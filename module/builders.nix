{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.services.containerization;
  builderCfg = cfg."linux-builder";
  anyBuilderEnabled = builderCfg.aarch64.enable || builderCfg.x86_64.enable;

  # https://github.com/apple/container/issues/1142
  rosettaCompatKernel = pkgs.callPackage ../pkgs/kernel.nix {
    version = "3.24.0";
    hash = "sha256-1WvjYfBMNeHXWv//S3L5LCeAhcffGvp5QGuEfRwQffU=";
  };

  userHome =
    if config.users.users ? ${cfg.user} then
      config.users.users.${cfg.user}.home
    else
      "/Users/${cfg.user}";

  userBuilderKey = "${userHome}/.ssh/nix-builder_ed25519";
  userBuilderPubKey = "${userHome}/.ssh/nix-builder_ed25519.pub";

  # Builder architecture definitions — only platform and defaults differ
  builderArches = {
    aarch64 = {
      nixSystems = [ "aarch64-linux" ];
      nameSuffix = "aarch64";
      platform = null;
      defaultKernel = null;
      defaultPort = 31022;
    };
    x86_64 = {
      nixSystems = [ "x86_64-linux" ];
      # `x86_64` is valid in Nix attr paths (`linux-builder.x86_64`), but the
      # machine-spec/store-URI hostname field should avoid underscores.
      nameSuffix = "amd64";
      platform = "linux/amd64";
      defaultKernel = rosettaCompatKernel;
      defaultPort = 31023;
    };
  };

  mkBuilderArchOptions =
    _arch:
    {
      defaultPort,
      defaultKernel ? null,
      ...
    }:
    {
      enable = lib.mkEnableOption "Linux builder container";
      sshPort = lib.mkOption {
        type = lib.types.port;
        default = defaultPort;
        description = "Host port for SSH to the builder container.";
      };
      maxJobs = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Maximum number of parallel build jobs on the builder.";
      };
      speedFactor = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = ''
          Relative speed of the builder.
          Arbitrary integer for Nix scheduler prioritization.
        '';
      };
      cores = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Number of CPUs to allocate to the builder container.";
      };
      memory = lib.mkOption {
        type = lib.types.str;
        default = "1024M";
        description = "Amount of memory to allocate to the builder container.";
      };
      kernel = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = defaultKernel;
        description = ''
          Kernel binary passed to this builder via `container run --kernel`.
          `null` uses the runtime default kernel. The x86_64 builder defaults
          to a Rosetta-compatible kernel.
        '';
      };
    };

  # Generate per-arch config blocks (container, SSH, buildMachines)
  mkBuilderArchConfig =
    arch:
    {
      nixSystems,
      nameSuffix,
      platform,
      ...
    }:
    let
      archCfg = builderCfg.${arch};
      name = "nix-builder-${nameSuffix}";
      platformArgs = lib.optionals (platform != null) [
        "--platform"
        platform
      ];
      kernelArgs = lib.optionals (archCfg.kernel != null) [
        "--kernel"
        (toString archCfg.kernel)
      ];
    in
    [
      # Container and SSH config
      (lib.mkIf (cfg.enable && archCfg.enable) {
        services.containerization.containers.${name} = {
          image = builderCfg.image;
          autoStart = true;
          extraArgs =
            platformArgs
            ++ kernelArgs
            ++ [
              "--publish"
              "${toString archCfg.sshPort}:22"
              "--cpus"
              "${toString archCfg.cores}"
              "--memory"
              "${toString archCfg.memory}"
            ];
        };

        # SSH alias for buildMachines (which has no port field).
        # StrictHostKeyChecking=no because the builder generates a new
        # host key on every container restart.
        environment.etc."ssh/ssh_config.d/100-${name}.conf".text = ''
          Host ${name}
            HostName localhost
            Port ${toString archCfg.sshPort}
            User root
            IdentityFile ${userBuilderKey}
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
        '';
      })

      # Declarative Nix config (plain nix-darwin)
      (lib.mkIf (cfg.enable && archCfg.enable && config.nix.enable) {
        nix.buildMachines = [
          {
            hostName = name;
            protocol = "ssh-ng";
            sshUser = "root";
            sshKey = userBuilderKey;
            systems = nixSystems;
            maxJobs = archCfg.maxJobs;
            speedFactor = archCfg.speedFactor;
            supportedFeatures = [ "big-parallel" ];
          }
        ];
        nix.distributedBuilds = lib.mkDefault true;
        nix.settings.builders-use-substitutes = lib.mkDefault true;
      })
    ];
in
{
  options.services.containerization."linux-builder" = {
    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/halfwhey/nix-builder:v2-nix2.34.6";
      description = "Docker image for the Nix remote builder (multi-arch, shared across architectures).";
    };
  }
  // lib.mapAttrs mkBuilderArchOptions builderArches;

  config = lib.mkMerge (
    [
      # Linux builder cleanup (module enabled but no builders active)
      (lib.mkIf (cfg.enable && !anyBuilderEnabled) {
        system.activationScripts.postActivation.text = lib.mkAfter ''
          if [ -f "${userBuilderKey}" ] || [ -f /etc/nix/builder_ed25519 ]; then
            echo "nix-apple-container: removing linux builder resources..."
          fi
          rm -f "${userBuilderKey}" "${userBuilderPubKey}"
          rm -f /etc/nix/builder_ed25519 /etc/nix/builder_ed25519.pub
        '';
      })

      # Linux builder — shared SSH key (all backends, any arch)
      (lib.mkIf (cfg.enable && anyBuilderEnabled) {
        # Keep a single canonical client key in the configured user's home.
        # Root can still read it for daemon-driven builds, so no duplicate
        # /etc/nix copy is needed.
        system.activationScripts.preActivation.text = lib.mkAfter ''
          install -d -m 700 -o ${cfg.user} "${userHome}/.ssh"
          if ! cmp -s ${../builder/builder_ed25519} "${userBuilderKey}" 2>/dev/null; then
            install -o ${cfg.user} -m 600 ${../builder/builder_ed25519} "${userBuilderKey}"
            install -o ${cfg.user} -m 644 ${../builder/builder_ed25519.pub} "${userBuilderPubKey}"
          fi
        '';
      })

      # Port conflict assertion (both builders enabled)
      (lib.mkIf (cfg.enable && builderCfg.aarch64.enable && builderCfg.x86_64.enable) {
        assertions = [
          {
            assertion = builderCfg.aarch64.sshPort != builderCfg.x86_64.sshPort;
            message = "nix-apple-container: linux-builder.aarch64.sshPort and linux-builder.x86_64.sshPort must be different.";
          }
        ];
      })

      # Linux builder — Determinate Nix config (nix.enable = false, determinateNix module available)
      (lib.mkIf (cfg.enable && anyBuilderEnabled && !config.nix.enable) (
        if options ? determinateNix then
          {
            determinateNix = {
              buildMachines = lib.concatLists (
                lib.mapAttrsToList (
                  arch:
                  { nixSystems, nameSuffix, ... }:
                  let
                    archCfg = builderCfg.${arch};
                  in
                  lib.optional archCfg.enable {
                    hostName = "nix-builder-${nameSuffix}";
                    protocol = "ssh-ng";
                    sshUser = "root";
                    sshKey = userBuilderKey;
                    systems = nixSystems;
                    maxJobs = archCfg.maxJobs;
                    speedFactor = archCfg.speedFactor;
                    supportedFeatures = [ "big-parallel" ];
                  }
                ) builderArches
              );
              distributedBuilds = true;
              customSettings.builders-use-substitutes = true;
            };
            system.activationScripts.postActivation.text = lib.mkAfter ''
              launchctl print system/systems.determinate.nix-daemon >/dev/null 2>&1 && \
                launchctl kickstart -k system/systems.determinate.nix-daemon >/dev/null 2>&1 || true
            '';
          }
        else
          {
            warnings = [
              "nix-apple-container: linux-builder is enabled but neither nix.enable nor the determinateNix module is available. Builder Nix config (buildMachines, distributedBuilds) must be managed manually."
            ];
          }
      ))
    ]
    ++ lib.concatLists (lib.mapAttrsToList mkBuilderArchConfig builderArches)
  );
}
