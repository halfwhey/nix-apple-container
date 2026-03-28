{ ... }: {
  system.stateVersion = 5;
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.primaryUser = "admin";

  services.containerization.enable = false;
}
