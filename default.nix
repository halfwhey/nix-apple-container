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
      autoCreateMounts = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically create host directories for volume mounts if they don't exist.";
      };
      pull = lib.mkOption {
        type = lib.types.enum [ "missing" "always" "never" ];
        default = "missing";
        description = ''
          Image pull policy.
          - "missing": pull only if not cached locally (default)
          - "always": pull before every start (keeps mutable tags like :latest fresh)
          - "never": never pull (image must exist locally)
        '';
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

  # Extract host paths from volume strings (host:container) for containers with autoCreateMounts
  mkMountDirsScript = lib.concatStrings (lib.mapAttrsToList (name: c:
    lib.optionalString (c.autoCreateMounts && c.volumes != [ ]) (
      lib.concatMapStrings (v:
        let hostPath = builtins.head (lib.splitString ":" v);
        in ''
          if [ ! -d "${hostPath}" ]; then
            echo "nix-apple-container: creating mount ${hostPath} for ${name}..."
            ${runAs} mkdir -p "${hostPath}"
          fi
        ''
      ) c.volumes
    )
  ) cfg.containers);

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

  mkContainerRunScript = name: c:
    let
      args = [ bin "run" "--name" name ]
        ++ (lib.concatMap (e: [ "--env" e ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
        ++ (lib.concatMap (v: [ "--volume" v ]) c.volumes)
        ++ c.extraArgs
        ++ [ c.image ]
        ++ c.cmd;
    in pkgs.writeShellScript "container-run-${name}" ''
      ${bin} stop ${lib.escapeShellArg name} 2>/dev/null || true
      ${bin} rm ${lib.escapeShellArg name} 2>/dev/null || true
      ${lib.optionalString (c.pull == "always") ''
        ${bin} image pull ${lib.escapeShellArg c.image} || true
      ''}
      exec ${lib.escapeShellArgs args}
    '';

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

    kernel = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./kernel.nix { };
        description = "Kata kernel tarball (passed to container system kernel set --tar).";
      };
      binaryPath = lib.mkOption {
        type = lib.types.str;
        default = "opt/kata/share/kata-containers/vmlinux-6.18.5-177";
        description = "Path to the kernel binary within the tar archive.";
      };
    };

    teardown.removeImages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Remove pulled container images when disabling. If false, only runtime state and kernels are removed.";
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

          # Kernels are cheap to reinstall from Nix store
          rm -rf "$APP_SUPPORT/kernels"

          # API server plist is regenerated on system start
          rm -rf "$APP_SUPPORT/apiserver"

          if [ "${lib.boolToString cfg.teardown.removeImages}" = "true" ]; then
            echo "nix-apple-container: removing images..."
            rm -rf "$APP_SUPPORT/content"
            rm -rf "$APP_SUPPORT"
          fi

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
            ProgramArguments = [ (toString (mkContainerRunScript name c)) ];
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
            if ! ${runAs} ${bin} system status &>/dev/null; then
              echo "nix-apple-container: starting runtime..."
              ${runAs} ${bin} system start --disable-kernel-install 2>/dev/null || true
            fi
            KERNEL_DIR="$(eval echo "~${cfg.user}")/Library/Application Support/com.apple.container/kernels"
            if [ ! -d "$KERNEL_DIR" ] || [ -z "$(ls -A "$KERNEL_DIR" 2>/dev/null)" ]; then
              echo "nix-apple-container: installing kernel..."
              ${runAs} ${bin} system kernel set \
                --tar ${cfg.kernel.package} \
                --binary ${cfg.kernel.binaryPath} \
                --force 2>/dev/null || true
            fi
          ''
          mkMountDirsScript
          (lib.optionalString cfg.gc.automatic gcScript)
        ]);

      # Reconcile containers: unload stale launchd agents, then stop+rm undeclared containers.
      # We must unload agents ourselves because nix-darwin's userLaunchd script is conditional
      # on having user agents in the NEW config — if all containers are removed, it never runs
      # and old agents with KeepAlive=true keep restarting containers.
      system.activationScripts.postActivation.text = lib.mkAfter (
        let
          # Plist filenames are based on serviceConfig.Label, not the attribute name
          declaredAgentNames = lib.concatStringsSep " " (map (n: "dev.apple.container.${n}") (lib.attrNames autoStartContainers));
        in ''
          echo "nix-apple-container: reconciling containers..."
          CONTAINER_USER="${cfg.user}"
          CONTAINER_UID=$(id -u "$CONTAINER_USER")
          AGENT_DIR="$(eval echo "~$CONTAINER_USER")/Library/LaunchAgents"
          DECLARED_AGENTS="${declaredAgentNames}"

          # Unload and remove stale launchd agents before stopping containers,
          # otherwise KeepAlive=true restarts them immediately.
          # nix-darwin's userLaunchd cleanup is conditional on having agents in the
          # new config — if all containers are removed, it skips cleanup entirely.
          for plist in "$AGENT_DIR"/dev.apple.container.*.plist; do
            [ -f "$plist" ] || continue
            agent_name="$(basename "$plist" .plist)"
            KEEP=false
            for d in $DECLARED_AGENTS; do
              if [ "$agent_name" = "$d" ]; then KEEP=true; break; fi
            done
            if [ "$KEEP" = "false" ]; then
              echo "nix-apple-container: unloading stale agent $agent_name..."
              launchctl asuser "$CONTAINER_UID" sudo --user="$CONTAINER_USER" -- launchctl unload "$plist" 2>/dev/null || true
              sudo --user="$CONTAINER_USER" -- rm -f "$plist"
            fi
          done

          # Now stop and remove containers not declared in config
          DECLARED="${declaredContainerNames}"
          for cid in $(${runAs} ${bin} ls --all --format json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[].configuration.id // empty' 2>/dev/null); do
            KEEP=false
            for d in $DECLARED; do
              if [ "$cid" = "$d" ]; then KEEP=true; break; fi
            done
            if [ "$KEEP" = "false" ]; then
              echo "nix-apple-container: stopping undeclared container $cid..."
              ${runAs} ${bin} stop "$cid" 2>/dev/null || true
              ${runAs} ${bin} rm "$cid" 2>/dev/null || true
            fi
          done
        ''
        + lib.optionalString (autoLoadImages != { }) ''
          echo "nix-apple-container: loading images..."
          ${imageLoadScript}
        ''
      );
    })
  ];
}
