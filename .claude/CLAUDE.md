# CLAUDE.md

Technical reference for working on nix-apple-container.

## Shell script conventions

When creating bash scripts, always check that required external binaries exist at the top of the script and fail with a descriptive error. Example:

```bash
for cmd in tart packer sshpass; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' is required but not found in PATH" >&2; exit 1; }
done
```

## Architecture

This is a nix-darwin module that wraps Apple's [Containerization](https://github.com/apple/containerization) framework.

- `module/default.nix` — nix-darwin module entrypoint; runtime/container lifecycle
- `module/options.nix` — core module options and the container submodule definition
- `module/common.nix` — internal shared handles used by more than one module file (paths, labels, key paths)
- `module/builders.nix` — linux-builder options and builder config
- `module/compat.nix` — migration/compatibility layer: deprecated option renames, all legacy launchd cleanup, resolver migration allowances
- `pkgs/package.nix` — derivation that extracts the `container` CLI from Apple's signed `.pkg`; accepts overridable `version` and `hash` args
- `pkgs/kernel.nix` — fixed-output derivation that fetches the kata-containers kernel tarball via `curl` and extracts the binary; accepts overridable `version` and `hash` args
- `builder/Dockerfile` — nix-builder image (`FROM nixos/nix:<version>`)
- `builder/IMAGE_VERSION` — builder image version series; published tags use `<builder-version>-nix<nix-version>` (e.g. `v2-nix2.34.6`)
- `builder/builder_ed25519` / `builder/builder_ed25519.pub` — known SSH key pair for the linux builder (intentionally public, same model as nixpkgs' `darwin.linux-builder`)
- `Makefile` — build/push/release/update targets for the builder image and module
- `scripts/` — update scripts: `update-container.sh`, `update-kernel.sh`, `update-nix-builder.sh`
- `scripts/uninstall.sh` — standalone uninstall script; mirrors the module teardown logic for use when the module import has been removed
- `.github/workflows/build-builder.yml` — weekly scheduled workflow (and push trigger on `builder/**`); on schedule, checks Docker Hub for a newer `nixos/nix` tag and, if stale, updates `builder/Dockerfile`, builds and pushes the image, updates `module/builders.nix`, and commits both files in a single commit; on push/dispatch, builds and pushes the image and commits only the `module/builders.nix` change
- `.github/workflows/update-container.yml` — weekly scheduled workflow; checks GitHub releases for a newer `apple/container` tag and bumps `pkgs/package.nix` if stale

The flake exposes `darwinModules.default`, `packages.aarch64-darwin.default`, `packages.aarch64-darwin.kernel`, and `packages.aarch64-darwin.uninstall`.

## How the package works

The `container` CLI is distributed as a flat `.pkg` (not a `.dmg`). Extraction:

1. `xar -xf` the `.pkg` — produces a `Payload` file at the top level (no sub-packages)
2. `gunzip -dc Payload | cpio -i` — extracts to `./bin/` and `./libexec/`
3. Binaries: `bin/container`, `bin/container-apiserver`
4. Plugins: `libexec/container/plugins/{container-runtime-linux,container-core-images,container-network-vmnet}/` — each contains a `bin/<name>` binary and a `config.json`

The `.pkg` does NOT extract to `usr/local/` — files are at the root of the payload. This was discovered by manual inspection; the initial assumption of `usr/local/bin/` was wrong.

## How the module works

### Activation script ordering

nix-darwin activation order: `preActivation` → `launchd` → `userLaunchd` → `postActivation`.

The module uses:
- `preActivation`: sync launchd plist assets, runtime start, kernel install, image loading (nix2container), registry image pre-pull for auto-start containers, mount dir creation, container pruning
- Main activation (nix-darwin): no module-owned launchd jobs are loaded here; user-domain jobs are managed explicitly
- `postActivation`: remove undeclared containers declaratively (bootout + clear stale launchd override + delete plist + stop/rm), then bootstrap current managed container jobs, builder SSH setup

### Activation (enable = true)

`preActivation`:
1. `container system status` — check if runtime is running; only start if not (fails loudly on error, no `|| true`)
2. Kernel symlink — creates `$APP_SUPPORT/kernels/default.kernel-arm64` as a symlink to the kernel binary in the Nix store. Fully declarative — the store path changes when the config changes, updating the symlink on next rebuild.
3. Image loading — for each image in `images.*`, compares the manifest digest from the Nix store against the runtime. Loads via `container image load -i` if missing or stale. Must happen before launchd starts containers.
4. Creates mount directories for containers with `autoCreateMounts = true` (only for absolute host paths)
5. Prunes stopped containers (`container prune`)

`postActivation`:
1. Removes undeclared containers declaratively:
   - `launchctl bootout` the old `dev.apple.container.<name>` label from `gui/<uid>` and `user/<uid>`
   - `launchctl enable` the same label in those domains to clear any stale disabled override
   - delete `/Library/LaunchAgents/dev.apple.container.<name>.plist`
   - `container stop` + `container rm`
2. Bootstraps the currently declared managed plists into the resolved user launchd domain

### Containers (autoStart = true)

The runtime itself is a Background-session LaunchAgent plist (`/Library/LaunchAgents/nix-apple-container.runtime.plist`) for `system.primaryUser`. This keeps Apple `container` in the user's launchd domain, which is what upstream expects for the apiserver/XPC path. It does mean the runtime only comes up after the first session for that user exists (GUI login or SSH/background session).

Auto-start containers are separate plists stored in `/Library/LaunchAgents/`. The module bootstraps those plists into `user/<uid>` explicitly after `container system start` succeeds, instead of relying on nix-darwin's `userLaunchd` `load -w` path. Before each bootstrap, activation explicitly `bootout`s the target label in the resolved domain if it is already loaded and then polls `launchctl print "$domain/$label"` until the service is fully gone (up to 30s), so re-bootstrap works even while the previous container is still being torn down. The plists themselves stay passive (`RunAtLoad = false`) and use `KeepAlive.OtherJobEnabled."com.apple.container.apiserver" = true`, so launchd only starts them once the runtime has registered the apiserver.

Important launchd semantics:
- `launchctl bootstrap ... <plist>` is not a declarative replace operation. If the label is already loaded in that domain, bootstrap can fail with `5` instead of replacing it. Explicit `bootout` first is required, and since `bootout` is asynchronous (returns before the process group is fully reaped), callers must poll `launchctl print "$domain/$label"` until it fails before re-bootstrapping.
- `launchctl disable` is sticky state in launchd's disabled database. It does NOT remove the plist and it survives reboots. For declarative removal, do not rely on `disable`; clear stale overrides with `enable`, remove the plist, and boot the job out.
- `launchctl list` is not a filesystem view. `PID` `-` plus status `1` means the last exit status for that known label was `1`; it does not prove the plist still exists on disk.

Each container's `ProgramArguments` points to a wrapper script (`mkContainerRunScript`) that:
1. Stops and removes any existing container with the same name
2. Waits for a stable runtime/apiserver and retries a few quick boot-time XPC failures
3. Runs `container run ...` with all configured flags

This wrapper ensures config changes are applied cleanly — when the plist changes, activation rewrites the managed plist set and the runtime bootstrap recreates the job, so the new wrapper cleans up the old container VM and starts fresh. It also smooths over the transient XPC interruptions that can happen right after reboot while Apple `container` is still settling. The `--detach` flag is NOT used because launchd manages the process lifecycle.

The runtime/bootstrap script and each container wrapper now wrap their stdout/stderr with ISO-8601 timestamps plus a context tag (`[nix-apple-container.runtime]`, `[container-<name>]`, `[bootstrap-managed-containers]`). That means `~/Library/Logs/container-runtime.{log,err}` and `~/Library/Logs/container-<name>.{log,err}` are timeline logs, not raw command output. The wrappers also log the child `container run` PID plus final exit/signal status. Use those files first when debugging launchd behavior.

For containers referencing Nix-managed images (in `images.*`), the wrapper script embeds the image's `copyTo` store path as a comment. When image content changes, the store path changes, the script content changes, the plist changes, and nix-darwin reloads the user agent — ensuring the container picks up the new image. Registry images are unaffected.

### Teardown (enable = false)

Compatibility cleanup for legacy launch agents, defaults cleanup, and builder key removal run unconditionally. Runtime state cleanup is guarded by `if [ -d "$APP_SUPPORT" ]` to prevent noisy no-ops on first import with `enable = false`.

When disabled:
1. Removes legacy user/system launch agents and stale system launch daemons during compatibility cleanup
2. `container system stop` — deregisters launchd services, stops containers (guarded by APP_SUPPORT)
3. Always removes `kernels/` and `content/ingest/` (safe to recreate)
4. If `preserveImagesOnDisable = false` (default): removes `content/` (image blobs + metadata)
5. If both preserve options are false (default): removes entire `$APP_SUPPORT` directory
6. `defaults delete com.apple.container` — runs unconditionally (with error suppression)
7. `pkgutil --forget com.apple.container-installer` (if receipt exists) — runs unconditionally
8. Removes builder files (`/etc/nix/builder_ed25519*`) — runs unconditionally

### Linux builders (linux-builder.aarch64 / linux-builder.x86_64)

Runs `ghcr.io/halfwhey/nix-builder` (based on `nixos/nix`) as Apple containers with sshd, configured as Nix remote builders. Two architectures available: `linux-builder.aarch64` (native) and `linux-builder.x86_64` (`--platform linux/amd64`). Each is independently enabled. Both share the same multi-arch image (`linux-builder.image`) and SSH key pair committed to the repo (same security model as nixpkgs' `darwin.linux-builder` -- builder only listens on localhost). Each builder also has a per-container `kernel` option wired to `container run --kernel`; `linux-builder.x86_64.kernel` defaults to a Rosetta-compatible Kata 3.24.0 kernel, while `linux-builder.aarch64.kernel = null` uses the runtime default kernel.

Container names always include a URI-safe platform suffix: `nix-builder-aarch64`, `nix-builder-amd64`. SSH aliases match the container names. The option path remains `linux-builder.x86_64` — `x86_64` is valid Nix syntax — but the runtime name avoids underscores because the machine-spec/store-URI hostname field should avoid them.

The builder image must persist both `sandbox = false` and `filter-syscalls = false` in `/etc/nix/nix.conf`. Setting `filter-syscalls = false` only on one-off image build commands is not enough — remote builds can still fail during environment setup with `unable to load seccomp BPF program: Invalid argument`, especially on the amd64/Rosetta path.

The old `linuxBuilder.*` option names are deprecated but still work via `mkRenamedOptionModule` (7 entries in `module/compat.nix`). They map to `linux-builder.aarch64.*` (per-arch options) and `linux-builder.image` (shared).

The default image tag in `module/builders.nix` (`services.containerization.linux-builder.image`) uses `<builder-version>-nix<nix-version>` (e.g. `v2-nix2.34.6`), not `:latest`. `builder/IMAGE_VERSION` is bumped manually when the builder image semantics change; the nix-version suffix is bumped automatically by `build-builder.yml` when the `nixos/nix` base image changes. The CI regex (`s|ghcr.io/halfwhey/nix-builder:[^"]*|...|`) matches the string literal in the option default value.

Users can override the image via `services.containerization.linux-builder.image = "ghcr.io/halfwhey/nix-builder:v2-nix2.34.6"`.

Implementation structure across `module/`:
- `module/default.nix`: runtime start/teardown, image loading, launchd jobs, container reconciliation
- `module/options.nix`: core `services.containerization` options and the container submodule
- `module/common.nix`: shared handles only; no behavior logic
- `module/compat.nix`: migration-only behavior: renamed option imports, all legacy user/system launchd cleanup, resolver migration handling
- `module/builders.nix`: `builderCfg`/`anyBuilderEnabled`, per-arch builder options/config, SSH key setup, and Determinate/plain Nix builder wiring

Builder config uses backend-specific declarative options when possible:
- When `config.nix.enable = true` (plain nix-darwin): sets `nix.buildMachines`, `nix.distributedBuilds`, `nix.settings.builders-use-substitutes` declaratively. nix-darwin writes the files and handles daemon restarts.
- When `config.nix.enable = false` (Determinate Nix): sets `determinateNix.buildMachines`, `determinateNix.distributedBuilds`, and `determinateNix.customSettings.builders-use-substitutes` declaratively.
- In all backends: SSH key (`/etc/nix/builder_ed25519`) is installed imperatively (needs 0600 perms). SSH config uses `programs.ssh.extraConfig` declaratively. SSH config is needed because `nix.buildMachines` has no port field (we use `hostName = "nix-builder-<arch>"` as SSH aliases) and `StrictHostKeyChecking no` is required (builder generates a new host key on every restart).

When all builders disabled: removes `/etc/nix/builder_ed25519*`. Containers removed by reconciliation. Declarative `nix.buildMachines`, `programs.ssh.extraConfig`, and `determinateNix.customSettings` are cleared automatically by nix-darwin when `lib.mkIf` conditions become false.

### Images

Two image sources:
- **`images.*`** (`attrsOf package`): nix2container `buildImage` or `pullImage`. Built at Nix eval time, loaded into the runtime via `container image load` at activation time.
- **Registry images**: For `autoStart` containers referencing images not in `images.*`, activation pre-pulls them with `container image pull` as the configured user before launchd bootstrap. This avoids first-run registry fetch failures inside launchd-managed `container run`. Non-autoStart containers still rely on the runtime to pull on demand.

**Image loading**: At activation time, nix2container's `copyTo` exports the image to a temp OCI layout dir, which is tarred and loaded via `container image load -i`. The OCI dir must NOT be pre-built in the Nix store — `container image load` fails on tars created from read-only Nix store paths. The temp dir and tar are deleted after loading.

**Critical**: Image loading runs in `preActivation` (not postActivation) because launchd starts containers between pre and post.

**Idempotency**: Image loading runs `copyTo` to a temp OCI layout, reads the manifest digest from `index.json`, and compares against the runtime via `container image inspect`. If digests match, the temp dir is cleaned up and the load is skipped. If the content changed (even with the same tag), the old image is removed via `container image rm` and the new one is loaded. This is stateless — no marker files needed.

### Root vs user context

`darwin-rebuild switch` runs activation scripts as root. Container CLI calls in activation scripts use `sudo -u <user> --` (`runAs`) to run as the actual user. The module installs the runtime plist and managed container plists into `/Library/LaunchAgents`, then bootstraps the container jobs explicitly into the user's launchd context. The `user` option defaults to `config.system.primaryUser`, and the module asserts that they match.

The user's home directory is resolved at Nix eval time via `userHome` (checks `config.users.users` first, falls back to `/Users/${cfg.user}`).

For reconciliation, prefer `container ls --all --quiet` over parsing `--format json`. The quiet output is the stable container ID/name list; the JSON shape is not a good contract for activation scripts.

`container prune` only removes stopped containers. It is not sufficient for drift cleanup. Running undeclared containers must still be found with `container ls --all --quiet` and explicitly stopped/removed.

## Idempotency and cleanup principles

Every activation script and feature MUST follow these rules:

### Idempotency

- **Guard before acting**: Check state before modifying. Don't start the runtime if already running (`system status`). Don't reload images if the digest matches. Don't append to `known_hosts` if the key is already present.
- **No unconditional appends**: Never `>> file` without checking if the content is already there. Use `grep -qF` to deduplicate.
- **No unconditional restarts**: Don't restart daemons unless config actually changed. nix-darwin's plist diffing handles launchd jobs. The Nix daemon reads `/etc/nix/machines` on demand.
- **Activation scripts run on every rebuild**: Assume they run repeatedly with no config changes. They must produce no side effects in that case.

### Cleanup (enable/disable lifecycle)

Every feature that creates state outside the Nix store MUST clean it up when disabled:

| Component | State created | Cleanup when disabled |
|-----------|--------------|----------------------|
| Module (`enable`) | `~/Library/Application Support/com.apple.container/`, defaults, pkg receipt | Teardown block with `!cfg.enable` guard; selective cleanup based on `preserveImagesOnDisable` and `preserveVolumesOnDisable`; also removes builder files |
| Containers (`autoStart`) | Managed plists in `/Library/LaunchAgents/`, bootstrapped `dev.apple.container.*` jobs, running container VMs | postActivation removes undeclared jobs declaratively and bootstraps the current plist set; teardown bootouts all managed labels, clears stale launchd disabled overrides, and removes the managed plists |
| Linux builders (`linux-builder.{aarch64,x86_64}.enable`) | `/etc/nix/builder_ed25519*`, `programs.ssh.extraConfig`, `nix.buildMachines` (declarative), `determinateNix.customSettings` (Determinate), containers `nix-builder-aarch64` / `nix-builder-amd64` | `!anyBuilderEnabled` block removes SSH key; containers removed by reconciliation; declarative options cleared by nix-darwin |
| Kernel | Symlinks in `$APP_SUPPORT/kernels/` pointing to Nix store | Removed with kernels dir on teardown (always cleaned); binary in Nix store protected by system profile |
| Images (`images.*`) | Images loaded into runtime's own storage via `container image load` | Removed with `content/` unless `preserveImagesOnDisable = true` |
| Mount directories (`autoCreateMounts`) | Host directories for volumes (absolute paths only) | NOT cleaned up (user data, intentionally preserved) |
| Named volumes | Runtime-managed storage inside `$APP_SUPPORT` | Destroyed with `$APP_SUPPORT` unless `preserveVolumesOnDisable = true` |

### nix-darwin's `userLaunchd` limitation

nix-darwin's `userLaunchd` path uses legacy `launchctl asuser ... load -w`, which is brittle on headless SSH-driven Macs and was the source of the `Error 134` / `SIGABRT` regressions. The module no longer relies on `launchd.user.agents` for container jobs; it installs Background-session plists in `/Library/LaunchAgents` and uses explicit `launchctl bootstrap user/<uid> ...` for the managed jobs. `module/compat.nix` still cleans up stale legacy user LaunchAgents and stale system LaunchDaemons during enabled migrations, while leaving the current `/Library/LaunchAgents` set alone.

### Plist filename convention

Plist filenames are derived from `serviceConfig.Label`, NOT the nix-darwin attribute name. Our managed jobs use `Label = "dev.apple.container.${name}"`, so plists are `dev.apple.container.${name}.plist`. The compatibility cleanup glob pattern must match this.

## Garbage collection

Stopped containers are pruned unconditionally on every activation (`container prune`). Containers removed from config are stopped and removed during postActivation reconciliation.

nix2container OCI layout dirs in the Nix store are referenced by the system profile's closure and protected from `nix-gc` as long as the current generation uses them. The runtime manages its own image storage independently.

## Bugs encountered during development

### `.pkg` payload path assumption
Initial code assumed the `.pkg` extracted to `usr/local/bin/`. Actual structure is flat: `bin/`, `libexec/` at root. The `installPhase` silently produced empty `$out/bin/` and `$out/libexec/` directories. Fixed by inspecting the actual payload with `xar -xf` + `cpio -i` manually.

### Duplicate `launchd.daemons` attribute
Defining `launchd.daemons."container-runtime"` as a named attr AND `launchd.daemons = lib.mapAttrs' ...` in the same `config` block causes a Nix evaluation error: "attribute already defined". Fixed by merging into a single attrset with `//`.

### `container system start` as a launchd daemon
Running `container system start` as a persistent `KeepAlive = true` daemon causes an infinite loop: the command registers its own launchd services (API server), exits, launchd restarts it, it tries to register again. The log shows endless "Registering API server with launchd... Verifying apiserver is running...". The module avoids that by using a one-shot runtime user agent plus guarded activation-time startup.

### Root user context during activation
`darwin-rebuild switch` runs as root. `container image pull` stores data under `$HOME/Library/Application Support/com.apple.container/`. When run as root, this becomes `/var/root/Library/...` — the wrong location. The container runtime running as the actual user can't find the images. Error: `NSCocoaErrorDomain Code=4 ... couldn't be moved to "sha256"`. Fixed by wrapping all container CLI calls with `sudo -u <user> --`.

### `container image load` fails on Nix store tars
Pre-building OCI layout dirs as Nix derivations (`runCommand` with `copyTo`) and tarring them at activation time produces tars that `container image load` rejects with `failed to create file: ./oci-layout`. The command extracts the tar to its cwd and fails on read-only or permission issues from Nix store paths. Fixed by running `copyTo` at activation time into a writable temp dir, same as the original approach.

### macOS bsdtar argument ordering
`tar -C dir -cf file .` doesn't work on macOS bsdtar — the `-C` before `-cf` is ignored, producing empty archives. Use `tar cf file -C dir .` instead.

### Headless Mac: first user session still required
Apple `container` expects its apiserver in the user's launchd domain. A pure system-daemon setup breaks the client's XPC path even though `LaunchDaemon + UserName` is valid launchd. The module therefore installs Background-session LaunchAgent plists for `system.primaryUser` in `/Library/LaunchAgents` and intentionally requires the first session for that user after boot. A GUI login works, and an SSH login as that same user also works because Apple `container` can run in the `Background` domain.

### Apple `container` follows the current launchd domain, not an arbitrary one
Upstream `container system start` is a one-shot command that registers `com.apple.container.apiserver` into the launchd bootstrap domain of the current session. In practice that means:
- GUI login session → `gui/<uid>`
- headless/background/SSH session → `user/<uid>`
- system/root session → `system`

This is why the module must keep Apple `container` in the user's domain and cannot treat it like a normal system daemon. `LaunchDaemon + UserName` is valid launchd, but it is the wrong XPC domain for the upstream client.

### Stale apiserver launchd registration hangs all CLI commands
If the `container` CLI was previously run from a different install path (e.g., a source build in `.build/debug/`, or a Nix store path that was later garbage collected), launchd retains the apiserver registration pointing to the old binary. Every `container` command — including `--help`, `system status`, `system stop` — hangs indefinitely at "checking if APIServer is alive" because XPC blocks waiting for launchd to activate a binary that doesn't exist (launchd enters exponential throttle). Manual fix: `launchctl bootout user/$(id -u)/com.apple.container.apiserver`. See [#1329](https://github.com/apple/container/issues/1329).

The module handles this automatically in preActivation: before checking `system status`, it inspects the registered apiserver binary path via `launchctl print`. If the binary no longer exists (stale store path), it bootouts the service so `system start` can re-register with the current binary. This makes package upgrades (version bumps in `pkgs/package.nix`) safe — the old store path is deregistered before the new CLI tries to use it.

### Kernel install prompt
`container system start` prompts interactively: "Install the recommended default kernel from [URL]? [Y/n]:". This hangs non-interactive environments. The module uses `--disable-kernel-install` on `system start` and manages the runtime default kernel declaratively — `pkgs/kernel.nix` extracts the binary into the Nix store, and the activation script symlinks it into the runtime's `kernels/` directory. Individual containers can still override this with `container run --kernel`; the x86_64 Nix builder uses that hook to pin a Rosetta-compatible kernel.

### `launchctl bootstrap` fails with status 5 if the label is already loaded
During the explicit `/Library/LaunchAgents` bootstrap flow, `launchctl bootstrap user/<uid> <plist>` can fail with `Bootstrap failed: 5: Input/output error` when the target `dev.apple.container.*` label is already present in that domain. This is not necessarily a bad plist; it can just mean the job is already loaded. Fix: `bootout` the exact label first, then bootstrap it again.

### `container prune` is not drift reconciliation
`container prune` only removes stopped containers. It will not delete running undeclared containers. Drift reconciliation must enumerate containers with `container ls --all --quiet` and explicitly `stop` + `rm` anything not declared in config.

### `launchctl disable` leaves persistent declarative residue
`launchctl disable` writes to launchd's persistent disabled database. That state survives plist deletion and can still show up in `launchctl list` / `print-disabled` after the service is removed from config. For declarative cleanup, the correct sequence is: `bootout` the label, `enable` the label to clear any stale disabled override, then remove the plist and stop/rm the container if needed.

### `launchctl list` status column is last exit status
In `launchctl list`, the second column is the service's `LastExitStatus`, not an enabled/disabled flag and not proof that the plist still exists. A line like `-    1    dev.apple.container.gitea` means launchd still knows about that label and the last exit status was `1`; it does not by itself tell you whether the plist is still on disk. Use `launchctl print-disabled`, `launchctl print <domain>/<label>`, and `ls /Library/LaunchAgents/*.plist` together when debugging.

### Activation failures do not roll back earlier successful bootstraps
The managed-container bootstrap script runs container plists one by one under `set -e`. If one bootstrap succeeds and a later one fails, activation aborts but the earlier job stays loaded and may already have started its container. This is why a rebuild can fail overall while one declared container still comes up successfully.

## Apple Containerization quirks

### One VM per container
Unlike Docker (single VM hosting all containers), each container runs in its own lightweight VM with a dedicated Linux kernel. The framework provides the kernel (kata-containers) and a Swift-based init system (vminitd) as PID 1.

### Kernel source
The Linux kernel comes from [kata-containers](https://github.com/kata-containers/kata-containers/releases). `pkgs/kernel.nix` is a fixed-output `stdenv.mkDerivation` that fetches the release tarball via `curl` in `buildCommand`, extracts the kernel binary via the `vmlinux.container` symlink, and stores just the binary (~16MB) in the Nix store. The activation script symlinks the runtime default kernel into `~/Library/Application Support/com.apple.container/kernels/` with a `default.kernel-arm64` symlink, while the x86_64 builder passes its own kernel path directly via `--kernel`.

`pkgs/kernel.nix` accepts `version` and `hash` as overridable function arguments (defaults to the pinned version). Users can call `pkgs.callPackage "${inputs.nix-apple-container}/pkgs/kernel.nix" { version = "..."; hash = "..."; }` to use a different release without forking the module. Same pattern applies to `pkgs/package.nix` for the container CLI.

### Networking
- macOS 15: limited networking, no container-to-container, no custom networks
- macOS 26: full networking support, custom networks, direct IP access
- Port forwarding: `--publish host:container` syntax, uses vmnet framework
- Each container gets its own IP on the vmnet subnet (default `192.168.64.0/24`)
- Containers named `foo` get DNS entry `foo.test` automatically
- No `--hostname` flag — use `--name` instead
- Known issue: VPN activation breaks container networking ([#1307](https://github.com/apple/container/issues/1307))
- Known issue: single file volume mounts fail intermittently ([#1251](https://github.com/apple/container/issues/1251))

### Container data location
All state under `~/Library/Application Support/com.apple.container/`:
- `kernels/` — Linux kernels + `default.kernel-arm64` symlink
- `content/blobs/` — image layers
- `content/ingest/` — temporary download staging
- `volumes/<name>/volume.img` — named volumes as ext filesystem disk images

### Named volumes are sparse disk images, not plain directories
Apple named volumes are stored as sparse disk images (`volume.img`) under the runtime state directory. That leads to two easy debugging traps:
- `du` shows allocated blocks, which can be tiny
- `ls -lh`, `stat`, and `rsync --progress` show the logical file size, which can be many GB

So a volume image can look like `66M` on disk while `rsync` reports a `9.4G` transfer. That is normal sparse-file behavior. It does NOT mean `rsync` found 9.4G of real data.

If `file volume.img` reports `mounted or unclean` or `(errors)`, treat that as volume/filesystem damage or an unclean shutdown signal inside the ext image, not as a launchd problem.

### Bind mounts use shared-directory/virtiofs semantics
Bind mounts are not the same as named volumes. Named volumes are block-backed disk images inside Apple `container` state; bind mounts use the VM shared-directory device (virtiofs-style host sharing).

Practical consequences:
- external or unusual host paths under `/Volumes/...` can fail before the container even starts with `VZErrorDomain Code=2` / `NSPOSIXErrorDomain Code=1 "Operation not permitted"`
- permission/ownership behavior at the mountpoint can be surprising compared to Docker on Linux
- directly bind-mounting an app's canonical data directory as the mountpoint can be fragile; mounting a parent directory and letting the app use a subdirectory under it is safer

This matters for stateful services like Gitea. If a named volume fails with bad persisted data, that is a volume/filesystem issue. If a bind mount fails with `VZErrorDomain` before boot, that is a host-path/shared-directory issue.

### container system start internals
`container system start` is NOT a long-running daemon. It:
1. Registers the API server with launchd
2. Verifies it's running
3. Optionally installs the kernel
4. Exits

The API server itself runs as a separate launchd service managed by the container framework, not by nix-darwin.

## nix-darwin quirks

### No deactivation hooks
nix-darwin has no "on module removed" lifecycle hook. Cleanup happens via:
- nix-darwin launchd options: auto-diffed and removed by nix-darwin's activation
- Custom state: must use `lib.mkIf (!cfg.enable)` to run cleanup when the module is still imported but disabled
- If the module import is removed entirely, no cleanup runs — user must handle manually or keep the import with `enable = false` first

### Activation script ordering
`system.activationScripts.postActivation.text` with `lib.mkAfter` runs after other activation. Multiple modules appending to the same script are concatenated. Use `lib.mkMerge` with separate `lib.mkIf` blocks for enable/disable logic.

### launchd.daemons vs launchd.user.agents
- `launchd.daemons` → `/Library/LaunchDaemons/` — loaded by root at boot; can still run as a non-root user via `serviceConfig.UserName`
- `launchd.user.agents` → `~/Library/LaunchAgents/` — loaded in the primary user's launchd domain; in practice this means the first GUI or SSH/background session for that user
- This module installs its runtime/container plists into `/Library/LaunchAgents` with `LimitLoadToSessionType = Background` and bootstraps them explicitly into `user/<uid>` because Apple `container` expects the apiserver in the user's launchd domain but nix-darwin's `userLaunchd` loader is brittle

## Useful links

### Apple Containerization
- Repository: https://github.com/apple/containerization (framework)
- CLI tool: https://github.com/apple/container
- Command reference: https://github.com/apple/container/blob/main/docs/command-reference.md
- How-to guide: https://github.com/apple/container/blob/main/docs/how-to.md
- Technical overview: https://github.com/apple/container/blob/main/docs/technical-overview.md
- Building from source: https://github.com/apple/container/blob/main/BUILDING.md
- SystemStart.swift (kernel install logic): https://github.com/apple/container/blob/e5f9abd8ff3136f27fde9ffc9abed4195c4ac9ef/Sources/ContainerCommands/System/SystemStart.swift#L138

### Kata Containers (kernel)
- Releases: https://github.com/kata-containers/kata-containers/releases
- Kernel binary in tarball: `opt/kata/share/kata-containers/vmlinux.container` (symlink to versioned binary)

### nix-darwin
- Repository: https://github.com/LnL7/nix-darwin
- Launchd module: `modules/system/launchd.nix` (handles service diff/cleanup)
- Activation scripts: `modules/system/activation-scripts.nix`
- OpenSSH module (enable/disable pattern): `modules/services/openssh.nix`

### Nix container image building
- dockerTools docs: https://ryantm.github.io/nixpkgs/builders/images/dockertools/
- nix.dev tutorial: https://nix.dev/tutorials/nixos/building-and-running-docker-images.html
- nix2container (alternative): https://github.com/nlewo/nix2container

### macOS .pkg packaging in Nix
- NixOS Discourse: https://discourse.nixos.org/t/how-to-define-derivations-for-macos-pkg-archives-in-nix/6252
- undmg (for .dmg files): https://github.com/matthewbauer/undmg
- nixpkgs platform notes: https://ryantm.github.io/nixpkgs/stdenv/platform-notes/
