# nix-apple-container

> **Alpha** — this module is functional but under active development. Options may change.

A nix-darwin module for declaratively managing [Apple Containerization](https://github.com/apple/containerization) — Apple's native Linux container runtime for Apple Silicon Macs.

## What it does

- Packages the `container` CLI from Apple's `.pkg` release via Nix (no Homebrew needed)
- Manages the Linux kernel as a Nix derivation (no runtime download from GitHub)
- Starts the container runtime and installs the kernel automatically
- Declares containers that run as launchd user agents (automatically recreated on config change)
- Auto-creates host directories for volume mounts
- Optional Linux builder container for building `aarch64-linux` derivations on macOS
- Reconciles running containers against config — removes undeclared containers and their launchd agents
- Garbage-collects containers and images not in your config
- Loads Nix-built OCI images via [nix2container](https://github.com/nlewo/nix2container) — no tarballs in the Nix store
- Selective teardown when disabled — optionally preserves pulled images across disable/enable cycles

## Requirements

- Apple Silicon Mac (aarch64-darwin)
- macOS 15+ (macOS 26 required for volume mounts and full networking)
- nix-darwin

## Usage

Add the flake input:

```nix
{
  inputs = {
    nix-apple-container.url = "github:halfwhey/nix-apple-container";
    nix-apple-container.inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Import the module in your darwin host config:

```nix
{ inputs, ... }: {
  imports = [ inputs.nix-apple-container.darwinModules.default ];

  services.containerization = {
    enable = true;

    containers.web = {
      image = "nginx:alpine";
      autoStart = true;
      extraArgs = [ "--publish" "8080:80" ];
    };
  };
}
```

After `darwin-rebuild switch`, the container runtime starts, the image is pulled, and the container runs as a launchd user agent. Changing any container option (image, env, volumes, ports) and rebuilding will automatically stop the old container and start a fresh one with the new config.

## Options

### `services.containerization`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Install the CLI, start the runtime, enable the module |
| `user` | string | `config.system.primaryUser` | User to run container commands as (activation scripts run as root) |
| `package` | package | *built from .pkg* | Override the container CLI package |
| `images` | attrs of packages | `{}` | nix2container images to load (see [Nix-built images](#nix-built-images-with-nix2container)) |

### `services.containerization.kernel`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `package` | package | *kata 3.26.0 arm64* | Kata kernel tarball — lives in Nix store, survives teardown |
| `binaryPath` | string | `"opt/kata/share/..."` | Path to the kernel binary within the tar archive |

### `services.containerization.containers.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | string | *required* | Image name:tag (pulled from registry if not local) |
| `autoStart` | bool | `false` | Run via launchd user agent on login |
| `cmd` | list of strings | `[]` | Override the image CMD |
| `env` | attrs of strings | `{}` | Environment variables |
| `volumes` | list of strings | `[]` | Volume mounts (`host-path:container-path`, macOS 26+) |
| `autoCreateMounts` | bool | `true` | Create host directories for volume mounts if they don't exist |
| `entrypoint` | string or null | `null` | Override the image entrypoint |
| `user` | string or null | `null` | Run as UID or UID:GID |
| `workdir` | string or null | `null` | Override working directory |
| `init` | bool | `false` | Run init for signal forwarding and zombie reaping |
| `ssh` | bool | `false` | Forward SSH agent from host |
| `network` | string or null | `null` | Attach to custom network (macOS 26+) |
| `readOnly` | bool | `false` | Read-only root filesystem |
| `labels` | attrs of strings | `{}` | Container labels for metadata |
| `pull` | enum | `"missing"` | `"missing"`, `"always"`, or `"never"` — image pull policy |
| `extraArgs` | list of strings | `[]` | Extra arguments passed to `container run` (e.g. `--publish`, `--cpus`, `--memory`) |

### `services.containerization.gc`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `automatic` | bool | `false` | Run garbage collection on activation |
| `pruneContainers` | enum | `"stopped"` | `"none"`, `"stopped"`, or `"running"` |
| `pruneImages` | bool | `false` | Remove unused images |

`pruneContainers` strategies:
- `"none"` — don't touch containers
- `"stopped"` — remove stopped containers
- `"running"` — stop and remove containers not declared in config, then prune stopped

> Note: Containers removed from config are always stopped and cleaned up on rebuild, regardless of GC settings. The GC options control cleanup of ad-hoc containers created outside your Nix config.

### `services.containerization.teardown`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `removeImages` | bool | `false` | Remove pulled images when disabling. If false, images survive disable/enable cycles |

### `services.containerization.linuxBuilder`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Run a Nix builder container for aarch64-linux builds |
| `image` | string | `"ghcr.io/halfwhey/nix-builder:latest"` | Builder container image |
| `sshPort` | port | `31022` | Host port for SSH to the builder |
| `maxJobs` | int | `4` | Max parallel build jobs |

Runs a Nix builder container for aarch64-linux builds. Uses a known SSH key pair (builder only listens on localhost). Writes to `/etc/nix/nix.custom.conf` (Determinate Nix compatible).

**Bootstrap**: First rebuild starts the builder. Second rebuild can use it for Linux derivations (e.g. nix2container images with `aarch64-linux` packages).

## Examples

### Minimal

```nix
services.containerization.enable = true;
```

### Web server with port forwarding

```nix
services.containerization = {
  enable = true;
  containers.nginx = {
    image = "nginx:alpine";
    autoStart = true;
    extraArgs = [ "--publish" "8080:80" ];
  };
};
```

### Gitea with persistent storage

```nix
services.containerization = {
  enable = true;
  containers.gitea = {
    image = "gitea/gitea:latest";
    autoStart = true;
    volumes = [
      "/Users/me/.gitea/data:/data"
    ];
    extraArgs = [
      "--publish" "3000:3000"
      "--publish" "2222:22"
    ];
  };
};
```

### Aggressive garbage collection

```nix
services.containerization = {
  enable = true;
  gc.automatic = true;
  gc.pruneContainers = "running";
  gc.pruneImages = true;
};
```

### Custom kernel version

```nix
services.containerization = {
  enable = true;
  kernel.package = pkgs.fetchurl {
    url = "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst";
    hash = "sha256-g89Z0G72ZWUzj3jrR8NKSIXY15MSF4ZQ77Wyza01eSI=";
  };
  kernel.binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.5-177";
};
```

### Nix-built images with nix2container

Build OCI images with [nix2container](https://github.com/nlewo/nix2container) and load them into the container runtime without storing full tarballs in the Nix store. Only a tiny JSON metadata file lives in the store — layers are streamed on-the-fly from existing Nix store paths at activation time.

Add the nix2container flake input:

```nix
{
  inputs = {
    nix2container.url = "github:nlewo/nix2container";
    nix2container.inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Then declare images and containers. Images must contain `aarch64-linux` packages since Apple containers run Linux VMs:

```nix
{ inputs, pkgs, ... }:
let
  nix2container = inputs.nix2container.packages.${pkgs.system}.nix2container;
  pkgsLinux = import pkgs.path { system = "aarch64-linux"; };
in {
  services.containerization = {
    enable = true;
    linuxBuilder.enable = true;  # needed to build aarch64-linux derivations

    images.greeter = nix2container.buildImage {
      name = "greeter";
      tag = "latest";
      config.Cmd = [
        "${pkgsLinux.busybox}/bin/sh" "-c"
        "echo 'Listening on :8080...' && while true; do echo -e 'HTTP/1.1 200 OK\r\n\r\nHello from a Nix-built container!' | ${pkgsLinux.busybox}/bin/nc -l -p 8080; done"
      ];
    };

    containers.greeter = {
      image = "greeter:latest";
      autoStart = true;
      pull = "never";  # image is loaded locally, not from a registry
      extraArgs = [ "--publish" "8080:8080" ];
    };
  };
}
```

Test it with `curl http://localhost:8080` after rebuild.

Images are only re-loaded when their content changes (tracked via Nix store path). Removing an image from config cleans up the tracking marker; the image data itself is cleaned up by `gc.pruneImages`.

> **Note**: Building nix2container images requires `aarch64-linux` packages. Enable `linuxBuilder` and rebuild twice: the first starts the builder, the second builds and loads the image.

## Uninstall

Set `enable = false` and rebuild. The module will:

1. Stop the container runtime
2. Remove kernels and API server state (cheap to reinstall from Nix store)
3. Clear user preference defaults and `.pkg` install receipts
4. Launchd agents are removed automatically by nix-darwin

Pulled images are preserved by default. Set `teardown.removeImages = true` to remove everything.

If you remove the module import entirely (instead of `enable = false`), no cleanup runs. Keep the import with `enable = false` first, rebuild, then remove the import.

## License

Apache-2.0
