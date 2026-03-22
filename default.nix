{ config, lib, pkgs, ... }:

let
  cfg = config.services.containerization;
  bin = lib.getExe cfg.package;
  runAs = "sudo -u ${cfg.user} --";

  imageSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.package;
        description =
          "OCI image derivation (e.g. from dockerTools.buildLayeredImage).";
      };
      autoLoad = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description =
          "Load this image into the container runtime on activation.";
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
    echo "nix-apple-container: loading image ${name}..."
    ${runAs} ${bin} image load < ${img.image}
  '') autoLoadImages);

  declaredContainerNames =
    lib.concatStringsSep " " (lib.attrNames cfg.containers);

  gcScript = lib.concatStrings [
    (lib.optionalString (cfg.gc.pruneContainers == "stopped") ''
      echo "nix-apple-container: pruning stopped containers..."
      ${runAs} ${bin} prune || true
    '')
    (lib.optionalString (cfg.gc.pruneContainers == "running") ''
      echo "nix-apple-container: pruning containers not in config..."
      DECLARED="${declaredContainerNames}"
      for cid in $(${runAs} ${bin} ls --all --format json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[].configuration.id // empty' 2>/dev/null); do
        KEEP=false
        for d in $DECLARED; do
          if [ "$cid" = "$d" ]; then KEEP=true; break; fi
        done
        if [ "$KEEP" = "false" ]; then
          echo "nix-apple-container: removing undeclared container $cid..."
          ${runAs} ${bin} stop "$cid" 2>/dev/null || true
          ${runAs} ${bin} rm "$cid" 2>/dev/null || true
        fi
      done
      ${runAs} ${bin} prune || true
    '')
    (lib.optionalString cfg.gc.pruneImages ''
      echo "nix-apple-container: pruning unused images..."
      ${runAs} ${bin} image prune || true
    '')
  ];

  mkContainerArgs = name: c:
    [ bin "run" "--name" name ] ++ (lib.concatMap (e: [ "--env" e ])
      (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
    ++ (lib.concatMap (v: [ "--volume" v ]) c.volumes) ++ c.extraArgs
    ++ [ c.image ] ++ c.cmd;

in {
  options.services.containerization = {
    enable = lib.mkEnableOption "Apple Containerization framework";

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description =
        "User to run container commands as (activation runs as root).";
    };

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
        type = lib.types.enum [ "none" "stopped" "running" ];
        default = "stopped";
        description = ''
          Container cleanup strategy during gc.
          - "none": don't touch containers
          - "stopped": remove stopped containers not in config
          - "running": stop and remove containers not in config
        '';
      };
      pruneImages = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Remove unused images during gc.";
      };
    };
  };

  config = lib.mkMerge [
    # Teardown: runs when module is disabled (guarded — only if state exists)
    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        CONTAINER_HOME=$(eval echo "~${cfg.user}")
        APP_SUPPORT="$CONTAINER_HOME/Library/Application Support/com.apple.container"

        if [ -d "$APP_SUPPORT" ]; then
          echo "nix-apple-container: tearing down..."

          ${runAs} ${bin} system stop 2>/dev/null || true

          echo "nix-apple-container: removing data ($APP_SUPPORT)..."
          rm -rf "$APP_SUPPORT"

          ${runAs} defaults delete com.apple.container 2>/dev/null || true

          pkgutil --pkg-info com.apple.container-installer &>/dev/null && \
            sudo pkgutil --forget com.apple.container-installer 2>/dev/null || true
        fi
      '';
    })

    # Setup: runs when module is enabled
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];

      launchd.user.agents = lib.mapAttrs' (name: c:
        lib.nameValuePair "container-${name}" {
          serviceConfig = {
            Label = "dev.apple.container.${name}";
            ProgramArguments = mkContainerArgs name c;
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath =
              "/Users/${cfg.user}/Library/Logs/container-${name}.log";
            StandardErrorPath =
              "/Users/${cfg.user}/Library/Logs/container-${name}.err";
          };
        }) autoStartContainers;

      # GC runs before launchd setup so stale containers are cleaned
      # before new ones try to start
      system.activationScripts.preActivation.text = lib.mkAfter
        (lib.concatStrings [
          ''
            if ! ${runAs} ${bin} system info &>/dev/null; then
              echo "nix-apple-container: starting runtime..."
              ${runAs} ${bin} system start --disable-kernel-install 2>/dev/null || true
            fi
            KERNEL_DIR="$(eval echo "~${cfg.user}")/Library/Application Support/com.apple.container/kernels"
            if [ ! -d "$KERNEL_DIR" ] || [ -z "$(ls -A "$KERNEL_DIR" 2>/dev/null)" ]; then
              echo "nix-apple-container: installing kernel..."
              ${runAs} ${bin} system kernel set --recommended 2>/dev/null || true
            fi
          ''
          (lib.optionalString cfg.gc.automatic gcScript)
        ]);

      # Image loading runs after launchd setup
      system.activationScripts.postActivation.text = lib.mkAfter
        (lib.optionalString (autoLoadImages != { }) ''
          echo "nix-apple-container: loading images..."
          ${imageLoadScript}
        '');
    })
  ];
}
