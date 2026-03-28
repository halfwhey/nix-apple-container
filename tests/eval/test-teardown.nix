{ evalDarwin, assertContains, assertNotContains, mkCheck, ... }:

let
  config = evalDarwin {
    modules = [{
      system.primaryUser = "testuser";
      services.containerization.enable = false;
    }];
  };

  postText = config.system.activationScripts.postActivation.text;

in mkCheck "teardown" [
  # Runtime is stopped
  (assertContains "system-stop" postText "system stop")
  # Agents are unloaded (glob pattern)
  (assertContains "agent-unload-glob" postText "dev.apple.container.*.plist")
  # Kernels directory is removed
  (assertContains "remove-kernels" postText "kernels")
  # Defaults are deleted
  (assertContains "defaults-delete" postText "defaults delete com.apple.container")
  # Package receipt is forgotten
  (assertContains "pkgutil-forget" postText "pkgutil --forget com.apple.container-installer")
  # Builder SSH keys are removed
  (assertContains "builder-key-removal" postText "rm -f /etc/nix/builder_ed25519")
  # Content/ingest is cleaned
  (assertContains "ingest-cleanup" postText "content/ingest")
  # APP_SUPPORT guard is present (conditional on directory existing)
  (assertContains "app-support-guard" postText "if [ -d \"$APP_SUPPORT\" ]")
]
