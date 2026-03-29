#!/bin/bash
set -euo pipefail

# Explicit PATH — nix binaries + nix-darwin system path
export PATH="/run/current-system/sw/bin:/usr/local/bin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"

# Version pins (overridable via environment)
NIXPKGS_REV="${NIXPKGS_REV:-e80236013dc8b77aa49ca90e7a12d86f5d8d64c9}"
NIX_DARWIN_REV="${NIX_DARWIN_REV:-da529ac9e46f25ed5616fd634079a5f3c579135f}"

echo "==> Bootstrapping nix-darwin..."

mkdir -p ~/.config/nix-darwin

# Detect Nix variant via receipt file (Determinate Nix creates this)
if [ -f /nix/receipt.json ]; then
  echo "  Detected Determinate Nix — setting nix.enable = false"

  cat > ~/.config/nix-darwin/flake.nix << NIXEOF
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/${NIXPKGS_REV}";
    nix-darwin.url = "github:LnL7/nix-darwin/${NIX_DARWIN_REV}";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nix-darwin, ... }: {
    darwinConfigurations.default = nix-darwin.lib.darwinSystem {
      modules = [{
        system.stateVersion = 5;
        nixpkgs.hostPlatform = "aarch64-darwin";
        system.primaryUser = "admin";
        nix.enable = false;
        security.pam.services.sudo_local.touchIdAuth = true;
      }];
    };
  };
}
NIXEOF

else
  echo "  Detected vanilla Nix — setting nix.enable = true"

  cat > ~/.config/nix-darwin/flake.nix << NIXEOF
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/${NIXPKGS_REV}";
    nix-darwin.url = "github:LnL7/nix-darwin/${NIX_DARWIN_REV}";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nix-darwin, ... }: {
    darwinConfigurations.default = nix-darwin.lib.darwinSystem {
      modules = [{
        system.stateVersion = 5;
        nixpkgs.hostPlatform = "aarch64-darwin";
        system.primaryUser = "admin";
        nix.enable = true;
        security.pam.services.sudo_local.touchIdAuth = true;
      }];
    };
  };
}
NIXEOF
fi

sudo nix run github:LnL7/nix-darwin -- switch --flake ~/.config/nix-darwin#default

# darwin-rebuild is now at /run/current-system/sw/bin/
export PATH="/run/current-system/sw/bin:$PATH"

# Clean up build-only cache config — not needed in the final image
sudo rm -f /etc/nix/nix.custom.conf

echo "==> nix-darwin bootstrapped:"
nix flake metadata ~/.config/nix-darwin
