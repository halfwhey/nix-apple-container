{ config, lib, pkgs, ... }:

let
  cfg = config.services.containerization;
  bin = lib.getExe cfg.package;

  imageSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.package;
        description = "OCI image derivation (e.g. from dockerTools.buildLayeredImage).";
      };
      autoLoad = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Load this image into the container runtime on activation.";
      };
    };
  };

  containerSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.str;
        description = "Image name:tag to run (local or registry).";
      };
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically start this container via launchd.";
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
        description = "Volume mounts (macOS 26+).";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments passed to 'container run'.";
      };
    };
  };

  autoLoadImages = lib.filterAttrs (_: i: i.autoLoad) cfg.images;
  autoStartContainers = lib.filterAttrs (_: c: c.autoStart) cfg.containers;

  imageLoadScript = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: img: ''
    echo "Loading container image: ${name}..."
    ${bin} image load < ${img.image}
  '') autoLoadImages);

  pullScript = lib.concatMapStringsSep "\n" (img: ''
    echo "Pulling image: ${img}..."
    ${bin} image pull ${img}
  '') cfg.pulls;

  gcScript = lib.concatStrings [
    (lib.optionalString cfg.gc.pruneContainers ''
      echo "Pruning stopped containers..."
      ${bin} prune || true
    '')
    (lib.optionalString cfg.gc.pruneImages ''
      echo "Pruning unused images..."
      ${bin} image prune || true
    '')
  ];

  mkContainerArgs = name: c:
    [ bin "run" "--detach" "--name" name ]
    ++ (lib.concatMap (e: [ "--env" e ])
      (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
    ++ (lib.concatMap (v: [ "--volume" v ]) c.volumes)
    ++ c.extraArgs
    ++ [ c.image ]
    ++ c.cmd;

in {
  options.services.containerization = {
    enable = lib.mkEnableOption "Apple Containerization framework";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      description = "The container CLI package.";
    };

    images = lib.mkOption {
      type = lib.types.attrsOf imageSubmodule;
      default = { };
      description = "Nix-built OCI images to load into the container runtime.";
    };

    pulls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ubuntu:latest" "alpine:3.19" ];
      description = "Registry images to pull on activation.";
    };

    containers = lib.mkOption {
      type = lib.types.attrsOf containerSubmodule;
      default = { };
      description = "Containers to manage.";
    };

    gc = {
      automatic = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run garbage collection on activation.";
      };
      pruneContainers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Remove stopped containers during gc.";
      };
      pruneImages = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Remove unused images during gc.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    launchd.daemons = {
      "container-runtime" = {
        serviceConfig = {
          Label = "dev.apple.container-runtime";
          ProgramArguments = [ bin "system" "start" ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/var/log/container-runtime.log";
          StandardErrorPath = "/var/log/container-runtime.err";
        };
      };
    } // lib.mapAttrs' (name: c:
      lib.nameValuePair "container-${name}" {
        serviceConfig = {
          Label = "dev.apple.container.${name}";
          ProgramArguments = mkContainerArgs name c;
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/var/log/container-${name}.log";
          StandardErrorPath = "/var/log/container-${name}.err";
        };
      }
    ) autoStartContainers;

    system.activationScripts.postActivation.text = lib.mkAfter (
      lib.concatStrings [
        (lib.optionalString (autoLoadImages != { }) ''
          echo "Loading container images..."
          ${imageLoadScript}
        '')
        (lib.optionalString (cfg.pulls != [ ]) pullScript)
        (lib.optionalString cfg.gc.automatic gcScript)
      ]
    );
  };
}
