#!/bin/bash
set -euo pipefail

echo "==> Installing Determinate Nix..."
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install --no-confirm

# Source nix profile for subsequent provisioners
# shellcheck disable=SC1091
[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && \
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

echo "==> Determinate Nix installed:"
nix --version
