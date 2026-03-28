{ ... }: {
  system.stateVersion = 5;
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.primaryUser = "admin";

  services.containerization = {
    enable = true;
    user = "admin";

    containers.nginx = {
      image = "nginx:alpine";
      autoStart = true;
      extraArgs = [ "--publish" "18080:80" ];
      labels = { "ci.test" = "true"; };
    };

    containers.full-options = {
      image = "alpine:latest";
      autoStart = true;
      cmd = [ "sleep" "infinity" ];
      env = { TEST_VAR = "hello"; };
      init = true;
      readOnly = true;
    };

    containers.reserved = {
      image = "alpine:latest";
      autoStart = false;
    };

    linuxBuilder.enable = true;
  };
}
