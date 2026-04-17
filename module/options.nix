{
  config,
  lib,
  pkgs,
  ...
}:

let
  defaultKernel = pkgs.callPackage ../pkgs/kernel.nix { };

  containerSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.str;
        description = "Image name:tag to run (local or registry).";
      };
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically start this container via launchd. When false, the container name is reserved (prevents drift cleanup) but no container is created or managed.";
      };
      cmd = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Override the image CMD.";
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables for the container.";
      };
      volumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Volume mounts (macOS 26+). Use host:container for bind mounts or name:container for named volumes. Every entry must contain a ':'.";
      };
      autoCreateMounts = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically create host directories for volume mounts if they don't exist.";
      };
      entrypoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override the image entrypoint.";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Run as this user (UID or UID:GID).";
      };
      workdir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override the working directory inside the container.";
      };
      init = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run an init process for signal forwarding and zombie reaping.";
      };
      ssh = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Forward SSH agent from host into the container.";
      };
      network = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Attach to a custom network (macOS 26+).";
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mount the container's root filesystem as read-only.";
      };
      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Container labels for metadata and filtering.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments passed to 'container run'.";
      };
    };
  };
in
{
  options.services.containerization = {
    enable = lib.mkEnableOption "Apple Containerization framework";

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description = "User to run container commands as (activation runs as root).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/package.nix { };
      description = "The container CLI package.";
    };

    containers = lib.mkOption {
      type = lib.types.attrsOf containerSubmodule;
      default = { };
      description = "Containers to manage.";
    };

    images = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      description = "nix2container images to load. Each value must be a nix2container buildImage output with copyTo, imageName, and imageTag attributes.";
    };

    kernel = lib.mkOption {
      type = lib.types.package;
      default = defaultKernel;
      description = "Kernel binary (flat file derivation). The default extracts the kata-containers kernel. The store path is symlinked directly as default.kernel-arm64.";
    };

    preserveImagesOnDisable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep loaded images when the module is disabled. By default, teardown removes all runtime state.";
    };

    preserveVolumesOnDisable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep named volume data when the module is disabled. Best-effort based on known runtime directory layout. Bind mounts are always preserved (they live on the host).";
    };
  };
}
