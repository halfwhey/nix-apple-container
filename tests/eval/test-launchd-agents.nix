{ evalDarwin, assertEq, mkCheck, ... }:

let
  config = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization = {
        enable = true;
        containers.web = {
          image = "nginx:alpine";
          autoStart = true;
          extraArgs = [ "--publish" "8080:80" ];
          labels = { "app" = "web"; };
        };
        containers.worker = {
          image = "alpine:latest";
          autoStart = true;
          cmd = [ "sleep" "infinity" ];
          env = { MODE = "worker"; };
          init = true;
          readOnly = true;
        };
        containers.reserved = {
          image = "alpine:latest";
          autoStart = false;
        };
      };
    }];
  };
  agents = config.launchd.user.agents;

in mkCheck "launchd-agents" [
  # autoStart containers produce agents
  (assertEq "web-agent-exists" (agents ? "container-web") true)
  (assertEq "worker-agent-exists" (agents ? "container-worker") true)
  # non-autoStart container does NOT produce an agent
  (assertEq "reserved-no-agent" (agents ? "container-reserved") false)
  # Check Label follows plist naming convention
  (assertEq "web-label" agents."container-web".serviceConfig.Label "dev.apple.container.web")
  (assertEq "worker-label" agents."container-worker".serviceConfig.Label "dev.apple.container.worker")
  # Check RunAtLoad and KeepAlive
  (assertEq "web-run-at-load" agents."container-web".serviceConfig.RunAtLoad true)
  (assertEq "web-keep-alive" agents."container-web".serviceConfig.KeepAlive true)
  # ProgramArguments points to a script (single element list with a store path)
  (assertEq "web-program-args-length" (builtins.length agents."container-web".serviceConfig.ProgramArguments) 1)
  # Log paths are set
  (assertEq "web-stdout" agents."container-web".serviceConfig.StandardOutPath "/Users/testuser/Library/Logs/container-web.log")
  (assertEq "web-stderr" agents."container-web".serviceConfig.StandardErrorPath "/Users/testuser/Library/Logs/container-web.err")
]
