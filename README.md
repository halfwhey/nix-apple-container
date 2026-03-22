# nix-apple-container

> **Alpha** — this module is functional but under active development. Options may change.

A nix-darwin module for declaratively managing [Apple Containerization](https://github.com/apple/containerization) — Apple's native Linux container runtime for Apple Silicon Macs.

## What it does

- Packages the `container` CLI from Apple's `.pkg` release via Nix (no Homebrew needed)
- Starts the container runtime and installs the Linux kernel automatically
- Declares containers that run as launchd user agents
- Loads Nix-built OCI images (via `dockerTools`) into the runtime on activation
- Garbage-collects containers and images not in your config
- Clean teardown when disabled — stops runtime, removes kernels, clears user data

## Requirements

- Apple Silicon Mac (aarch64-darwin)
- macOS 15+ (macOS 26 recommended for full networking support)
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

After `darwin-rebuild switch`, the container runtime starts, the image is pulled, and the container runs as a launchd user agent.

## Options

### `services.containerization`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Install the CLI, start the runtime, enable the module |
| `user` | string | `config.system.primaryUser` | User to run container commands as (activation scripts run as root) |
| `package` | package | *built from .pkg* | Override the container CLI package |

### `services.containerization.containers.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | string | *required* | Image name:tag (pulled from registry if not local) |
| `autoStart` | bool | `false` | Run via launchd user agent on login |
| `cmd` | list of strings | `[]` | Override the image CMD |
| `env` | attrs of strings | `{}` | Environment variables |
| `volumes` | list of strings | `[]` | Volume mounts (`host-path:container-path`) |
| `extraArgs` | list of strings | `[]` | Extra arguments passed to `container run` |

Common `extraArgs` flags:

| Flag | Example | Description |
|------|---------|-------------|
| `--publish` | `"8080:80"` | Port forwarding (host:container) |
| `--cpus` | `"4"` | CPU count |
| `--memory` | `"2g"` | Memory limit |
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

## Uninstall

Set `enable = false` and rebuild. The module will:

1. Stop the container runtime
2. Remove `~/Library/Application Support/com.apple.container/`
3. Clear user preference defaults
4. Clean up any `.pkg` install receipts
5. Launchd agents are removed automatically by nix-darwin

## License

Apache-2.0
