{ config, lib, pkgs, options, ... }:

let
  cfg = config.services.containerization;
  bin = lib.getExe cfg.package;
  runAs = "sudo -u ${cfg.user} --";

  userHome = if config.users.users ? ${cfg.user} then
    config.users.users.${cfg.user}.home
  else
    "/Users/${cfg.user}";

  containerSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.str;
        description = "Image name:tag to run (local or registry).";
      };
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description =
          "Automatically start this container via launchd. When false, the container name is reserved (prevents drift cleanup) but no container is created or managed.";
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
        description =
          "Volume mounts (macOS 26+). Use host:container for bind mounts or name:container for named volumes. Every entry must contain a ':'.";
      };
      autoCreateMounts = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description =
          "Automatically create host directories for volume mounts if they don't exist.";
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
        description =
          "Run an init process for signal forwarding and zombie reaping.";
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

  # Resolve nix2container image metadata (keyed by attr name)
  resolvedImages = lib.mapAttrs (name: img: {
    copyTo = img.copyTo;
    imageName = img.imageName;
    imageTag = img.imageTag;
    imageRef = "${img.imageName}:${img.imageTag}";
  }) cfg.images;

  # Lookup from imageRef → copyTo store path, used to embed a content-dependent
  # comment in container wrapper scripts so plist changes trigger agent restarts.
  nixImagePaths = lib.mapAttrs' (_: r:
    lib.nameValuePair r.imageRef "${r.copyTo}"
  ) resolvedImages;

  appSupport = "${userHome}/Library/Application Support/com.apple.container";
  agentDir = "${userHome}/Library/LaunchAgents";

  # Unload and remove module-owned launchd agents.
  # If declaredAgents is empty, unloads ALL agents (teardown).
  # Otherwise, unloads only agents not in the declared list (reconciliation).
  mkAgentUnloadScript = declaredAgents: ''
    CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
    if [ -n "$CONTAINER_UID" ] && [ -d "${agentDir}" ]; then
      for plist in "${agentDir}"/dev.apple.container.*.plist; do
        [ -f "$plist" ] || continue
        agent_name="$(basename "$plist" .plist)"
        ${
          lib.optionalString (declaredAgents != "") ''
            KEEP=false
            # shellcheck disable=SC2043
            for d in ${declaredAgents}; do
              if [ "$agent_name" = "$d" ]; then KEEP=true; break; fi
            done
            if [ "$KEEP" = "true" ]; then continue; fi
          ''
        }
        echo "nix-apple-container: unloading agent $agent_name..."
        launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- launchctl unload "$plist" 2>/dev/null || true
        sudo --user="${cfg.user}" -- rm -f "$plist"
      done
    fi
  '';

  autoStartContainers = lib.filterAttrs (_: c: c.autoStart) cfg.containers;

  # Extract host paths from volume strings (host:container) for containers with autoCreateMounts
  mkMountDirsScript = lib.concatStrings (lib.mapAttrsToList (name: c:
    lib.optionalString (c.autoCreateMounts && c.volumes != [ ])
    (lib.concatMapStrings (v:
      let hostPath = builtins.head (lib.splitString ":" v);
      in lib.optionalString
      (lib.hasInfix ":" v && lib.hasPrefix "/" hostPath) ''
        if [ ! -d "${hostPath}" ]; then
          echo "nix-apple-container: creating mount ${hostPath} for ${name}..."
          ${runAs} mkdir -p "${hostPath}"
        fi
      '') c.volumes)) cfg.containers);

  # Load nix2container images via `container image load` at activation time.
  # Content-aware: runs copyTo to a temp OCI layout, reads the manifest digest from
  # index.json, and compares against the runtime. Only tars+loads when content differs.
  imageLoadScript = lib.optionalString (cfg.images != { }) ''
    ${lib.concatStrings (lib.mapAttrsToList (name: _:
      let r = resolvedImages.${name};
      in ''
        TMPDIR=$(mktemp -d)
        "${r.copyTo}/bin/copy-to" "oci:$TMPDIR:${r.imageName}:${r.imageTag}"
        EXPECTED_DIGEST=$(${pkgs.jq}/bin/jq -r '.manifests[0].digest' "$TMPDIR/index.json")
        CURRENT_DIGEST=$(${runAs} ${bin} image inspect "${r.imageRef}" 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '.[].index.digest' 2>/dev/null || echo "")
        if [ "$EXPECTED_DIGEST" = "$CURRENT_DIGEST" ]; then
          echo "nix-apple-container: image ${r.imageRef} is current"
          rm -rf "$TMPDIR"
        else
          if [ -n "$CURRENT_DIGEST" ]; then
            echo "nix-apple-container: removing stale image ${r.imageRef}..."
            ${runAs} ${bin} image rm "${r.imageRef}" 2>/dev/null || true
          fi
          echo "nix-apple-container: loading image ${r.imageRef}..."
          tar cf "$TMPDIR.tar" -C "$TMPDIR" .
          chmod 644 "$TMPDIR.tar"
          ${runAs} ${bin} image load -i "$TMPDIR.tar"
          rm -rf "$TMPDIR" "$TMPDIR.tar"
        fi
      '') cfg.images)}
  '';

  mkContainerRunScript = name: c:
    let
      nixImagePath = nixImagePaths.${c.image} or null;
      allLabels = c.labels // { "managed-by" = "nix-apple-container"; };
      args = [ bin "run" "--name" name ]
        ++ lib.optionals (c.entrypoint != null) [ "--entrypoint" c.entrypoint ]
        ++ lib.optionals (c.user != null) [ "--user" c.user ]
        ++ lib.optionals (c.workdir != null) [ "--workdir" c.workdir ]
        ++ lib.optional c.init "--init" ++ lib.optional c.ssh "--ssh"
        ++ lib.optional c.readOnly "--read-only"
        ++ lib.optionals (c.network != null) [ "--network" c.network ]
        ++ (lib.concatMap (e: [ "--env" e ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
        ++ (lib.concatMap (l: [ "--label" l ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") allLabels))
        ++ (lib.concatMap (v: [ "--volume" v ]) c.volumes) ++ c.extraArgs
        ++ [ c.image ] ++ c.cmd;
    in pkgs.writeShellScript "container-run-${name}" ''
      ${lib.optionalString (nixImagePath != null) "# nix-image: ${nixImagePath}"}
      ${bin} stop ${lib.escapeShellArg name} 2>/dev/null || true
      ${bin} rm ${lib.escapeShellArg name} 2>/dev/null || true
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
      description =
        "nix2container images to load. Each value must be a nix2container buildImage output with copyTo, imageName, and imageTag attributes.";
    };

    kernel = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./kernel.nix { };
      description =
        "Kernel binary (flat file derivation). The default extracts the kata-containers kernel. The store path is symlinked directly as default.kernel-arm64.";
    };

    linuxBuilder = {
      enable =
        lib.mkEnableOption "Linux builder container for aarch64-linux builds";
      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/halfwhey/nix-builder:2.34.6";
        description = "Docker image for the Nix remote builder.";
      };
      speedFactor = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = ''
          The relative speed of the Linux builder.
          This is an arbitrary integer that indicates the speed of this builder, relative to other.
        '';
      };
      cores = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Number of CPUs to allocate to the container.";
      };
      memory = lib.mkOption {
        type = lib.types.str;
        default = "1024M";
        description = ''
          Amount of memory to allocate to the container.
        '';
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

    preserveImagesOnDisable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description =
        "Keep loaded images when the module is disabled. By default, teardown removes all runtime state.";
    };

    preserveVolumesOnDisable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description =
        "Keep named volume data when the module is disabled. Best-effort based on known runtime directory layout. Bind mounts are always preserved (they live on the host).";
    };

  };

  config = lib.mkMerge [
    # Teardown: runs when module is disabled (guarded — only if state exists)
    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        # Unload agents even if APP_SUPPORT was manually deleted — agents
        # are plist files in ~/Library/LaunchAgents, not inside APP_SUPPORT.
        ${mkAgentUnloadScript ""}

        APP_SUPPORT="${userHome}/Library/Application Support/com.apple.container"

        if [ -d "$APP_SUPPORT" ]; then
          echo "nix-apple-container: tearing down..."

          ${runAs} ${bin} system stop 2>/dev/null || true

          # Kernels and temp staging are always safe to remove
          rm -rf "$APP_SUPPORT/kernels"
          rm -rf "$APP_SUPPORT/content/ingest"

          ${lib.optionalString (!cfg.preserveImagesOnDisable) ''
            rm -rf "$APP_SUPPORT/content"
          ''}

          ${lib.optionalString
          (!cfg.preserveImagesOnDisable && !cfg.preserveVolumesOnDisable) ''
            rm -rf "$APP_SUPPORT"
          ''}
        fi

        # These run regardless of APP_SUPPORT existence
        ${runAs} defaults delete com.apple.container 2>/dev/null || true
        pkgutil --pkg-info com.apple.container-installer &>/dev/null && \
          sudo pkgutil --forget com.apple.container-installer 2>/dev/null || true
        rm -f /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub
      '';
    })

    # Setup: runs when module is enabled
    (lib.mkIf cfg.enable {
      assertions = let
        bad = lib.filterAttrs
          (_: c: builtins.any (v: !(lib.hasInfix ":" v)) c.volumes)
          cfg.containers;
      in lib.optional (bad != { }) {
        assertion = false;
        message =
          "nix-apple-container: containers ${
            lib.concatStringsSep ", " (lib.attrNames bad)
          } have volumes without a ':'. Use host:container for bind mounts or name:container for named volumes.";
      };

      environment.systemPackages = [ cfg.package ];

      launchd.user.agents = lib.mapAttrs' (name: c:
        lib.nameValuePair "container-${name}" {
          serviceConfig = {
            Label = "dev.apple.container.${name}";
            ProgramArguments = [ (toString (mkContainerRunScript name c)) ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "${userHome}/Library/Logs/container-${name}.log";
            StandardErrorPath =
              "${userHome}/Library/Logs/container-${name}.err";
          };
        }) autoStartContainers;

      # preActivation runs before launchd loads agents — images must be
      # loaded before containers try to start
      system.activationScripts.preActivation.text = lib.mkAfter
        (lib.concatStrings [
          ''
            # If the apiserver is registered but its binary no longer exists (e.g.
            # package upgrade + nix-collect-garbage), launchd can't activate it and
            # every CLI command hangs.  Deregister the stale service so system start
            # can re-register with the current binary.
            CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
            if [ -n "$CONTAINER_UID" ]; then
              APISERVER_BIN=$(launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- \
                launchctl print "user/$CONTAINER_UID/com.apple.container.apiserver" 2>/dev/null \
                | grep "path = " | awk '{print $3}') || true
              if [ -n "$APISERVER_BIN" ] && [ ! -x "$APISERVER_BIN" ]; then
                echo "nix-apple-container: deregistering stale apiserver ($APISERVER_BIN)..."
                launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- \
                  launchctl bootout "user/$CONTAINER_UID/com.apple.container.apiserver" 2>/dev/null || true
              fi
            fi

            if ! ${runAs} ${bin} system status &>/dev/null; then
              echo "nix-apple-container: starting runtime..."
              ${runAs} ${bin} system start --disable-kernel-install
            fi
            KERNEL_DIR="${appSupport}/kernels"
            ${runAs} mkdir -p "$KERNEL_DIR"
            ${runAs} ln -sf "${cfg.kernel}" "$KERNEL_DIR/default.kernel-arm64"
          ''
          imageLoadScript
          mkMountDirsScript
          ''
            echo "nix-apple-container: pruning stopped containers..."
            ${runAs} ${bin} prune || true
          ''
        ]);

      # Reconcile containers: unload stale launchd agents, then stop+rm undeclared containers.
      # We must unload agents ourselves because nix-darwin's userLaunchd script is conditional
      # on having user agents in the NEW config — if all containers are removed, it never runs
      # and old agents with KeepAlive=true keep restarting containers.
      system.activationScripts.postActivation.text = lib.mkAfter (let
        # Plist filenames are based on serviceConfig.Label, not the attribute name
        declaredAgentNames = lib.concatStringsSep " "
          (map (n: "dev.apple.container.${n}")
            (lib.attrNames autoStartContainers));
      in ''
        echo "nix-apple-container: reconciling containers..."

        # Unload and remove stale launchd agents before stopping containers.
        # nix-darwin's userLaunchd cleanup is conditional on having agents in the
        # new config — if all containers are removed, it skips cleanup entirely.
        ${mkAgentUnloadScript declaredAgentNames}

        # Now stop and remove containers not declared in config
        DECLARED="${lib.concatStringsSep " " (lib.attrNames cfg.containers)}"
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
      '');
    })

    # Linux builder cleanup (module enabled but builder disabled)
    (lib.mkIf (cfg.enable && !cfg.linuxBuilder.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        if [ -f /etc/nix/builder_ed25519 ]; then
          echo "nix-apple-container: removing linux builder resources..."
          rm -f /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub
        fi
      '';
    })

    # Linux builder — container, SSH key, and SSH config (all backends)
    (lib.mkIf (cfg.enable && cfg.linuxBuilder.enable) {
      services.containerization.containers.nix-builder = {
        image = cfg.linuxBuilder.image;
        autoStart = true;
        extraArgs = [
          "--publish"
          "${toString cfg.linuxBuilder.sshPort}:22"
          "--cpus"
          "${toString cfg.linuxBuilder.cores}"
          "--memory"
          "${toString cfg.linuxBuilder.memory}"
        ];
      };

      # SSH key must be imperative — SSH requires 0600, can't use a world-readable store path
      system.activationScripts.preActivation.text = lib.mkAfter ''
        if ! cmp -s ${./builder/builder_ed25519} /etc/nix/builder_ed25519 2>/dev/null; then
          install -m 600 ${./builder/builder_ed25519} /etc/nix/builder_ed25519
          install -m 644 ${
            ./builder/builder_ed25519.pub
          } /etc/nix/builder_ed25519.pub
        fi
      '';

      # SSH config for builder alias (port mapping + host key skipping).
      # nix.buildMachines has no port field, so we use hostName=nix-builder as an
      # SSH alias. StrictHostKeyChecking=no is needed because the builder generates
      # a new host key on every container restart.
      programs.ssh.extraConfig = ''
        Host nix-builder
          HostName localhost
          Port ${toString cfg.linuxBuilder.sshPort}
          User root
          IdentityFile /etc/nix/builder_ed25519
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
      '';

    })

    # Linux builder — declarative Nix config (plain nix-darwin with nix.enable = true)
    (lib.mkIf (cfg.enable && cfg.linuxBuilder.enable && config.nix.enable) {
      nix.buildMachines = [{
        hostName = "nix-builder";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = "/etc/nix/builder_ed25519";
        systems = [ "aarch64-linux" ];
        maxJobs = cfg.linuxBuilder.maxJobs;
        speedFactor = cfg.linuxBuilder.speedFactor;
        supportedFeatures = [ "big-parallel" ];
      }];
      nix.distributedBuilds = lib.mkDefault true;
      nix.settings.builders-use-substitutes = lib.mkDefault true;
    })

    # Linux builder — Determinate Nix config (nix.enable = false, determinateNix module available)
    (lib.mkIf (cfg.enable && cfg.linuxBuilder.enable && !config.nix.enable)
      (if options ? determinateNix then {
        determinateNix.customSettings = {
          builders =
            "ssh-ng://nix-builder aarch64-linux /etc/nix/builder_ed25519 ${
              toString cfg.linuxBuilder.maxJobs
            } 1 big-parallel - -";
          builders-use-substitutes = true;
        };
      } else {
        warnings = [
          "nix-apple-container: linuxBuilder.enable is true but neither nix.enable nor the determinateNix module is available. Builder Nix config (buildMachines, distributedBuilds) must be managed manually."
        ];
      }))
  ];
}
