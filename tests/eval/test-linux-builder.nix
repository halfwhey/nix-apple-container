{ evalDarwin, assertEq, assertContains, mkCheck, ... }:

let
  # Vanilla Nix path (nix.enable = true, the default)
  configVanilla = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization = {
        enable = true;
        linuxBuilder.enable = true;
      };
    }];
  };

  # Determinate Nix path (nix.enable = false + determinateNix stub)
  configDeterminate = evalDarwin {
    modules = [
      ../fixtures/determinateNix-stub.nix
      {
        system.primaryUser = "testuser";
        nix.enable = false;
        services.containerization = {
          enable = true;
          linuxBuilder.enable = true;
        };
      }
    ];
  };

in mkCheck "linux-builder" [
  # === Vanilla Nix path ===

  # nix-builder container is auto-added
  (assertEq "builder-container-exists" (configVanilla.services.containerization.containers ? "nix-builder") true)
  (assertEq "builder-autostart" configVanilla.services.containerization.containers.nix-builder.autoStart true)
  (assertContains "builder-image" configVanilla.services.containerization.containers.nix-builder.image "nix-builder")
  # Port forwarding for SSH
  (assertEq "builder-ssh-port"
    (builtins.elem "--publish" configVanilla.services.containerization.containers.nix-builder.extraArgs)
    true)
  # SSH config
  (assertContains "ssh-host-alias" configVanilla.programs.ssh.extraConfig "Host nix-builder")
  (assertContains "ssh-port" configVanilla.programs.ssh.extraConfig "Port 31022")
  (assertContains "ssh-identity" configVanilla.programs.ssh.extraConfig "builder_ed25519")
  (assertContains "ssh-no-strict" configVanilla.programs.ssh.extraConfig "StrictHostKeyChecking no")
  # nix.buildMachines populated
  (assertEq "build-machines-count" (builtins.length configVanilla.nix.buildMachines) 1)
  (assertEq "build-machines-host" (builtins.head configVanilla.nix.buildMachines).hostName "nix-builder")
  (assertEq "build-machines-systems" (builtins.head configVanilla.nix.buildMachines).systems ["aarch64-linux"])
  (assertEq "build-machines-maxjobs" (builtins.head configVanilla.nix.buildMachines).maxJobs 4)
  (assertEq "distributed-builds" configVanilla.nix.distributedBuilds true)

  # === Determinate Nix path ===

  # determinateNix.customSettings has builders configured
  (assertEq "determinate-has-builders" (configDeterminate.determinateNix.customSettings ? "builders") true)
  (assertContains "determinate-builders-host" configDeterminate.determinateNix.customSettings.builders "nix-builder")
  (assertContains "determinate-builders-arch" configDeterminate.determinateNix.customSettings.builders "aarch64-linux")
  (assertEq "determinate-substitutes" configDeterminate.determinateNix.customSettings.builders-use-substitutes true)
  # nix.buildMachines is not accessible when nix.enable = false (nix-darwin throws),
  # so we verify only that determinateNix.customSettings is populated instead
]
