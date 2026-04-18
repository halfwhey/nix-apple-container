{
  config,
  lib,
  ...
}:

let
  cfg = config.services.containerization;

  userHome =
    if config.users.users ? ${cfg.user} then
      config.users.users.${cfg.user}.home
    else
      "/Users/${cfg.user}";

  userAgentDir = "${userHome}/Library/LaunchAgents";
  systemAgentDir = "/Library/LaunchAgents";
  systemDaemonDir = "/Library/LaunchDaemons";
  runtimeLabel = "nix-apple-container.runtime";

  # nix-darwin skips userLaunchd cleanup when no user agents remain in the
  # current config. Remove stale container user agents explicitly on disable.
  legacyUserAgentCleanup = ''
    CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
    if [ -d "${userAgentDir}" ]; then
      for plist in "${userAgentDir}/${runtimeLabel}.plist" "${userAgentDir}"/dev.apple.container.*.plist; do
        [ -f "$plist" ] || continue
        agent_name="$(basename "$plist" .plist)"
        echo "nix-apple-container: removing legacy user launch agent $agent_name..."
        if [ -n "$CONTAINER_UID" ]; then
          launchctl asuser "$CONTAINER_UID" sudo --user="${cfg.user}" -- launchctl unload "$plist" 2>/dev/null || true
          launchctl bootout "gui/$CONTAINER_UID/$agent_name" 2>/dev/null || true
          launchctl bootout "user/$CONTAINER_UID/$agent_name" 2>/dev/null || true
        fi
        sudo --user="${cfg.user}" -- rm -f "$plist"
      done
    fi
  '';

  # One broken migration placed container jobs in /Library/LaunchAgents.
  legacySystemAgentCleanup = ''
    CONTAINER_UID=$(id -u "${cfg.user}" 2>/dev/null || echo "")
    if [ -d "${systemAgentDir}" ]; then
      for plist in "${systemAgentDir}/${runtimeLabel}.plist" "${systemAgentDir}"/dev.apple.container.*.plist; do
        [ -f "$plist" ] || continue
        agent_name="$(basename "$plist" .plist)"
        echo "nix-apple-container: removing legacy system launch agent $agent_name..."
        if [ -n "$CONTAINER_UID" ]; then
          launchctl bootout "gui/$CONTAINER_UID/$agent_name" 2>/dev/null || true
          launchctl bootout "user/$CONTAINER_UID/$agent_name" 2>/dev/null || true
        fi
        rm -f "$plist"
      done
    fi
  '';

  # Another broken revision moved the runtime and container jobs into system
  # LaunchDaemons, which puts Apple container in the wrong launchd domain.
  legacySystemDaemonCleanup = ''
    if [ -d "${systemDaemonDir}" ]; then
      for plist in "${systemDaemonDir}/${runtimeLabel}.plist" "${systemDaemonDir}"/dev.apple.container.*.plist; do
        [ -f "$plist" ] || continue
        agent_name="$(basename "$plist" .plist)"
        echo "nix-apple-container: removing legacy system launch daemon $agent_name..."
        launchctl bootout "system/$agent_name" 2>/dev/null || true
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
      done
    fi
  '';
in
{
  imports = [
    # Backward compat: linuxBuilder.* → linux-builder.aarch64.* / linux-builder.image
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "enable" ]
      [ "services" "containerization" "linux-builder" "aarch64" "enable" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "image" ]
      [ "services" "containerization" "linux-builder" "image" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "sshPort" ]
      [ "services" "containerization" "linux-builder" "aarch64" "sshPort" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "maxJobs" ]
      [ "services" "containerization" "linux-builder" "aarch64" "maxJobs" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "speedFactor" ]
      [ "services" "containerization" "linux-builder" "aarch64" "speedFactor" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "cores" ]
      [ "services" "containerization" "linux-builder" "aarch64" "cores" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "containerization" "linuxBuilder" "memory" ]
      [ "services" "containerization" "linux-builder" "aarch64" "memory" ]
    )
  ];

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.etc."resolver/containerization.test".knownSha256Hashes = [
        # Accept the previously hand-written resolver file on first migration
        # so activation can replace it with the declarative /etc symlink.
        "99b89c6edbb7edea675a76545841411eec5cca0d6222be61769f83f5828691b6"
      ];

      system.activationScripts.preActivation.text = lib.mkBefore ''
        # Older broken revisions placed Apple container jobs in system
        # LaunchAgents/LaunchDaemons. Remove those before nix-darwin's launchd
        # phase so the current user-agent setup can take over cleanly.
        ${legacySystemAgentCleanup}
        ${legacySystemDaemonCleanup}
      '';

      system.activationScripts.etc.text = lib.mkAfter ''
        if [ -e /etc/resolver/containerization.test.before-nix-darwin ]; then
          rm /etc/resolver/containerization.test.before-nix-darwin
        fi
      '';
    })

    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = lib.mkBefore ''
        ${legacyUserAgentCleanup}
        ${legacySystemAgentCleanup}
        ${legacySystemDaemonCleanup}
      '';
    })
  ];
}
