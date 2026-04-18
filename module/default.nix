{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.containerization;
  bin = lib.getExe cfg.package;
  runAs = "sudo -u ${cfg.user} --";

  userHome =
    if config.users.users ? ${cfg.user} then
      config.users.users.${cfg.user}.home
    else
      "/Users/${cfg.user}";

  # Resolve nix2container image metadata (keyed by attr name)
  resolvedImages = lib.mapAttrs (name: img: {
    copyTo = img.copyTo;
    imageName = img.imageName;
    imageTag = img.imageTag;
    imageRef = "${img.imageName}:${img.imageTag}";
  }) cfg.images;

  # Lookup from imageRef → copyTo store path, used to embed a content-dependent
  # comment in container wrapper scripts so plist changes trigger agent restarts.
  nixImagePaths = lib.mapAttrs' (_: r: lib.nameValuePair r.imageRef "${r.copyTo}") resolvedImages;

  appSupport = "${userHome}/Library/Application Support/com.apple.container";
  runtimeLabel = "nix-apple-container.runtime";
  userBuilderKey = "${userHome}/.ssh/nix-builder_ed25519";
  userBuilderPubKey = "${userHome}/.ssh/nix-builder_ed25519.pub";

  autoStartContainers = lib.filterAttrs (_: c: c.autoStart) cfg.containers;

  # Extract host paths from volume strings (host:container) for containers with autoCreateMounts
  mkMountDirsScript = lib.concatStrings (
    lib.mapAttrsToList (
      name: c:
      lib.optionalString (c.autoCreateMounts && c.volumes != [ ]) (
        lib.concatMapStrings (
          v:
          let
            hostPath = builtins.head (lib.splitString ":" v);
          in
          lib.optionalString (lib.hasInfix ":" v && lib.hasPrefix "/" hostPath) ''
            if [ ! -d "${hostPath}" ]; then
              echo "nix-apple-container: creating mount ${hostPath} for ${name}..."
              ${runAs} mkdir -p "${hostPath}"
            fi
          ''
        ) c.volumes
      )
    ) cfg.containers
  );

  # Load nix2container images via `container image load` at activation time.
  # Content-aware: runs copyTo to a temp OCI layout, reads the manifest digest from
  # index.json, and compares against the runtime. Only tars+loads when content differs.
  imageLoadScript = lib.optionalString (cfg.images != { }) ''
    ${lib.concatStrings (
      lib.mapAttrsToList (
        name: _:
        let
          r = resolvedImages.${name};
        in
        ''
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
        ''
      ) cfg.images
    )}
  '';

  mkContainerRunScript =
    name: c:
    let
      nixImagePath = nixImagePaths.${c.image} or null;
      allLabels = c.labels // {
        "managed-by" = "nix-apple-container";
      };
      args = [
        bin
        "run"
        "--name"
        name
      ]
      ++ lib.optionals (c.entrypoint != null) [
        "--entrypoint"
        c.entrypoint
      ]
      ++ lib.optionals (c.user != null) [
        "--user"
        c.user
      ]
      ++ lib.optionals (c.workdir != null) [
        "--workdir"
        c.workdir
      ]
      ++ lib.optional c.init "--init"
      ++ lib.optional c.ssh "--ssh"
      ++ lib.optional c.readOnly "--read-only"
      ++ lib.optionals (c.network != null) [
        "--network"
        c.network
      ]
      ++ (lib.concatMap (e: [
        "--env"
        e
      ]) (lib.mapAttrsToList (k: v: "${k}=${v}") c.env))
      ++ (lib.concatMap (l: [
        "--label"
        l
      ]) (lib.mapAttrsToList (k: v: "${k}=${v}") allLabels))
      ++ (lib.concatMap (v: [
        "--volume"
        v
      ]) c.volumes)
      ++ c.extraArgs
      ++ [ c.image ]
      ++ c.cmd;
    in
    pkgs.writeShellScript "container-run-${name}" ''
      if [ "$(id -un)" != "${cfg.user}" ]; then
        exit 0
      fi
      ${lib.optionalString (nixImagePath != null) "# nix-image: ${nixImagePath}"}
      ${bin} stop ${lib.escapeShellArg name} 2>/dev/null || true
      ${bin} rm ${lib.escapeShellArg name} 2>/dev/null || true
      exec ${lib.escapeShellArgs args}
    '';

in
{
  imports = [
    ./options.nix
    ./builders.nix
    ./compat.nix
  ];

  config = lib.mkMerge ([
    # Teardown: runs when module is disabled (guarded — only if state exists)
    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
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

          ${lib.optionalString (!cfg.preserveImagesOnDisable && !cfg.preserveVolumesOnDisable) ''
            rm -rf "$APP_SUPPORT"
          ''}
        fi

        # These run regardless of APP_SUPPORT existence
        ${
          if cfg.user == config.system.primaryUser then
            "${runAs} defaults delete com.apple.container.defaults dns.domain 2>/dev/null || true"
          else
            "${runAs} ${bin} system property clear dns.domain 2>/dev/null || true"
        }
        pkgutil --pkg-info com.apple.container-installer &>/dev/null && \
          sudo pkgutil --forget com.apple.container-installer 2>/dev/null || true
        rm -f "${userBuilderKey}" "${userBuilderPubKey}"
        rm -f /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub
      '';
    })

    # Setup: runs when module is enabled
    (lib.mkIf cfg.enable {
      assertions =
        let
          bad = lib.filterAttrs (_: c: builtins.any (v: !(lib.hasInfix ":" v)) c.volumes) cfg.containers;
        in
        lib.optional (bad != { }) {
          assertion = false;
          message = "nix-apple-container: containers ${lib.concatStringsSep ", " (lib.attrNames bad)} have volumes without a ':'. Use host:container for bind mounts or name:container for named volumes.";
        };

      environment.systemPackages = [ cfg.package ];

      environment.etc."resolver/containerization.test" = {
        text = ''
          domain test
          search test
          nameserver 127.0.0.1
          port 2053
        '';
      };

      system.defaults.CustomUserPreferences = lib.mkIf (cfg.user == config.system.primaryUser) {
        "com.apple.container.defaults" = {
          "dns.domain" = "test";
        };
      };

      launchd.daemons.container-runtime = {
        serviceConfig = {
          Label = runtimeLabel;
          ProgramArguments = [
            (toString (
              pkgs.writeShellScript "container-runtime-start" ''
                exec ${runAs} ${bin} system start --disable-kernel-install
              ''
            ))
          ];
          RunAtLoad = true;
          KeepAlive = {
            SuccessfulExit = false;
          };
          StandardOutPath = "${userHome}/Library/Logs/container-runtime.log";
          StandardErrorPath = "${userHome}/Library/Logs/container-runtime.err";
        };
      };

      launchd.user.agents = lib.mapAttrs' (
        name: c:
        lib.nameValuePair "container-${name}" {
          serviceConfig = {
            Label = "dev.apple.container.${name}";
            ProgramArguments = [ (toString (mkContainerRunScript name c)) ];
            LimitLoadToSessionType = [ "Background" ];
            RunAtLoad = false;
            KeepAlive = {
              OtherJobEnabled = {
                "com.apple.container.apiserver" = true;
              };
            };
            StandardOutPath = "${userHome}/Library/Logs/container-${name}.log";
            StandardErrorPath = "${userHome}/Library/Logs/container-${name}.err";
          };
        }
      ) autoStartContainers;

      # preActivation runs before launchd loads agents — images must be
      # loaded before containers try to start
      system.activationScripts.preActivation.text = lib.mkAfter (
        lib.concatStrings [
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
            ${lib.optionalString (cfg.user != config.system.primaryUser) ''
              if [ "$(${runAs} ${bin} system property get dns.domain 2>/dev/null || true)" != "test" ]; then
                echo "nix-apple-container: setting default DNS domain to test..."
                ${runAs} ${bin} system property set dns.domain test
              fi
            ''}
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
        ]
      );

      # Reconcile containers: stop+rm undeclared containers.
      system.activationScripts.postActivation.text = lib.mkAfter ''
        echo "nix-apple-container: reconciling containers..."

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
      '';
    })

  ]);
}
