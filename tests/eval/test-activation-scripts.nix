{ evalDarwin, assertContains, mkCheck, ... }:

let
  config = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization = {
        enable = true;
        containers.web = {
          image = "nginx:alpine";
          autoStart = true;
        };
      };
    }];
  };

  preText = config.system.activationScripts.preActivation.text;
  postText = config.system.activationScripts.postActivation.text;

in mkCheck "activation-scripts" [
  # preActivation: runtime start with kernel install disabled
  (assertContains "runtime-start" preText "system start --disable-kernel-install")
  # preActivation: kernel symlink
  (assertContains "kernel-symlink" preText "default.kernel-arm64")
  # preActivation: container prune
  (assertContains "prune" preText "container prune")
  # preActivation: runtime status check (idempotent start)
  (assertContains "status-check" preText "system status")
  # postActivation: reconciliation
  (assertContains "reconcile" postText "reconciling containers")
  # postActivation: agent unload logic
  (assertContains "agent-unload" postText "dev.apple.container.*.plist")
  # postActivation: stops undeclared containers
  (assertContains "stop-undeclared" postText "stopping undeclared container")
]
