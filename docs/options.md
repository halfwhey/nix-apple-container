# Options

## `services.containerization`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Install the CLI, start the runtime, enable the module |
| `user` | string | `config.system.primaryUser` | User to run container commands as (activation scripts run as root) |
| `package` | package | *built from .pkg* | Override the container CLI package |
| `images` | attrs of packages | `{}` | nix2container images to load (buildImage or pullImage) |
| `preserveImagesOnDisable` | bool | `false` | Keep loaded images when the module is disabled |
| `preserveVolumesOnDisable` | bool | `false` | Keep named volume data when the module is disabled. Best-effort based on known runtime directory layout. Bind mounts are always preserved (they live on the host) |

## `services.containerization.networks.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `subnet` | string or null | `null` | IPv4 subnet (e.g. `192.168.100.0/24`) |
| `subnetV6` | string or null | `null` | IPv6 subnet |

Declarative networks (macOS 26+). Created idempotently during activation. Networks managed by the module are labeled `managed-by=nix-apple-container` and cleaned up when removed from config or when the module is disabled.

## `services.containerization.volumes.<name>`

Declarative named volumes. Created idempotently during activation.

## `services.containerization.kernel`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| *(top-level)* | package | *kata 3.26.0 arm64* | Flat file derivation of the kernel binary — symlinked as `default.kernel-arm64` in the runtime |

## `services.containerization.containers.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | string or null | `null` | Image name:tag (from `images.*` or a registry). Auto-set when `nixos.enable = true`. Required otherwise |
| `nixos.enable` | bool | `false` | Build this container from a NixOS configuration. Requires nix2container flake input |
| `nixos.configuration` | NixOS module | `{}` | NixOS modules to evaluate and build into an OCI image. The image runs systemd as PID 1 |
| `autoStart` | bool | `false` | Run via launchd user agent on login. When false, the name is reserved (prevents drift cleanup) but no container is created |
| `cmd` | list of strings | `[]` | Override the image CMD |
| `env` | attrs of strings | `{}` | Environment variables |
| `volumes` | list of strings | `[]` | Volume mounts (macOS 26+). `host:container` for bind mounts or `name:container` for named volumes. Every entry must contain a `:` |
| `autoCreateMounts` | bool | `true` | Create host directories for volume mounts if they don't exist |
| `entrypoint` | string or null | `null` | Override the image entrypoint |
| `user` | string or null | `null` | Run as UID or UID:GID |
| `workdir` | string or null | `null` | Override working directory |
| `init` | bool | `false` | Run init for signal forwarding and zombie reaping |
| `ssh` | bool | `false` | Forward SSH agent from host |
| `network` | string or null | `null` | Attach to custom network (macOS 26+). Can reference a network from `networks.*` or a project network |
| `readOnly` | bool | `false` | Read-only root filesystem |
| `labels` | attrs of strings | `{}` | Container labels for metadata |
| `ports` | list of strings | `[]` | Port mappings (`host:container`). Each becomes a `--publish` flag |
| `cpus` | float or null | `null` | CPU limit for the container VM |
| `memory` | string or null | `null` | Memory limit (e.g. `512m`, `2g`) |
| `dependsOn` | list of strings | `[]` | Container names that must be running before this one starts. Within a project, use short names (auto-resolved to scoped names) |
| `dependsOnTimeout` | int | `60` | Seconds to wait for each dependency before proceeding |
| `dns` | list of strings | `[]` | Custom DNS servers |
| `tmpfs` | list of strings | `[]` | Tmpfs mounts inside the container |
| `extraArgs` | list of strings | `[]` | Extra arguments passed to `container run` |

## `services.containerization.projects.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `containers` | attrs of container submodule | `{}` | Containers in this project. Names are scoped: `web` in project `myapp` becomes `myapp-web` |
| `network` | string or null | `null` | Shared network for all containers (macOS 26+). Auto-created if not in `networks.*` |
| `env` | attrs of strings | `{}` | Environment variables applied to all containers in the project |
| `labels` | attrs of strings | `{}` | Labels applied to all containers in the project |

Projects group related containers with shared configuration. Container names are scoped by project (`<project>-<name>`). Within a project, `dependsOn` references use short names and auto-resolve to the scoped form. Project-level `env` and `labels` merge into each container (container-level values take precedence).

## `services.containerization.linuxBuilder`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Run a Nix builder container for aarch64-linux builds |
| `image` | string | `"ghcr.io/halfwhey/nix-builder:latest"` | Builder container image |
| `sshPort` | port | `31022` | Host port for SSH to the builder |
| `maxJobs` | int | `4` | Max parallel build jobs |

Runs a Nix builder container for aarch64-linux builds. The default image (`ghcr.io/halfwhey/nix-builder`) is built from the `builder/Dockerfile` in this repo — it's a minimal `nixos/nix` image with sshd. Uses a known SSH key pair (builder only listens on localhost, same security model as nixpkgs' `darwin.linux-builder`).

Builder Nix configuration is fully declarative:
- **`nix.enable = true`** (plain nix-darwin): uses `nix.buildMachines`, `nix.distributedBuilds`, and `nix.settings`.
- **Determinate Nix**: uses `determinateNix.customSettings`. Note: `builders` is a single string setting — if another module also sets `determinateNix.customSettings.builders`, they will conflict. Requires the [Determinate nix-darwin module](https://docs.determinate.systems/guides/nix-darwin/):

  <details>
  <summary>Determinate Nix flake setup</summary>

  ```nix
  # flake.nix
  {
    inputs = {
      determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
      # ... your other inputs
    };

    outputs = { determinate, nix-darwin, ... }: {
      darwinConfigurations.myhost = nix-darwin.lib.darwinSystem {
        modules = [
          determinate.darwinModules.default
          # ... your other modules
          {
            determinateNix.enable = true;
          }
        ];
      };
    };
  }
  ```

  > **First-time setup**: nix-darwin may refuse to activate with `Unexpected files in /etc` mentioning `nix.custom.conf`. This happens because the Determinate installer created the file before nix-darwin can manage it ([nix-darwin#1298](https://github.com/nix-darwin/nix-darwin/issues/1298)). Rename it and rebuild:
  > ```bash
  > sudo mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
  > ```

  </details>

**Bootstrap**: First rebuild starts the builder. Second rebuild can use it for Linux derivations (e.g. nix2container images with `aarch64-linux` packages).
