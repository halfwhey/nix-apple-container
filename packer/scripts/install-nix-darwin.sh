#!/bin/bash
set -euo pipefail

# Explicit PATH — nix binaries + nix-darwin system path
export PATH="/run/current-system/sw/bin:/usr/local/bin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"

echo "==> Bootstrapping nix-darwin..."

# Detect Nix variant via receipt file (Determinate Nix creates this)
if [ -f /nix/receipt.json ]; then
  NIX_ENABLE="false"
  echo "  Detected Determinate Nix — setting nix.enable = false"
else
  NIX_ENABLE="true"
  echo "  Detected vanilla Nix — setting nix.enable = true"
fi

# Pin to same revisions as dev/flake.lock for max cache hits
mkdir -p ~/.config/nix-darwin
cat > ~/.config/nix-darwin/flake.nix << NIXEOF
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/e80236013dc8b77aa49ca90e7a12d86f5d8d64c9";
    nix-darwin.url = "github:LnL7/nix-darwin/da529ac9e46f25ed5616fd634079a5f3c579135f";
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

sudo nix run github:LnL7/nix-darwin -- switch --flake ~/.config/nix-darwin#default

# darwin-rebuild is now at /run/current-system/sw/bin/
export PATH="/run/current-system/sw/bin:$PATH"

echo "==> nix-darwin bootstrapped:"
darwin-rebuild --version
