#!/bin/bash
set -euo pipefail

# Source nix profile
# shellcheck disable=SC1091
[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && \
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

echo "==> Bootstrapping nix-darwin..."

# Determine which Nix variant is installed
# Determinate Nix leaves a receipt file; vanilla Nix does not
if [ -f /nix/receipt.json ]; then
  NIX_ENABLE="false"
  echo "  Detected Determinate Nix — setting nix.enable = false"
else
  NIX_ENABLE="true"
  echo "  Detected vanilla Nix — setting nix.enable = true"
fi

# Create a minimal nix-darwin flake for bootstrapping
mkdir -p ~/.config/nix-darwin
cat > ~/.config/nix-darwin/flake.nix << NIXEOF
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nix-darwin, ... }: {
    darwinConfigurations.default = nix-darwin.lib.darwinSystem {
      modules = [{
        system.stateVersion = 5;
        nixpkgs.hostPlatform = "aarch64-darwin";
        system.primaryUser = "admin";
        nix.enable = ${NIX_ENABLE};
        security.pam.services.sudo_local.touchIdAuth = true;
      }];
    };
  };
}
NIXEOF

# Bootstrap nix-darwin
sudo nix run github:LnL7/nix-darwin -- switch --flake ~/.config/nix-darwin#default

echo "==> nix-darwin bootstrapped:"
darwin-rebuild --version
