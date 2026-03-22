# nix-apple-container

> **Alpha** — this module is functional but under active development. Options may change.

A nix-darwin module for declaratively managing [Apple Containerization](https://github.com/apple/containerization) — Apple's native Linux container runtime for Apple Silicon Macs.

## What it does

- Packages the `container` CLI from Apple's `.pkg` release via Nix (no Homebrew needed)
- Manages the Linux kernel as a Nix derivation (no runtime download from GitHub)
- Starts the container runtime and installs the kernel automatically
- Declares containers that run as launchd user agents (automatically recreated on config change)
- Loads Nix-built OCI images (via `dockerTools`) into the runtime on activation
- Auto-creates host directories for volume mounts
- Reconciles running containers against config — removes undeclared containers and their launchd agents
- Garbage-collects containers and images not in your config
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
    nix-apple-container.url = "github:your-user/nix-apple-container";
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
| `pull` | enum | `"missing"` | `"missing"`, `"always"`, or `"never"` — image pull policy |
| `extraArgs` | list of strings | `[]` | Extra arguments passed to `container run` |

Common `extraArgs` flags:

| Flag | Example | Description |
|------|---------|-------------|
| `--publish` | `"8080:80"` | Port forwarding (host:container) |
| `--cpus` | `"4"` | CPU count |
| `--memory` | `"2g"` | Memory limit (pre-allocated to VM) |
| `--workdir` | `"/app"` | Working directory |
| `--user` | `"1000:1000"` | Run as UID:GID |
| `--rm` | | Auto-remove on exit |
| `--init` | | Signal forwarding + zombie cleanup |
| `--ssh` | | Forward SSH agent |
| `--dns` | `"1.1.1.1"` | DNS nameserver |
| `--network` | `"my-net"` | Attach to network (macOS 26) |
| `--rosetta` | | Rosetta emulation |

### `services.containerization.images.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | package | *required* | OCI image derivation (e.g. `dockerTools.buildLayeredImage`) |
| `autoLoad` | bool | `true` | Load into the runtime on activation |

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

### Nix-built OCI image

```nix
services.containerization = {
  enable = true;

  images.dev = {
    image = pkgsLinux.dockerTools.buildLayeredImage {
      name = "dev";
      tag = "latest";
      contents = with pkgsLinux; [ bashInteractive coreutils git ];
      config.Cmd = [ "/bin/bash" ];
    };
  };

  containers.dev = {
    image = "dev:latest";
    autoStart = false; # run manually: container run -it dev:latest
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
