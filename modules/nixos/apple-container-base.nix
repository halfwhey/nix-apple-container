# Base NixOS configuration for Apple container VMs.
# Adapted from Arion's container-systemd.nix.
# This module makes a NixOS system suitable for running inside
# an Apple container (lightweight VM with vminitd at the VM level).
{ config, lib, pkgs, ... }: {
  imports = [
    "${pkgs.path}/nixos/modules/profiles/minimal.nix"
  ];

  boot.isContainer = true;
  boot.specialFileSystems = lib.mkForce { };
  boot.loader.grub.enable = false;
  boot.kernel.enable = false;

  # Disable units that don't work in container VMs
  systemd.services.systemd-logind.enable = false;
  systemd.services.console-getty.enable = false;
  systemd.sockets.nix-daemon.enable = lib.mkDefault false;
  systemd.services.nix-daemon.enable = lib.mkDefault false;

  # Route journald to console for log visibility
  services.journald.console = "/dev/console";

  # Container detection
  environment.variables.container = "apple";
  networking.hostName = ""; # Inherited from --name

  # Minimal footprint
  documentation.enable = false;
  nix.enable = lib.mkDefault false;

  system.stateVersion = lib.mkDefault "24.11";
}
