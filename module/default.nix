{
  config,
  lib,
  pkgs,
  ...
}:

let
  common = import ./common.nix { inherit config; };
  cfg = config.services.containerization;
  inherit (common)
    launchAgentsDir
    resolverRelativePath
    runtimeLabel
    systemBuilderKey
    systemBuilderPubKey
    userBuilderKey
    userBuilderPubKey
    userHome
    ;
  bin = lib.getExe cfg.package;
  jq = "${pkgs.jq}/bin/jq";
  runAs = "sudo -u ${cfg.user} --";

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
  launchdStateDir = "/tmp/nix-apple-container-${cfg.user}";
  managedAgentDir = launchAgentsDir;
  runtimeAgentPath = "${managedAgentDir}/${runtimeLabel}.plist";
  logContextVar = "NAC_LOG_CONTEXT";
  changedManagedLabelsPath = "${launchdStateDir}/changed-managed-labels";

  userDomainLoop = uidExpr: body: ''
    for domain in "gui/${uidExpr}" "user/${uidExpr}"; do
      ${body}
    done
  '';

  bootoutManagedLabelsScript = logCommand: ''
    ${userDomainLoop "$CONTAINER_UID" ''
      launchctl print "$domain" >/dev/null 2>&1 || continue
      launchctl print "$domain" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++){f=$i;gsub(/^"|"$/,"",f);if(f~/^dev\.apple\.container\.[A-Za-z0-9_.-]+$/){print f;break}}}' \
        | sort -u \
        | while IFS= read -r label; do
            [ -n "$label" ] || continue
            ${logCommand}
            launchctl bootout "$domain/$label" 2>/dev/null || true
          done
    ''}
  '';

  mkShellLogging = context: ''
    : "''${${logContextVar}:=${context}}"

    nac_timestamp() {
      /bin/date '+%Y-%m-%dT%H:%M:%S%z'
    }

    nac_log() {
      if [ -n "''${NAC_LOG_CAPTURE_INITIALIZED:-}" ]; then
        printf '%s [%s] %s\n' "$(nac_timestamp)" "$NAC_LOG_CONTEXT" "$*" >&4
      else
        printf '%s [%s] %s\n' "$(nac_timestamp)" "$NAC_LOG_CONTEXT" "$*" >&2
      fi
    }

    nac_capture_streams() {
      if [ -n "''${NAC_LOG_CAPTURE_INITIALIZED:-}" ]; then
        return 0
      fi

      NAC_LOG_CAPTURE_INITIALIZED=1
      exec 3>&1 4>&2
      exec > >(
        while IFS= read -r line || [ -n "$line" ]; do
          printf '%s [%s][stdout] %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$NAC_LOG_CONTEXT" "$line" >&3
        done
      )
      exec 2> >(
        while IFS= read -r line || [ -n "$line" ]; do
          printf '%s [%s][stderr] %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$NAC_LOG_CONTEXT" "$line" >&4
        done
      )
    }

    # `launchctl print <domain>` output format varies by macOS version: modern
    # releases list services as `<pid>\t<status>\t<label>`, older releases used
    # `<label> = <value>`, and endpoints may use quoted labels. Match any
    # `dev.apple.container.*` token on any field (stripping surrounding quotes)
    # so label discovery works across formats.
    nac_list_managed_labels() {
      local domain="$1"

      launchctl print "$domain" >/dev/null 2>&1 || return 0
      launchctl print "$domain" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++){f=$i;gsub(/^"|"$/,"",f);if(f~/^dev\.apple\.container\.[A-Za-z0-9_.-]+$/){print f;break}}}' \
        | sort -u
    }

    nac_label_in_file() {
      local label="$1"
      local file="$2"

      [ -f "$file" ] || return 1
      grep -Fx -- "$label" "$file" >/dev/null 2>&1
    }

    nac_wait_for_label_unload() {
      local domain="$1"
      local label="$2"
      local timeout="''${3:-30}"
      local waited=0

      while [ "$waited" -lt "$timeout" ]; do
        launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
        sleep 1
        waited=$((waited + 1))
      done

      launchctl print "$domain/$label" >/dev/null 2>&1 && return 1
      return 0
    }

    # Forward shutdown signals to the $run_pid child (when present) so launchd's
    # bootout reaps the process group promptly. Otherwise the wrapper exits but
    # `container run` lingers, keeping the service registered while launchctl
    # bootstrap races with the pending unload (fails with status 5).
    nac_kill_child() {
      if [ -n "''${run_pid:-}" ] && kill -0 "$run_pid" 2>/dev/null; then
        nac_log "forwarding shutdown to container run child pid=$run_pid"
        kill "$run_pid" 2>/dev/null || true
        nac_wait_count=0
        while kill -0 "$run_pid" 2>/dev/null && [ "$nac_wait_count" -lt 10 ]; do
          sleep 1
          nac_wait_count=$((nac_wait_count + 1))
        done
        if kill -0 "$run_pid" 2>/dev/null; then
          nac_log "container run child still alive after 10s; sending SIGKILL"
          kill -9 "$run_pid" 2>/dev/null || true
        fi
      fi
    }

    nac_capture_streams
    nac_log "script start pid=$$"
    trap 'status=$?; nac_log "script exit status=$status"' EXIT
    trap 'nac_log "received SIGHUP"; nac_kill_child; exit 129' HUP
    trap 'nac_log "received SIGINT"; nac_kill_child; exit 130' INT
    trap 'nac_log "received SIGQUIT"; nac_kill_child; exit 131' QUIT
    trap 'nac_log "received SIGTERM"; nac_kill_child; exit 143' TERM
    trap 'nac_log "received SIGABRT"; nac_kill_child; exit 134' ABRT
  '';

  autoStartContainers = lib.filterAttrs (_: c: c.autoStart) cfg.containers;
  registryAutoStartImages = lib.unique (
    lib.filter (image: !(builtins.hasAttr image nixImagePaths)) (
      lib.mapAttrsToList (_: c: c.image) autoStartContainers
    )
  );
  bootstrapManagedContainersScript = pkgs.writeShellScript "bootstrap-managed-containers" ''
    ${mkShellLogging "bootstrap-managed-containers"}

    set -e -o pipefail

    for cmd in awk basename chmod grep id launchctl mkdir rm sudo touch; do
      command -v "$cmd" >/dev/null 2>&1 || {
        nac_log "'$cmd' is required but not found in PATH"
        exit 1
      }
    done

    CURRENT_USER=$(id -un 2>/dev/null || echo "")
    CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
    if [ -z "$CONTAINER_UID" ]; then
      nac_log "could not resolve uid for ${cfg.user}"
      exit 1
    fi

    CONTAINER_MANAGER=$(launchctl managername 2>/dev/null || echo "")
    CONTAINER_DOMAIN=""
    case "$CONTAINER_MANAGER" in
      Aqua)
        CONTAINER_DOMAIN="gui/$CONTAINER_UID"
        ;;
      Background)
        CONTAINER_DOMAIN="user/$CONTAINER_UID"
        ;;
      *)
        if launchctl print "user/$CONTAINER_UID" >/dev/null 2>&1; then
          CONTAINER_DOMAIN="user/$CONTAINER_UID"
        elif launchctl print "gui/$CONTAINER_UID" >/dev/null 2>&1; then
          CONTAINER_DOMAIN="gui/$CONTAINER_UID"
        fi
        ;;
    esac

    if [ -z "$CONTAINER_DOMAIN" ]; then
      if [ "$CURRENT_USER" = "${cfg.user}" ]; then
        nac_log "could not determine a user launchd domain for uid $CONTAINER_UID while running as ${cfg.user}; failing so launchd can retry"
        exit 1
      fi
      nac_log "no user launchd domain for uid $CONTAINER_UID yet; deferring managed container bootstrap until the first ${cfg.user} session"
      exit 0
    fi

    CONTAINER_MANAGER_DISPLAY="$CONTAINER_MANAGER"
    if [ -z "$CONTAINER_MANAGER_DISPLAY" ]; then
      CONTAINER_MANAGER_DISPLAY="unknown"
    fi

    nac_log "resolved launchd manager='$CONTAINER_MANAGER_DISPLAY' domain='$CONTAINER_DOMAIN' user='${cfg.user}'"
    mkdir -p "${appSupport}"

    run_container() {
      if [ "$(id -un)" = "${cfg.user}" ]; then
        "$@"
      else
        sudo -u "${cfg.user}" -- "$@"
      fi
    }

    if run_container ${bin} system status >/dev/null 2>&1; then
      nac_log "runtime already running"
    else
      nac_log "runtime not running; starting with 'container system start --disable-kernel-install'"
      if run_container ${bin} system start --disable-kernel-install; then
        nac_log "runtime start command completed"
      else
        status=$?
        nac_log "runtime start failed with status $status"
        exit "$status"
      fi
    fi

    launchctl enable "$CONTAINER_DOMAIN/${runtimeLabel}" >/dev/null 2>&1 || true

    changed_labels_file="${changedManagedLabelsPath}"
    desired_labels_file="${launchdStateDir}/desired-managed-labels.$$"
    mkdir -p "${launchdStateDir}"
    if [ "$(id -u)" -eq 0 ]; then
      touch "$changed_labels_file"
      chmod 644 "$changed_labels_file"
    fi
    : > "$desired_labels_file"

    found_managed_plist=0
    for plist in "${managedAgentDir}"/dev.apple.container.*.plist; do
      [ -f "$plist" ] || continue
      found_managed_plist=1
      label="$(basename "$plist" .plist)"
      printf '%s\n' "$label" >> "$desired_labels_file"
    done

    ${userDomainLoop "$CONTAINER_UID" ''
      nac_list_managed_labels "$domain" | while IFS= read -r label; do
        [ -n "$label" ] || continue
        if nac_label_in_file "$label" "$desired_labels_file"; then
          if [ "$domain" != "$CONTAINER_DOMAIN" ]; then
            nac_log "booting out duplicate managed label '$label' from '$domain'"
            launchctl bootout "$domain/$label" 2>/dev/null || true
          fi
        else
          nac_log "booting out stale managed label '$label' from '$domain'"
          launchctl bootout "$domain/$label" 2>/dev/null || true
        fi
      done
    ''}

    for plist in "${managedAgentDir}"/dev.apple.container.*.plist; do
      [ -f "$plist" ] || continue
      label="$(basename "$plist" .plist)"
      if launchctl print "$CONTAINER_DOMAIN/$label" >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ] && nac_label_in_file "$label" "$changed_labels_file"; then
          nac_log "reloading changed managed label '$label' in '$CONTAINER_DOMAIN'"
          launchctl bootout "$CONTAINER_DOMAIN/$label" 2>/dev/null || true
          if ! nac_wait_for_label_unload "$CONTAINER_DOMAIN" "$label" 30; then
            nac_log "timed out waiting for '$label' to unload from '$CONTAINER_DOMAIN'"
            exit 1
          fi
        else
          nac_log "managed label '$label' already loaded in '$CONTAINER_DOMAIN'; skipping bootstrap"
          continue
        fi
      fi
      nac_log "bootstrapping '$label' from '$plist' into '$CONTAINER_DOMAIN'"
      launchctl enable "$CONTAINER_DOMAIN/$label" >/dev/null 2>&1 || true
      launchctl bootstrap "$CONTAINER_DOMAIN" "$plist"
      nac_log "bootstrapped '$label' successfully"
    done

    if [ "$found_managed_plist" -eq 0 ]; then
      nac_log "no managed container plists found in ${managedAgentDir}"
    fi

    if [ "$(id -u)" -eq 0 ]; then
      : > "$changed_labels_file"
    fi
    rm -f "$desired_labels_file"
    nac_log "bootstrap-managed-containers completed"
  '';
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
          EXPECTED_DIGEST=$(${jq} -r '.manifests[0].digest' "$TMPDIR/index.json")
          CURRENT_DIGEST=$(${runAs} ${bin} image inspect "${r.imageRef}" 2>/dev/null \
            | ${jq} -r '.[].index.digest' 2>/dev/null || echo "")
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

  registryImagePullScript = lib.optionalString (registryAutoStartImages != [ ]) ''
    ${lib.concatMapStrings (image: ''
      if ${runAs} ${bin} image inspect ${lib.escapeShellArg image} >/dev/null 2>&1; then
        echo "nix-apple-container: image ${image} is present"
      else
        attempt=1
        max_attempts=3
        while true; do
          echo "nix-apple-container: pulling registry image ${image} (attempt $attempt/$max_attempts)..."
          if ${runAs} ${bin} image pull ${lib.escapeShellArg image}; then
            break
          fi
          if [ "$attempt" -ge "$max_attempts" ]; then
            echo "nix-apple-container: failed to pull registry image ${image} after $max_attempts attempts" >&2
            exit 1
          fi
          echo "nix-apple-container: pull for ${image} failed; retrying in 5s..." >&2
          attempt=$((attempt + 1))
          sleep 5
        done
      fi
    '') registryAutoStartImages}
  '';

  mkContainerArgs =
    name: c:
    let
      allLabels = c.labels // {
        "managed-by" = "nix-apple-container";
      };
    in
    [
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

  mkContainerRunScript =
    name: c:
    let
      nixImagePath = nixImagePaths.${c.image} or null;
      args = mkContainerArgs name c;
    in
    pkgs.writeShellScript "container-run-${name}" ''
      ${mkShellLogging "container-${name}"}

      if [ "$(id -un)" != "${cfg.user}" ]; then
        nac_log "launchd invoked as $(id -un); expected ${cfg.user}; exiting without action"
        exit 0
      fi

      wait_for_runtime() {
        local attempt=1
        nac_log "waiting for runtime readiness"
        while [ "$attempt" -le 30 ]; do
          if ${bin} system status >/dev/null 2>&1; then
            sleep 1
            if ${bin} system status >/dev/null 2>&1; then
              nac_log "runtime became ready after $attempt probe(s)"
              return 0
            fi
          fi
          if [ "$attempt" -eq 1 ] || [ $((attempt % 5)) -eq 0 ] || [ "$attempt" -eq 30 ]; then
            nac_log "runtime not ready yet (probe $attempt/30)"
          fi
          sleep 1
          attempt=$((attempt + 1))
        done
        nac_log "runtime did not become ready after 30 probes; skipping start for ${name}"
        return 1
      }

      ${lib.optionalString (nixImagePath != null) "# nix-image: ${nixImagePath}"}
      startup_attempt=1
      max_startup_attempts=5

      while true; do
        wait_for_runtime || exit 0

        nac_log "startup attempt ''${startup_attempt}/''${max_startup_attempts}: reconciling existing container state"
        ${bin} stop ${lib.escapeShellArg name} 2>/dev/null || true
        ${bin} rm ${lib.escapeShellArg name} 2>/dev/null || true

        nac_log "running container ${name} from image ${c.image}"
        SECONDS=0
        set +e
        ${lib.escapeShellArgs args} &
        run_pid=$!
        nac_log "container run child pid=''${run_pid}"
        wait "$run_pid"
        status=$?
        set -e
        run_duration=$SECONDS

        if [ "$status" -eq 0 ]; then
          nac_log "container ${name} started successfully in ''${run_duration}s"
          exit 0
        fi

        nac_log "container ${name} exited with status ''${status} after ''${run_duration}s"
        if [ "$startup_attempt" -ge "$max_startup_attempts" ] || [ "$run_duration" -ge 10 ]; then
          nac_log "giving up after attempt ''${startup_attempt}; propagating status ''${status}"
          exit "$status"
        fi

        nac_log "${name} hit a transient runtime error during startup; retrying (''${startup_attempt}/''${max_startup_attempts})"
        nac_log "reissuing 'container system start --disable-kernel-install' before retry"
        ${bin} system start --disable-kernel-install >/dev/null 2>&1 || true
        sleep 2
        startup_attempt=$((startup_attempt + 1))
      done
    '';

  mkLaunchdPlist =
    label: serviceConfig:
    pkgs.writeText "${label}.plist" (lib.generators.toPlist { escape = true; } serviceConfig);

  mkManagedLaunchAgentPlist =
    {
      label,
      programArguments,
      logStem,
      runAtLoad,
      keepAlive ? null,
      extraConfig ? { },
    }:
    mkLaunchdPlist label (
      {
        Label = label;
        ProgramArguments = programArguments;
        LimitLoadToSessionType = [ "Background" ];
        RunAtLoad = runAtLoad;
        StandardOutPath = "${userHome}/Library/Logs/${logStem}.log";
        StandardErrorPath = "${userHome}/Library/Logs/${logStem}.err";
      }
      // lib.optionalAttrs (keepAlive != null) {
        KeepAlive = keepAlive;
      }
      // extraConfig
    );

  runtimePlist = mkManagedLaunchAgentPlist {
    label = runtimeLabel;
    programArguments = [ (toString bootstrapManagedContainersScript) ];
    logStem = "container-runtime";
    runAtLoad = true;
    keepAlive = {
      SuccessfulExit = false;
    };
    extraConfig = {
      EnvironmentVariables.${logContextVar} = runtimeLabel;
    };
  };

  containerPlists = lib.mapAttrs' (
    name: c:
    let
      label = "dev.apple.container.${name}";
    in
    lib.nameValuePair label {
      inherit label;
      plist = mkManagedLaunchAgentPlist {
        inherit label;
        programArguments = [ (toString (mkContainerRunScript name c)) ];
        logStem = "container-${name}";
        runAtLoad = false;
        keepAlive = {
          OtherJobEnabled = {
            "com.apple.container.apiserver" = true;
          };
        };
      };
      targetPath = "${managedAgentDir}/${label}.plist";
    }
  ) autoStartContainers;

  syncLaunchdFilesScript = pkgs.writeShellScript "sync-container-launchd-files" ''
    for cmd in chmod cmp install rm touch; do
      command -v "$cmd" >/dev/null 2>&1 || {
        echo "nix-apple-container: '$cmd' is required but not found in PATH" >&2
        exit 1
      }
    done

    sync_plist() {
      local label="$1"
      local src="$2"
      local dest="$3"
      local track_changes="$4"

      if [ ! -f "$dest" ] || ! cmp -s "$src" "$dest"; then
        install -o root -g wheel -m 644 "$src" "$dest"
        if [ "$track_changes" = 1 ]; then
          printf '%s\n' "$label" >> "$changed_labels_file"
        fi
      fi
    }

    install -d -m 755 -o root -g wheel "${managedAgentDir}"
    install -d -m 1777 "${launchdStateDir}"
    changed_labels_file="${changedManagedLabelsPath}"
    touch "$changed_labels_file"
    chmod 644 "$changed_labels_file"
    : > "$changed_labels_file"
    sync_plist "${runtimeLabel}" "${runtimePlist}" "${runtimeAgentPath}" 0
    ${
      if containerPlists == { } then
        ''
          rm -f "${managedAgentDir}"/dev.apple.container.*.plist
        ''
      else
        let
          desiredPatterns = lib.concatStringsSep "|" (
            lib.mapAttrsToList (label: _: lib.escapeShellArg label) containerPlists
          );
        in
        ''
          for existing in "${managedAgentDir}"/dev.apple.container.*.plist; do
            [ -f "$existing" ] || continue
            label="$(basename "$existing" .plist)"
            keep=0
            case "$label" in
              ${desiredPatterns})
                keep=1
                ;;
            esac
            if [ "$keep" -eq 0 ]; then
              rm -f "$existing"
            fi
          done
        ''
    }
    ${lib.concatStrings (
      lib.mapAttrsToList (_: spec: ''
        sync_plist "${spec.label}" "${spec.plist}" "${spec.targetPath}" 1
      '') containerPlists
    )}
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
        ${runAs} defaults delete com.apple.container.defaults dns.domain 2>/dev/null || true
        pkgutil --pkg-info com.apple.container-installer &>/dev/null && \
          sudo pkgutil --forget com.apple.container-installer 2>/dev/null || true
        CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
        if [ -n "$CONTAINER_UID" ]; then
          launchctl bootout "gui/$CONTAINER_UID/${runtimeLabel}" 2>/dev/null || true
          launchctl bootout "user/$CONTAINER_UID/${runtimeLabel}" 2>/dev/null || true
          ${bootoutManagedLabelsScript ""}
          for domain in "gui/$CONTAINER_UID" "user/$CONTAINER_UID"; do
            launchctl print-disabled "$domain" 2>/dev/null \
              | awk -F'"' '/dev\.apple\.container\.|nix-apple-container\.runtime/ {print $2}' \
              | while IFS= read -r label; do
                  [ -n "$label" ] || continue
                  launchctl enable "$domain/$label" >/dev/null 2>&1 || true
                done
          done
        fi
        rm -f "${runtimeAgentPath}"
        rm -f "${managedAgentDir}"/dev.apple.container.*.plist
        rm -rf "${launchdStateDir}"
        rm -rf "${appSupport}/launchd"
        rm -f "${userBuilderKey}" "${userBuilderPubKey}"
        rm -f "${systemBuilderKey}" "${systemBuilderPubKey}"
      '';
    })

    # Setup: runs when module is enabled
    (lib.mkIf cfg.enable {
      assertions =
        let
          badVolumes = lib.filterAttrs (
            _: c: builtins.any (v: !(lib.hasInfix ":" v)) c.volumes
          ) cfg.containers;
        in
        lib.optional (badVolumes != { }) {
          assertion = false;
          message = "nix-apple-container: containers ${lib.concatStringsSep ", " (lib.attrNames badVolumes)} have volumes without a ':'. Use host:container for bind mounts or name:container for named volumes.";
        }
        ++ lib.optional (cfg.user != config.system.primaryUser) {
          assertion = false;
          message = "nix-apple-container: services.containerization.user must match system.primaryUser (${config.system.primaryUser}) because the login-time runtime agent is installed only for the primary user.";
        };

      environment.systemPackages = [ cfg.package ];

      environment.etc."${resolverRelativePath}" = {
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

      # preActivation runs before later activation hooks. Ensure the runtime is
      # available so images can be loaded before the postActivation bootstrap
      # recreates the managed container jobs.
      system.activationScripts.preActivation.text = lib.mkAfter (
        lib.concatStrings [
          ''
            # If the apiserver is registered but its binary no longer exists (e.g.
            # package upgrade + nix-collect-garbage), launchd can't activate it and
            # every CLI command hangs.  Deregister the stale service so system start
            # can re-register with the current binary.
            CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
            if [ -n "$CONTAINER_UID" ]; then
              ${userDomainLoop "$CONTAINER_UID" ''
                APISERVER_BIN=$(launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- \
                  launchctl print "$domain/com.apple.container.apiserver" 2>/dev/null \
                  | grep "path = " | awk '{print $3}') || true
                if [ -n "$APISERVER_BIN" ] && [ ! -x "$APISERVER_BIN" ]; then
                  echo "nix-apple-container: deregistering stale apiserver from $domain ($APISERVER_BIN)..."
                  launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- \
                    launchctl bootout "$domain/com.apple.container.apiserver" 2>/dev/null || true
                fi
              ''}
            fi

            echo "nix-apple-container: syncing launchd assets..."
            ${syncLaunchdFilesScript}
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
          registryImagePullScript
        ]
      );

      # Reconcile containers: stop+rm undeclared containers.
      system.activationScripts.postActivation.text = lib.mkAfter ''
        echo "nix-apple-container: reconciling containers..."
        CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")

        # Now stop and remove containers not declared in config
        DECLARED="${lib.concatStringsSep " " (lib.attrNames cfg.containers)}"
        for cid in $(${runAs} ${bin} ls --all --quiet 2>/dev/null); do
          KEEP=false
          for d in $DECLARED; do
            if [ "$cid" = "$d" ]; then KEEP=true; break; fi
          done
          if [ "$KEEP" = "false" ]; then
            echo "nix-apple-container: stopping undeclared container $cid..."
            if [ -n "$CONTAINER_UID" ]; then
              launchctl bootout "gui/$CONTAINER_UID/dev.apple.container.$cid" 2>/dev/null || true
              launchctl bootout "user/$CONTAINER_UID/dev.apple.container.$cid" 2>/dev/null || true
              launchctl enable "gui/$CONTAINER_UID/dev.apple.container.$cid" >/dev/null 2>&1 || true
              launchctl enable "user/$CONTAINER_UID/dev.apple.container.$cid" >/dev/null 2>&1 || true
            fi
            rm -f "${managedAgentDir}/dev.apple.container.$cid.plist"
            ${runAs} ${bin} stop "$cid" 2>/dev/null || true
            ${runAs} ${bin} rm "$cid" 2>/dev/null || true
          fi
        done

        echo "nix-apple-container: bootstrapping launchd-managed containers..."
        ${bootstrapManagedContainersScript}
      '';
    })

  ]);
}
