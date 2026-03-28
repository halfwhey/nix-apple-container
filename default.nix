{ config, lib, pkgs, options, nix2containerLib ? null, ... }:

let
  cfg = config.services.containerization;
  bin = lib.getExe cfg.package;
  runAs = "sudo -u ${cfg.user} --";

  userHome = if config.users.users ? ${cfg.user} then
    config.users.users.${cfg.user}.home
  else
    "/Users/${cfg.user}";

  # Evaluate a NixOS configuration and build an OCI image via nix2container.
  # Adapted from Arion's pattern: symlink /usr/sbin/init → toplevel/init,
  # nix2container includes the full closure in image layers.
  mkNixosContainerImage = name: nixosConfig:
    assert nix2containerLib != null;
    let
      nixos = import "${pkgs.path}/nixos/lib/eval-config.nix" {
        system = "aarch64-linux";
        modules = [
          ./modules/nixos/apple-container-base.nix
          nixosConfig
        ];
      };
      toplevel = nixos.config.system.build.toplevel;
      rootInit = pkgs.runCommand "root-init-${name}" { } ''
        mkdir -p $out/usr/sbin
        ln -s ${toplevel}/init $out/usr/sbin/init
      '';
    in nix2containerLib.nix2container.buildImage {
      name = name;
      tag = "latest";
      copyToRoot = rootInit;
      config = {
        entrypoint = [ "/usr/sbin/init" ];
        env = [
          "container=apple"
          "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
        ];
      };
      maxLayers = 100;
    };

  # Collect NixOS container images from all containers (including project-expanded ones)
  nixosContainerImages = lib.filterAttrs (_: v: v != null) (lib.mapAttrs
    (name: c:
      if c.nixos.enable then mkNixosContainerImage name c.nixos.configuration
      else null)
    cfg.containers);

  containerSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description =
          "Image name:tag to run (local or registry). Auto-set when nixos.enable = true.";
      };
      nixos = {
        enable = lib.mkEnableOption "Build this container from a NixOS configuration";
        configuration = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          description =
            "NixOS modules to evaluate and build into an OCI image. The image runs systemd as PID 1.";
        };
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
      ports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description =
          "Port mappings (host:container). Each becomes a --publish flag.";
      };
      cpus = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = "CPU limit for the container VM.";
      };
      memory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Memory limit (e.g. '512m', '2g').";
      };
      dependsOn = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description =
          "Container names that must be running before this one starts. The wrapper script polls until each dependency is running.";
      };
      dependsOnTimeout = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description =
          "Seconds to wait for each dependency before giving up.";
      };
      dns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Custom DNS servers for the container.";
      };
      tmpfs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Tmpfs mounts inside the container.";
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

  # Create declared networks (idempotent — skip if already exists)
  networkCreateScript = lib.optionalString (cfg.networks != { }) ''
    ${lib.concatStrings (lib.mapAttrsToList (name: net: ''
      if ! ${runAs} ${bin} network inspect ${lib.escapeShellArg name} &>/dev/null; then
        echo "nix-apple-container: creating network ${name}..."
        ${runAs} ${bin} network create \
          --label managed-by=nix-apple-container \
          ${lib.optionalString (net.subnet != null)
            "--subnet ${lib.escapeShellArg net.subnet}"} \
          ${lib.optionalString (net.subnetV6 != null)
            "--subnet-v6 ${lib.escapeShellArg net.subnetV6}"} \
          ${lib.escapeShellArg name}
      fi
    '') cfg.networks)}
  '';

  # Create declared volumes (idempotent — skip if already exists)
  volumeCreateScript = lib.optionalString (cfg.volumes != { }) ''
    ${lib.concatStrings (lib.mapAttrsToList (name: _: ''
      if ! ${runAs} ${bin} volume inspect ${lib.escapeShellArg name} &>/dev/null; then
        echo "nix-apple-container: creating volume ${name}..."
        ${runAs} ${bin} volume create \
          --label managed-by=nix-apple-container \
          ${lib.escapeShellArg name}
      fi
    '') cfg.volumes)}
  '';

  # Remove networks not in config (only those managed by this module)
  networkReconcileScript = ''
    for net_name in $(${runAs} ${bin} network ls --format json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[].name // empty' 2>/dev/null); do
      KEEP=false
      ${lib.optionalString (cfg.networks != { }) ''
        for d in ${lib.escapeShellArgs (lib.attrNames cfg.networks)}; do
          if [ "$net_name" = "$d" ]; then KEEP=true; break; fi
        done
      ''}
      if [ "$KEEP" = "false" ]; then
        # Only remove networks we manage (have our label)
        if ${runAs} ${bin} network inspect "$net_name" 2>/dev/null | ${pkgs.jq}/bin/jq -e '.[0].labels["managed-by"] == "nix-apple-container"' >/dev/null 2>&1; then
          echo "nix-apple-container: removing undeclared network $net_name..."
          ${runAs} ${bin} network rm "$net_name" 2>/dev/null || true
        fi
      fi
    done
  '';

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
        ++ lib.optionals (c.cpus != null)
          [ "--cpus" (toString c.cpus) ]
        ++ lib.optionals (c.memory != null) [ "--memory" c.memory ]
        ++ (lib.concatMap (p: [ "--publish" p ]) c.ports)
        ++ (lib.concatMap (d: [ "--dns" d ]) c.dns)
        ++ (lib.concatMap (t: [ "--tmpfs" t ]) c.tmpfs)
        ++ (lib.concatMap (e: [ "--env" e ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
        ++ (lib.concatMap (l: [ "--label" l ])
          (lib.mapAttrsToList (k: v: "${k}=${v}") allLabels))
        ++ (lib.concatMap (v: [ "--volume" v ]) c.volumes) ++ c.extraArgs
        ++ [ c.image ] ++ c.cmd;

      dependsOnScript = lib.optionalString (c.dependsOn != [ ]) ''
        for dep in ${lib.escapeShellArgs c.dependsOn}; do
          echo "nix-apple-container: ${name}: waiting for $dep..."
          WAITED=0
          while [ "$WAITED" -lt ${toString c.dependsOnTimeout} ]; do
            if ${bin} inspect "$dep" 2>/dev/null | ${pkgs.jq}/bin/jq -e '.[0].status == "running"' >/dev/null 2>&1; then
              echo "nix-apple-container: ${name}: $dep is running"
              break
            fi
            sleep 1
            WAITED=$((WAITED + 1))
          done
          if [ "$WAITED" -ge ${toString c.dependsOnTimeout} ]; then
            echo "nix-apple-container: ${name}: WARNING: $dep not running after ${toString c.dependsOnTimeout}s, proceeding anyway" >&2
          fi
        done
      '';
    in pkgs.writeShellScript "container-run-${name}" ''
      ${lib.optionalString (nixImagePath != null) "# nix-image: ${nixImagePath}"}
      ${dependsOnScript}
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

    projects = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          containers = lib.mkOption {
            type = lib.types.attrsOf containerSubmodule;
            default = { };
            description =
              "Containers in this project. Names are scoped: container 'web' in project 'myapp' becomes 'myapp-web'.";
          };
          network = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description =
              "Shared network for all containers in this project (macOS 26+). Auto-created if not already declared in networks.";
          };
          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description =
              "Environment variables applied to all containers in the project.";
          };
          labels = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description =
              "Labels applied to all containers in the project.";
          };
        };
      });
      default = { };
      description =
        "Container projects (groups of related services with shared config).";
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
        default = "ghcr.io/halfwhey/nix-builder:2.34.3";
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

    networks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          subnet = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "IPv4 subnet (e.g. '192.168.100.0/24').";
          };
          subnetV6 = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "IPv6 subnet.";
          };
        };
      });
      default = { };
      description =
        "Declarative networks (macOS 26+). Created on activation, removed when undeclared.";
    };

    volumes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = { };
      });
      default = { };
      description =
        "Declarative named volumes. Created on activation.";
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
    # Project expansion: expand project containers into cfg.containers with scoped names
    (lib.mkIf (cfg.projects != { }) {
      services.containerization.containers = lib.mkMerge (lib.mapAttrsToList
        (projName: proj:
          lib.mapAttrs' (cName: c:
            let
              scopedName = "${projName}-${cName}";
              # Resolve dependsOn within project scope
              resolvedDeps = map
                (d:
                  if cfg.projects.${projName}.containers ? ${d} then
                    "${projName}-${d}"
                  else
                    d)
                c.dependsOn;
            in lib.nameValuePair scopedName (c // {
              env = proj.env // c.env;
              labels = proj.labels // c.labels;
              network =
                if c.network != null then c.network
                else proj.network;
              dependsOn = resolvedDeps;
            })) proj.containers)
        cfg.projects);

      # Auto-create project networks if not already in cfg.networks
      services.containerization.networks = lib.mkMerge (lib.mapAttrsToList
        (projName: proj:
          lib.optionalAttrs (proj.network != null && !(cfg.networks ? ${proj.network}))
            { ${proj.network} = { }; })
        cfg.projects);

      assertions = let
        # Check for name collisions between top-level containers and expanded project containers
        expandedNames = lib.concatMap (projName:
          map (cName: "${projName}-${cName}")
            (lib.attrNames cfg.projects.${projName}.containers))
          (lib.attrNames cfg.projects);
        topLevelNames = lib.attrNames
          (lib.filterAttrs (n: _:
            !(builtins.any (projName:
              lib.hasPrefix "${projName}-" n &&
              cfg.projects.${projName}.containers ?
                ${lib.removePrefix "${projName}-" n})
              (lib.attrNames cfg.projects)))
            cfg.containers);
        collisions = builtins.filter (n: builtins.elem n topLevelNames) expandedNames;
      in lib.optional (collisions != [ ]) {
        assertion = false;
        message =
          "nix-apple-container: name collision between project containers and top-level containers: ${
            lib.concatStringsSep ", " collisions
          }. Project containers are prefixed with '<project>-<name>'.";
      };
    })

    # NixOS container expansion: auto-set image, register in images.*, add systemd flags
    (lib.mkIf (cfg.enable && nixosContainerImages != { }) {
      assertions = [
        {
          assertion = nix2containerLib != null;
          message =
            "nix-apple-container: NixOS containers require nix2container. Add it as a flake input and pass nix2containerLib to the module.";
        }
      ];

      # Auto-register NixOS images for loading via the existing imageLoadScript
      services.containerization.images = nixosContainerImages;

      # Auto-set container image refs and systemd-specific flags
      services.containerization.containers = lib.mapAttrs (name: _:
        let img = nixosContainerImages.${name};
        in {
          image = lib.mkDefault "${img.imageName}:${img.imageTag}";
          # systemd needs cgroup access and tmpfs for /run
          volumes = lib.mkDefault [ "/sys/fs/cgroup:/sys/fs/cgroup:ro" ];
          tmpfs = lib.mkDefault [ "/run" "/run/wrappers" ];
        }) nixosContainerImages;
    })

    # Teardown: runs when module is disabled (guarded — only if state exists)
    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        # Unload agents even if APP_SUPPORT was manually deleted — agents
        # are plist files in ~/Library/LaunchAgents, not inside APP_SUPPORT.
        ${mkAgentUnloadScript ""}

        APP_SUPPORT="${userHome}/Library/Application Support/com.apple.container"

        if [ -d "$APP_SUPPORT" ]; then
          echo "nix-apple-container: tearing down..."

          # Remove module-managed networks and volumes before stopping runtime
          for net_name in $(${runAs} ${bin} network ls --format json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[].name // empty' 2>/dev/null); do
            if ${runAs} ${bin} network inspect "$net_name" 2>/dev/null | ${pkgs.jq}/bin/jq -e '.[0].labels["managed-by"] == "nix-apple-container"' >/dev/null 2>&1; then
              echo "nix-apple-container: removing network $net_name..."
              ${runAs} ${bin} network rm "$net_name" 2>/dev/null || true
            fi
          done

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
        # Containers without an image source
        noImage = lib.filterAttrs
          (_: c: c.image == null && !c.nixos.enable)
          cfg.containers;
        containerNames = lib.attrNames cfg.containers;
        # dependsOn targets must exist
        badDepRefs = lib.filterAttrs (_: c:
          builtins.any (d: !(builtins.elem d containerNames)) c.dependsOn)
          cfg.containers;
        # dependsOn targets must have autoStart = true
        badDepAutoStart = lib.filterAttrs (_: c:
          builtins.any
          (d: cfg.containers ? ${d} && !cfg.containers.${d}.autoStart)
          c.dependsOn) cfg.containers;
        # Cycle detection via DFS
        hasCycle = let
          visit = visited: stack: node:
            if builtins.elem node stack then
              true
            else if builtins.elem node visited then
              false
            else
              let
                deps = (cfg.containers.${node} or { dependsOn = [ ]; }).dependsOn;
                newStack = stack ++ [ node ];
              in builtins.any (visit (visited ++ [ node ]) newStack) deps;
        in builtins.any (visit [ ] [ ]) containerNames;
      in lib.optional (bad != { }) {
        assertion = false;
        message =
          "nix-apple-container: containers ${
            lib.concatStringsSep ", " (lib.attrNames bad)
          } have volumes without a ':'. Use host:container for bind mounts or name:container for named volumes.";
      } ++ lib.optional (noImage != { }) {
        assertion = false;
        message =
          "nix-apple-container: containers ${
            lib.concatStringsSep ", " (lib.attrNames noImage)
          } have no image. Set 'image' or enable 'nixos.enable'.";
      } ++ lib.optional (badDepRefs != { }) {
        assertion = false;
        message =
          "nix-apple-container: containers ${
            lib.concatStringsSep ", " (lib.attrNames badDepRefs)
          } have dependsOn references to non-existent containers.";
      } ++ lib.optional (badDepAutoStart != { }) {
        assertion = false;
        message =
          "nix-apple-container: containers ${
            lib.concatStringsSep ", " (lib.attrNames badDepAutoStart)
          } depend on containers with autoStart = false. Dependencies must have autoStart = true.";
      } ++ lib.optional hasCycle {
        assertion = false;
        message =
          "nix-apple-container: circular dependency detected in dependsOn.";
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
            if ! ${runAs} ${bin} system status &>/dev/null; then
              echo "nix-apple-container: starting runtime..."
              ${runAs} ${bin} system start --disable-kernel-install
            fi
            KERNEL_DIR="${appSupport}/kernels"
            ${runAs} mkdir -p "$KERNEL_DIR"
            ${runAs} ln -sf "${cfg.kernel}" "$KERNEL_DIR/default.kernel-arm64"
          ''
          networkCreateScript
          volumeCreateScript
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

        # Reconcile networks: remove module-managed networks not in config
        ${networkReconcileScript}
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
        extraArgs = [ "--publish" "${toString cfg.linuxBuilder.sshPort}:22" ];
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

      system.activationScripts.postActivation.text = lib.mkAfter ''
        echo "nix-apple-container: waiting for linux builder..."
        BUILDER_READY=false
        for _i in $(seq 1 30); do
          if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -i /etc/nix/builder_ed25519 -p ${
                 toString cfg.linuxBuilder.sshPort
               } \
               root@localhost true 2>/dev/null; then
            BUILDER_READY=true
            break
          fi
          sleep 1
        done
        if [ "$BUILDER_READY" = "false" ]; then
          echo "nix-apple-container: WARNING: linux builder SSH not responding after 30s" >&2
        fi
      '';
    })

    # Linux builder — declarative Nix config (plain nix-darwin with nix.enable = true)
    (lib.mkIf (cfg.enable && cfg.linuxBuilder.enable && config.nix.enable) {
      nix.buildMachines = [{
        hostName = "nix-builder";
        protocol = "ssh";
        sshUser = "root";
        sshKey = "/etc/nix/builder_ed25519";
        systems = [ "aarch64-linux" ];
        maxJobs = cfg.linuxBuilder.maxJobs;
        speedFactor = 1;
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
            "ssh://nix-builder aarch64-linux /etc/nix/builder_ed25519 ${
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
