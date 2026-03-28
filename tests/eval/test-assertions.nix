{ evalDarwin, assertEq, assertContains, mkCheck, lib, ... }:

let
  # Config with a bad volume (missing ':')
  configBad = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization = {
        enable = true;
        containers.bad = {
          image = "alpine:latest";
          volumes = [ "no-colon" ];
        };
      };
    }];
  };
  failedBad = builtins.filter (a: !a.assertion) configBad.assertions;

  # Config with valid volumes
  configGood = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization = {
        enable = true;
        containers.good = {
          image = "alpine:latest";
          volumes = [ "/host:/container" "named-vol:/data" ];
        };
      };
    }];
  };
  # Filter for our module's assertion specifically
  ourFailedGood = builtins.filter
    (a: !a.assertion && lib.hasInfix "nix-apple-container" (a.message or ""))
    configGood.assertions;

in mkCheck "assertions" [
  # Bad volume triggers our assertion
  (assertEq "bad-volume-fails" (builtins.length failedBad > 0) true)
  (assertContains "bad-volume-message" (builtins.head failedBad).message "without a ':'")
  (assertContains "bad-volume-names-container" (builtins.head failedBad).message "bad")
  # Valid volumes don't trigger our assertion
  (assertEq "good-volume-passes" (builtins.length ourFailedGood) 0)
]
