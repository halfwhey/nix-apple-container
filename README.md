<div align="center">

# nix-apple-container

A nix-darwin module for declaratively managing [Apple Containerization][apple-containerization] — Apple's native Linux container runtime for Apple Silicon Macs.

[What it does](#what-it-does) •
[Getting started](#getting-started) •
[Options][options] •
[Examples](#examples) •
[Uninstall](#uninstall)

</div>

## What it does

- Packages the `container` CLI from Apple's `.pkg` release via Nix
- Manages the Kata Linux kernel as a Nix derivation (no runtime download from GitHub)
- Starts the container runtime and installs the kernel automatically
- Declares containers that run as launchd user agents (automatically recreated on config change)
- Containers are addressable by name from the host and from other containers (e.g. `foo.test` for a container named `foo`)
- Auto-creates host directories for volume mounts
- Optional Linux builder containers for building `aarch64-linux` and `x86_64-linux` derivations on macOS
- Reconciles running containers against config — removes undeclared containers and their launchd agents
- Builds and loads Nix-built OCI images via [nix2container][nix2container] — no tarballs in the Nix store

> **Runtime ownership**: This module fully owns the configured user's Apple container runtime. Undeclared containers are treated as drift and removed on rebuild. nix2container images are loaded via `container image load` at activation time; registry images are pulled by the runtime automatically when a container starts. Disabling the module tears down the runtime wholesale.

## Getting started

### Requirements

- Apple Silicon Mac (aarch64-darwin)
- macOS 15+ (macOS 26 required for volume mounts and full networking)
- [nix-darwin][nix-darwin]

<details>
<summary>Tested on</summary>

```
macOS: 26.3 (25D125)
Arch: arm64
Nix: nix (Determinate Nix 3.17.1) 2.33.3
Apple Container: container CLI version 0.11.0 (build: release, commit: d9b8a8d)
nix-darwin: github:LnL7/nix-darwin/06648f4 (2026-04-01)
nixpkgs: github:NixOS/nixpkgs/a62e6ed (2024-05-31)
```

</details>

### Installation

Add the flake input:

```nix
{
  inputs = {
    # Follow master — picks up nix-builder image updates automatically:
    nix-apple-container.url = "github:halfwhey/nix-apple-container";
    # Pin to a release for stability:
    # nix-apple-container.url = "github:halfwhey/nix-apple-container/v0.0.5";

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

After `darwin-rebuild switch`, the container runtime starts, the image is pulled from the registry, and the container runs as a launchd user agent. Changing any container option (image, env, volumes, ports) and rebuilding will automatically stop the old container and start a fresh one with the new config.

## Options

See [docs/options.md][options] for the full option reference — `services.containerization`, containers, kernel, images, and linux-builder.

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

### Custom versions

Override `package` (apple/container CLI) or `kernel` (kata-containers) with a different version:

```nix
services.containerization = {
  enable = true;

  package = pkgs.callPackage "${inputs.nix-apple-container}/pkgs/package.nix" {
    version = "0.11.0";
    hash = "sha256-...";
  };

  kernel = pkgs.callPackage "${inputs.nix-apple-container}/pkgs/kernel.nix" {
    version = "3.27.0";
    hash = "sha256-...";
  };
};
```

The runtime default kernel (`services.containerization.kernel`) is separate from
the per-builder kernel used by `linux-builder.<arch>.kernel`. By default,
`linux-builder.x86_64.kernel` is pinned to Kata `3.24.0` and passed via
`container run --kernel` to avoid Rosetta regressions with newer kernels.

The builder image tag is versioned independently from the base `nixos/nix`
version. Tags use the form `<builder-version>-nix<nix-version>`, for example
`v2-nix2.34.6`.

For a fully custom kernel (different source or extraction logic), pass any flat-file derivation to `kernel`:

```nix
services.containerization.kernel = pkgs.stdenv.mkDerivation {
  pname = "my-kernel";
  version = "3.26.0";
  outputHash = "sha256-...";
  outputHashMode = "flat";
  nativeBuildInputs = with pkgs; [ cacert curl zstd gnutar ];
  buildCommand = ''
    curl -L -o kata.tar.zst "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst"
    tar --zstd -xf kata.tar.zst ./opt/kata/share/kata-containers/
    cp -L ./opt/kata/share/kata-containers/vmlinux.container $out
  '';
};
```

### Nix-built images with nix2container

Build OCI images with [nix2container][nix2container] and load them into the container runtime without storing full tarballs in the Nix store. Only a tiny JSON metadata file lives in the store — layers are streamed on-the-fly from existing Nix store paths at activation time.

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
    linux-builder.aarch64.enable = true;  # needed to build aarch64-linux derivations

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
      extraArgs = [ "--publish" "8080:8080" ];
    };
  };
}
```

Test it with `curl http://localhost:8080` after rebuild.

Images are loaded into the runtime via `container image load` at activation time. The load is idempotent — images already present are skipped.

> **Note**: Building nix2container images requires `aarch64-linux` packages. Enable `linux-builder.aarch64` and rebuild twice: the first starts the builder, the second builds and loads the image.

### Cross-architecture Linux builds

Build `x86_64-linux` and `aarch64-linux` derivations on Apple Silicon:

```nix
services.containerization = {
  enable = true;
  linux-builder = {
    aarch64.enable = true;  # aarch64-linux builder
    x86_64.enable = true;   # x86_64-linux builder 
  };
};
```

Each architecture runs its own builder container. Both share the same multi-arch image and SSH key. The `x86_64` builder uses the runtime name `nix-builder-amd64` and listens on port 31023 by default (configurable via `linux-builder.x86_64.sshPort`).

The x86_64 builder also has its own per-container kernel option:

```nix
services.containerization.linux-builder.x86_64.kernel =
  pkgs.callPackage "${inputs.nix-apple-container}/pkgs/kernel.nix" {
    version = "3.24.0";
    hash = "sha256-2pNP+CBvV4DBAeGiwIe8MpdasjcDhc9L2tcRArP7ANw=";
  };
```

Set it to `null` to use the runtime default kernel instead.

### Registry images

Containers referencing images not in `images.*` are pulled automatically by the container runtime when `container run` is invoked. No Nix-side configuration is needed — just declare the container:

```nix
services.containerization = {
  enable = true;

  containers.alpine = {
    image = "alpine:latest";
    autoStart = true;
  };
};
```

## Uninstall

Set `enable = false` and rebuild. The module will:

1. Unload all container launchd agents
2. Stop the container runtime
3. Remove runtime state (`~/Library/Application Support/com.apple.container/`) — respects `preserveImagesOnDisable` and `preserveVolumesOnDisable`
4. Remove builder SSH key (`~/.ssh/nix-builder_ed25519*`) and legacy `/etc/nix/builder_ed25519*` if present
5. Clear user preference defaults and `.pkg` install receipts

If you remove the module import entirely (instead of `enable = false`), no cleanup runs. Keep the import with `enable = false` first, rebuild, then remove the import. If you find any lingering artifacts please open an issue.

### Standalone uninstall

If you've already removed the module import, or prefer a one-command cleanup:

```
nix run github:halfwhey/nix-apple-container#uninstall
```

This performs the same teardown as `enable = false` — stops the runtime, removes agents, cleans up state. Accepts `--preserve-images`, `--preserve-volumes`, and `--yes` (skip confirmation).

## Troubleshooting

### VPN breaks container networking

Active VPN or tunnel interfaces (`utun*`) break the vmnet port forwarding used by `--publish`. Symptoms include `curl: (56) Connection reset by peer` on published ports and failure to resolve `.test` DNS names — even though the container itself is running normally.

This is a [known upstream issue][vpn-issue]. The only current workaround is to disconnect the VPN before starting containers. macOS 26 is expected to overhaul container networking.

To check for active tunnel interfaces:

```bash
ifconfig | grep utun
```

### Headless Mac: permission popups block container startup

On headless Mac minis (or any Mac without a display), macOS may present GUI permission dialogs for network or volume access the first time a container starts. These popups are invisible over SSH and will silently block the container from launching.

Connect a display (or use screen sharing) and approve the permission prompts. Once granted, the permissions persist across reboots.

[apple-containerization]: https://github.com/apple/containerization
[nix-darwin]: https://github.com/LnL7/nix-darwin
[nix2container]: https://github.com/nlewo/nix2container
[options]: docs/options.md
[vpn-issue]: https://github.com/apple/container/issues/1307
