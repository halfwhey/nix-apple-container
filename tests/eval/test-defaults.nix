{ evalDarwin, assertEq, mkCheck, ... }:

let
  config = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization.enable = true;
    }];
  };
  cfg = config.services.containerization;
in mkCheck "defaults" [
  (assertEq "no-containers" cfg.containers {})
  (assertEq "no-images" cfg.images {})
  (assertEq "preserveImages-default" cfg.preserveImagesOnDisable false)
  (assertEq "preserveVolumes-default" cfg.preserveVolumesOnDisable false)
  (assertEq "builder-disabled" cfg.linuxBuilder.enable false)
  (assertEq "builder-port-default" cfg.linuxBuilder.sshPort 31022)
  (assertEq "builder-maxJobs-default" cfg.linuxBuilder.maxJobs 4)
  (assertEq "user-follows-primaryUser" cfg.user "testuser")
  # systemPackages contains the container CLI
  (builtins.any (p: (p.pname or "") == "apple-container") config.environment.systemPackages)
]
