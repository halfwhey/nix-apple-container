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

- `default.nix` — the nix-darwin module
- `package.nix` — derivation that extracts the `container` CLI from Apple's signed `.pkg`; accepts overridable `version` and `hash` args
- `kernel.nix` — fixed-output derivation that fetches the kata-containers kernel tarball via `curl` and extracts the binary; accepts overridable `version` and `hash` args
- `builder/Dockerfile` — nix-builder image (`FROM nixos/nix:<version>`); the Nix version in the `FROM` line is used as the image tag
- `builder/builder_ed25519` / `builder/builder_ed25519.pub` — known SSH key pair for the linux builder (intentionally public, same model as nixpkgs' `darwin.linux-builder`)
- `Makefile` — build/push/release/update targets for the builder image and module
- `scripts/` — update scripts: `update-container.sh`, `update-kernel.sh`, `update-nix-builder.sh`
- `scripts/uninstall.sh` — standalone uninstall script; mirrors the module teardown logic for use when the module import has been removed
- `.github/workflows/build-builder.yml` — builds and pushes the nix-builder image on changes to `builder/**`; tags with the Nix version; commits updated default image back to `default.nix`
- `.github/workflows/update-nix-builder.yml` — weekly scheduled workflow; checks Docker Hub for a newer `nixos/nix` tag and bumps `builder/Dockerfile` if stale, triggering `build-builder.yml` via the path filter
- `.github/workflows/update-container.yml` — weekly scheduled workflow; checks GitHub releases for a newer `apple/container` tag and bumps `package.nix` if stale

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
- `preActivation`: runtime start, kernel install, image loading (nix2container), mount dir creation, container pruning
- Main activation (nix-darwin): loads/unloads launchd agents (starts/stops containers)
- `postActivation`: reconcile stale agents, stop undeclared containers, builder SSH setup

### Activation (enable = true)

`preActivation`:
1. `container system status` — check if runtime is running; only start if not (fails loudly on error, no `|| true`)
2. Kernel symlink — creates `$APP_SUPPORT/kernels/default.kernel-arm64` as a symlink to the kernel binary in the Nix store. Fully declarative — the store path changes when the config changes, updating the symlink on next rebuild.
3. Image loading — for each image in `images.*`, compares the manifest digest from the Nix store against the runtime. Loads via `container image load -i` if missing or stale. Must happen before launchd starts containers.
4. Creates mount directories for containers with `autoCreateMounts = true` (only for absolute host paths)
5. Prunes stopped containers (`container prune`)

`postActivation`:
1. Unloads stale launchd agents (`dev.apple.container.*.plist`) not in current config
2. Stops and removes containers not declared in config

### Containers (autoStart = true)

Declared as `launchd.user.agents` (NOT `launchd.daemons`). This is critical because:
- The container runtime stores state per-user under `~/Library/Application Support/`
- `launchd.daemons` run as root, which puts state under `/var/root/` — wrong user context
- `launchd.user.agents` run as the logged-in user

Each container's `ProgramArguments` points to a wrapper script (`mkContainerRunScript`) that:
1. Stops and removes any existing container with the same name
2. `exec container run ...` with all configured flags

This wrapper ensures config changes are applied cleanly — when the plist changes, nix-darwin reloads the agent, the new wrapper cleans up the old container VM, and starts fresh. The `--detach` flag is NOT used because launchd manages the process lifecycle.

For containers referencing Nix-managed images (in `images.*`), the wrapper script embeds the image's `copyTo` store path as a comment. When image content changes, the store path changes, the script content changes, the plist changes, and nix-darwin restarts the agent — ensuring the container picks up the new image. Registry images are unaffected.

### Teardown (enable = false)

Agent unloading, defaults cleanup, and builder key removal run unconditionally. Runtime state cleanup is guarded by `if [ -d "$APP_SUPPORT" ]` to prevent noisy no-ops on first import with `enable = false`.

When disabled:
1. Unloads all module-owned launchd agents (`dev.apple.container.*.plist`) — runs unconditionally, before system stop to prevent KeepAlive restart loops
2. `container system stop` — deregisters launchd services, stops containers (guarded by APP_SUPPORT)
3. Always removes `kernels/` and `content/ingest/` (safe to recreate)
4. If `preserveImagesOnDisable = false` (default): removes `content/` (image blobs + metadata)
5. If both preserve options are false (default): removes entire `$APP_SUPPORT` directory
6. `defaults delete com.apple.container` — runs unconditionally (with error suppression)
7. `pkgutil --forget com.apple.container-installer` (if receipt exists) — runs unconditionally
8. Removes builder files (`/etc/nix/builder_ed25519*`) — runs unconditionally

### Linux builder (linuxBuilder.enable = true)

Runs `ghcr.io/halfwhey/nix-builder` (based on `nixos/nix`) as an Apple container with sshd, configured as a Nix remote builder for aarch64-linux builds. Uses a known SSH key pair committed to the repo (same security model as nixpkgs' `darwin.linux-builder` — builder only listens on localhost).

The default image tag in `default.nix` (`services.containerization.linuxBuilder.image`) tracks the Nix version used in the Dockerfile (e.g. `2.34.3`), not `:latest`. It is bumped automatically by `build-builder.yml` after each successful image push. The auto-update cascade is:
1. `update-nix-builder.yml` (weekly) detects a newer `nixos/nix` tag → bumps `builder/Dockerfile` → pushes to master
2. `build-builder.yml` fires on the `builder/**` path change → builds and pushes image tagged `:<nix-version>` → commits updated default to `default.nix`

Users can override the image via `services.containerization.linuxBuilder.image = "ghcr.io/halfwhey/nix-builder:2.34.3"`.

Builder config uses backend-specific declarative options when possible:
- When `config.nix.enable = true` (plain nix-darwin): sets `nix.buildMachines`, `nix.distributedBuilds`, `nix.settings.builders-use-substitutes` declaratively. nix-darwin writes the files and handles daemon restarts.
- When `config.nix.enable = false` (Determinate Nix): sets `determinateNix.customSettings` declaratively.
- In all backends: SSH key (`/etc/nix/builder_ed25519`) is installed imperatively (needs 0600 perms). SSH config uses `programs.ssh.extraConfig` declaratively. SSH config is needed because `nix.buildMachines` has no port field (we use `hostName = "nix-builder"` as an SSH alias) and `StrictHostKeyChecking no` is required (builder generates a new host key on every restart).

When disabled: removes `/etc/nix/builder_ed25519*`. Container is removed by reconciliation. Declarative `nix.buildMachines`, `programs.ssh.extraConfig`, and `determinateNix.customSettings` are cleared automatically by nix-darwin when the `lib.mkIf` condition becomes false.

### Images

Two image sources:
- **`images.*`** (`attrsOf package`): nix2container `buildImage` or `pullImage`. Built at Nix eval time, loaded into the runtime via `container image load` at activation time.
- **Registry images**: Containers referencing images not in `images.*` are pulled automatically by the container runtime when `container run` is invoked. No Nix-side fetch needed.

**Image loading**: At activation time, nix2container's `copyTo` exports the image to a temp OCI layout dir, which is tarred and loaded via `container image load -i`. The OCI dir must NOT be pre-built in the Nix store — `container image load` fails on tars created from read-only Nix store paths. The temp dir and tar are deleted after loading.

**Critical**: Image loading runs in `preActivation` (not postActivation) because launchd starts containers between pre and post.

**Idempotency**: Image loading runs `copyTo` to a temp OCI layout, reads the manifest digest from `index.json`, and compares against the runtime via `container image inspect`. If digests match, the temp dir is cleaned up and the load is skipped. If the content changed (even with the same tag), the old image is removed via `container image rm` and the new one is loaded. This is stateless — no marker files needed.

### Root vs user context

`darwin-rebuild switch` runs activation scripts as root. Container CLI calls in activation scripts use `sudo -u <user> --` (`runAs`) to run as the actual user. Launchd agent wrappers (`mkContainerRunScript`) run directly as the user since launchd.user.agents runs in the user session. The `user` option defaults to `config.system.primaryUser`.

The user's home directory is resolved at Nix eval time via `userHome` (checks `config.users.users` first, falls back to `/Users/${cfg.user}`).

## Idempotency and cleanup principles

Every activation script and feature MUST follow these rules:

### Idempotency

- **Guard before acting**: Check state before modifying. Don't start the runtime if already running (`system status`). Don't reload images if the digest matches. Don't append to `known_hosts` if the key is already present.
- **No unconditional appends**: Never `>> file` without checking if the content is already there. Use `grep -qF` to deduplicate.
- **No unconditional restarts**: Don't restart daemons unless config actually changed. nix-darwin's plist diffing handles launchd agents. The Nix daemon reads `/etc/nix/machines` on demand.
- **Activation scripts run on every rebuild**: Assume they run repeatedly with no config changes. They must produce no side effects in that case.

### Cleanup (enable/disable lifecycle)

Every feature that creates state outside the Nix store MUST clean it up when disabled:

| Component | State created | Cleanup when disabled |
|-----------|--------------|----------------------|
| Module (`enable`) | `~/Library/Application Support/com.apple.container/`, defaults, pkg receipt | Teardown block with `!cfg.enable` guard; selective cleanup based on `preserveImagesOnDisable` and `preserveVolumesOnDisable`; also removes builder files |
| Containers (`autoStart`) | Launchd agents (`dev.apple.container.*.plist`), running container VMs | postActivation reconciliation unloads agents + stops/removes containers; teardown also unloads agents before system stop |
| Linux builder (`linuxBuilder.enable`) | `/etc/nix/builder_ed25519*`, `programs.ssh.extraConfig`, `nix.buildMachines` (declarative), `determinateNix.customSettings` (Determinate) | `!cfg.linuxBuilder.enable` block removes SSH key; declarative options cleared by nix-darwin |
| Kernel | Symlinks in `$APP_SUPPORT/kernels/` pointing to Nix store | Removed with kernels dir on teardown (always cleaned); binary in Nix store protected by system profile |
| Images (`images.*`) | Images loaded into runtime's own storage via `container image load` | Removed with `content/` unless `preserveImagesOnDisable = true` |
| Mount directories (`autoCreateMounts`) | Host directories for volumes (absolute paths only) | NOT cleaned up (user data, intentionally preserved) |
| Named volumes | Runtime-managed storage inside `$APP_SUPPORT` | Destroyed with `$APP_SUPPORT` unless `preserveVolumesOnDisable = true` |

### nix-darwin's `userLaunchd` limitation

nix-darwin's user agent cleanup script is gated by `mkIf (... || userLaunchAgents != [])`. When ALL user agents are removed from config, the cleanup script never runs. Our module handles this explicitly in postActivation by globbing `dev.apple.container.*.plist` files and unloading stale agents.

### Plist filename convention

Plist filenames are derived from `serviceConfig.Label`, NOT the nix-darwin attribute name. Our agents use `Label = "dev.apple.container.${name}"`, so plists are `dev.apple.container.${name}.plist`. The reconciliation glob pattern must match this.

## Garbage collection

Stopped containers are pruned unconditionally on every activation (`container prune`). Containers removed from config are stopped and removed during postActivation reconciliation.

nix2container OCI layout dirs in the Nix store are referenced by the system profile's closure and protected from `nix-gc` as long as the current generation uses them. The runtime manages its own image storage independently.

## Bugs encountered during development

### `.pkg` payload path assumption
Initial code assumed the `.pkg` extracted to `usr/local/bin/`. Actual structure is flat: `bin/`, `libexec/` at root. The `installPhase` silently produced empty `$out/bin/` and `$out/libexec/` directories. Fixed by inspecting the actual payload with `xar -xf` + `cpio -i` manually.

### Duplicate `launchd.daemons` attribute
Defining `launchd.daemons."container-runtime"` as a named attr AND `launchd.daemons = lib.mapAttrs' ...` in the same `config` block causes a Nix evaluation error: "attribute already defined". Fixed by merging into a single attrset with `//`.

### `container system start` as a launchd daemon
Running `container system start` as a persistent `KeepAlive = true` daemon causes an infinite loop: the command registers its own launchd services (API server), exits, launchd restarts it, it tries to register again. The log shows endless "Registering API server with launchd... Verifying apiserver is running...". Fixed by moving `system start` to the activation script (runs once) and removing the launchd daemon.

### Root user context during activation
`darwin-rebuild switch` runs as root. `container image pull` stores data under `$HOME/Library/Application Support/com.apple.container/`. When run as root, this becomes `/var/root/Library/...` — the wrong location. The container runtime running as the actual user can't find the images. Error: `NSCocoaErrorDomain Code=4 ... couldn't be moved to "sha256"`. Fixed by wrapping all container CLI calls with `sudo -u <user> --`.

### `container image load` fails on Nix store tars
Pre-building OCI layout dirs as Nix derivations (`runCommand` with `copyTo`) and tarring them at activation time produces tars that `container image load` rejects with `failed to create file: ./oci-layout`. The command extracts the tar to its cwd and fails on read-only or permission issues from Nix store paths. Fixed by running `copyTo` at activation time into a writable temp dir, same as the original approach.

### macOS bsdtar argument ordering
`tar -C dir -cf file .` doesn't work on macOS bsdtar — the `-C` before `-cf` is ignored, producing empty archives. Use `tar cf file -C dir .` instead.

### Headless Mac: launchd user agents fail without a GUI session
On headless Mac minis (no display, no logged-in console session), the `gui/<uid>` launchd domain doesn't exist. `launchctl load` and user agent plists fail because `launchd.user.agents` targets this domain. Containers declared as user agents won't start. The fix is to enable auto-login so macOS creates a persistent GUI session on boot: `system.defaults.loginwindow.autoLoginUser = "<user>";` in the nix-darwin config, or `sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser <user>` imperatively. Reboot required.

### Stale apiserver launchd registration hangs all CLI commands
If the `container` CLI was previously run from a different install path (e.g., a source build in `.build/debug/`, or a Nix store path that was later garbage collected), launchd retains the apiserver registration pointing to the old binary. Every `container` command — including `--help`, `system status`, `system stop` — hangs indefinitely at "checking if APIServer is alive" because XPC blocks waiting for launchd to activate a binary that doesn't exist (launchd enters exponential throttle). Manual fix: `launchctl bootout user/$(id -u)/com.apple.container.apiserver`. See [#1329](https://github.com/apple/container/issues/1329).

The module handles this automatically in preActivation: before checking `system status`, it inspects the registered apiserver binary path via `launchctl print`. If the binary no longer exists (stale store path), it bootouts the service so `system start` can re-register with the current binary. This makes package upgrades (version bumps in `package.nix`) safe — the old store path is deregistered before the new CLI tries to use it.

### Kernel install prompt
`container system start` prompts interactively: "Install the recommended default kernel from [URL]? [Y/n]:". This hangs non-interactive environments. The module uses `--disable-kernel-install` on `system start` and manages the kernel declaratively — `kernel.nix` extracts the binary into the Nix store, and the activation script symlinks it into the runtime's `kernels/` directory.

## Apple Containerization quirks

### One VM per container
Unlike Docker (single VM hosting all containers), each container runs in its own lightweight VM with a dedicated Linux kernel. The framework provides the kernel (kata-containers) and a Swift-based init system (vminitd) as PID 1.

### Kernel source
The Linux kernel comes from [kata-containers](https://github.com/kata-containers/kata-containers/releases). `kernel.nix` is a fixed-output `stdenv.mkDerivation` that fetches the release tarball via `curl` in `buildCommand`, extracts the kernel binary via the `vmlinux.container` symlink, and stores just the binary (~16MB) in the Nix store. The activation script symlinks it into `~/Library/Application Support/com.apple.container/kernels/` with a `default.kernel-arm64` symlink.

`kernel.nix` accepts `version` and `hash` as overridable function arguments (defaults to the pinned version). Users can call `pkgs.callPackage "${inputs.nix-apple-container}/kernel.nix" { version = "..."; hash = "..."; }` to use a different release without forking the module. Same pattern applies to `package.nix` for the container CLI.

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
- `launchd.daemons` / `launchd.user.agents`: auto-diffed and removed by nix-darwin's activation
- Custom state: must use `lib.mkIf (!cfg.enable)` to run cleanup when the module is still imported but disabled
- If the module import is removed entirely, no cleanup runs — user must handle manually or keep the import with `enable = false` first

### Activation script ordering
`system.activationScripts.postActivation.text` with `lib.mkAfter` runs after other activation. Multiple modules appending to the same script are concatenated. Use `lib.mkMerge` with separate `lib.mkIf` blocks for enable/disable logic.

### launchd.daemons vs launchd.user.agents
- `launchd.daemons` → `/Library/LaunchDaemons/` — runs as root
- `launchd.user.agents` → `~/Library/LaunchAgents/` — runs as logged-in user
- Container commands MUST use `launchd.user.agents` due to per-user state

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
