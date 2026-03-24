{ config, lib, pkgs, ... }:

let
  cfg = config.services.containerization;
  bin = lib.getExe cfg.package;
  runAs = "sudo -u ${cfg.user} --";

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

  imageLoadScript = let
    declaredImageNames = lib.concatStringsSep " " (lib.attrNames cfg.images);
  in lib.optionalString (cfg.images != { }) ''
    MARKER_DIR="/var/lib/nix-apple-container/images"
    mkdir -p "$MARKER_DIR"

    ${lib.concatStrings (lib.mapAttrsToList (name: img: ''
      if [ "$(cat "$MARKER_DIR/${name}" 2>/dev/null)" != "${img.copyTo}" ]; then
        echo "nix-apple-container: loading image ${img.imageName}:${img.imageTag}..."
        tmpdir=$(mktemp -d -t nix-apple-container-image.XXXXXX)
        "${img.copyTo}/bin/copy-to" "oci:$tmpdir:${img.imageName}:${img.imageTag}"
        tar -C "$tmpdir" -cf "$tmpdir.tar" .
        chmod 644 "$tmpdir.tar"
        ${runAs} ${bin} image load -i "$tmpdir.tar"
        rm -rf "$tmpdir" "$tmpdir.tar"
        echo "${img.copyTo}" > "$MARKER_DIR/${name}"
      fi
    '') cfg.images)}

    # Clean stale markers for images no longer in config
    DECLARED_IMAGES="${declaredImageNames}"
    for marker in "$MARKER_DIR"/*; do
      [ -f "$marker" ] || continue
      mname="$(basename "$marker")"
      KEEP=false
      for d in $DECLARED_IMAGES; do
        if [ "$mname" = "$d" ]; then KEEP=true; break; fi
      done
      if [ "$KEEP" = "false" ]; then
        rm -f "$marker"
      fi
    done
  '';

  mkContainerRunScript = name: c:
    let
      args = [ bin "run" "--name" name ]
        ++ lib.optionals (c.entrypoint != null) [ "--entrypoint" c.entrypoint ]
        ++ lib.optionals (c.user != null) [ "--user" c.user ]
        ++ lib.optionals (c.workdir != null) [ "--workdir" c.workdir ]
        ++ lib.optional c.init "--init"
        ++ lib.optional c.ssh "--ssh"
        ++ lib.optional c.readOnly "--read-only"
        ++ lib.optionals (c.network != null) [ "--network" c.network ]
        ++ (lib.concatMap (e: [ "--env" e ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
        ++ (lib.concatMap (l: [ "--label" l ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") c.labels))
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

    containers = lib.mkOption {
      type = lib.types.attrsOf containerSubmodule;
      default = { };
      description = "Containers to manage.";
    };

    images = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      description = "nix2container images to load. Each value must be a nix2container buildImage output with copyTo, imageName, and imageTag passthru attributes.";
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

    linuxBuilder = {
      enable = lib.mkEnableOption "Linux builder container for aarch64-linux builds";
      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/halfwhey/nix-builder:latest";
        description = "Docker image for the Nix remote builder.";
      };
      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 31022;
        description = "Host port for SSH to the builder container.";
      };
      maxJobs = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Maximum number of parallel build jobs on the builder.";
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

          ${lib.optionalString cfg.teardown.removeImages ''
            echo "nix-apple-container: removing images..."
            rm -rf "$APP_SUPPORT/content"
            rm -rf "$APP_SUPPORT"
          ''}

          ${runAs} defaults delete com.apple.container 2>/dev/null || true

          pkgutil --pkg-info com.apple.container-installer &>/dev/null && \
            sudo pkgutil --forget com.apple.container-installer 2>/dev/null || true
        fi

        rm -rf /var/lib/nix-apple-container
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
          imageLoadScript
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
      );
    })

    # Linux builder cleanup
    (lib.mkIf (cfg.enable && !cfg.linuxBuilder.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        if [ -f /etc/nix/builder_ed25519 ]; then
          echo "nix-apple-container: removing linux builder resources..."
          rm -f /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub
          rm -f /etc/nix/nix.custom.conf
          rm -f /etc/nix/machines
          rm -f /etc/ssh/ssh_config.d/200-nix-builder.conf
        fi
      '';
    })

    # Linux builder
    (lib.mkIf (cfg.enable && cfg.linuxBuilder.enable) {
      services.containerization.containers.nix-builder = {
        image = cfg.linuxBuilder.image;
        autoStart = true;
        extraArgs = [
          "--publish" "${toString cfg.linuxBuilder.sshPort}:22"
        ];
      };

      system.activationScripts.preActivation.text = lib.mkAfter ''
        install -m 600 ${./builder/builder_ed25519} /etc/nix/builder_ed25519
        install -m 644 ${./builder/builder_ed25519.pub} /etc/nix/builder_ed25519.pub
      '';

      system.activationScripts.postActivation.text = lib.mkAfter ''
        echo "nix-apple-container: waiting for linux builder..."
        for _i in $(seq 1 30); do
          if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -i /etc/nix/builder_ed25519 -p ${toString cfg.linuxBuilder.sshPort} \
               root@localhost true 2>/dev/null; then
            break
          fi
          sleep 1
        done

        # SSH config to skip host key checking for the builder (localhost only)
        mkdir -p /etc/ssh/ssh_config.d
        printf '%s\n' \
          'Host nix-builder' \
          '  HostName localhost' \
          '  Port ${toString cfg.linuxBuilder.sshPort}' \
          '  User root' \
          '  IdentityFile /etc/nix/builder_ed25519' \
          '  StrictHostKeyChecking no' \
          '  UserKnownHostsFile /dev/null' \
          > /etc/ssh/ssh_config.d/200-nix-builder.conf

        # Configure builder in nix.custom.conf (Determinate Nix)
        printf '%s\n' 'builders = @/etc/nix/machines' 'builders-use-substitutes = true' > /etc/nix/nix.custom.conf

        echo "ssh://nix-builder aarch64-linux /etc/nix/builder_ed25519 ${toString cfg.linuxBuilder.maxJobs} 1 big-parallel - -" > /etc/nix/machines

        # Restart Nix daemon to pick up config changes
        launchctl kickstart -k system/systems.determinate.nix-daemon 2>/dev/null || \
          launchctl kickstart -k system/org.nixos.nix-daemon 2>/dev/null || true
      '';
    })
  ];
}
