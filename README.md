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
- Optional Linux builder container for building `aarch64-linux` derivations on macOS
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
Apple Container: container CLI version 0.10.0 (build: release, commit: 6bdb647)
nix-darwin: github:LnL7/nix-darwin/da529ac (2026-03-08)
nixpkgs: github:nixos/nixpkgs/e802360 (2026-03-14)
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
    # nix-apple-container.url = "github:halfwhey/nix-apple-container/v0.0.2";

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

See [docs/options.md][options] for the full option reference — `services.containerization`, containers, kernel, images, and linuxBuilder.

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

  package = pkgs.callPackage "${inputs.nix-apple-container}/package.nix" {
    version = "0.11.0";
    hash = "sha256-...";
  };

  kernel = pkgs.callPackage "${inputs.nix-apple-container}/kernel.nix" {
    version = "3.27.0";
    hash = "sha256-...";
  };
};
```

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
      extraArgs = [ "--publish" "8080:8080" ];
    };
  };
}
```

Test it with `curl http://localhost:8080` after rebuild.

Images are loaded into the runtime via `container image load` at activation time. The load is idempotent — images already present are skipped.

> **Note**: Building nix2container images requires `aarch64-linux` packages. Enable `linuxBuilder` and rebuild twice: the first starts the builder, the second builds and loads the image.

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
4. Remove builder SSH key (`/etc/nix/builder_ed25519*`) if present
5. Clear user preference defaults and `.pkg` install receipts

If you remove the module import entirely (instead of `enable = false`), no cleanup runs. Keep the import with `enable = false` first, rebuild, then remove the import. If you find any lingering artifacts please open an issue.

[apple-containerization]: https://github.com/apple/containerization
[nix-darwin]: https://github.com/LnL7/nix-darwin
[nix2container]: https://github.com/nlewo/nix2container
[options]: docs/options.md
