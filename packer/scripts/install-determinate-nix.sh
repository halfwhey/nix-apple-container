#!/bin/bash
set -euo pipefail

: "${NIX_INSTALLER_URL:?NIX_INSTALLER_URL must be set}"

echo "==> Installing Determinate Nix from ${NIX_INSTALLER_URL}..."
curl --proto '=https' --tlsv1.2 -sSf -L "$NIX_INSTALLER_URL" \
  | sh -s -- install macos --no-confirm --determinate

# Explicit PATH (packer SSH sessions don't reload shell profiles)
export PATH="/usr/local/bin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"

# Configure local binary cache so the daemon has it in memory before
# nix-darwin bootstrap. install-nix-darwin.sh renames this file before
# the switch to avoid the /etc conflict, but the daemon retains the
# settings until it's restarted by nix-darwin activation.
if [ -n "${NIX_SERVE_HOST:-}" ]; then
  echo "==> Configuring local binary cache at ${NIX_SERVE_HOST}..."
  cat << EOF | sudo tee /etc/nix/nix.custom.conf
substituters = http://${NIX_SERVE_HOST} https://cache.nixos.org https://install.determinate.systems
trusted-substituters = http://${NIX_SERVE_HOST}
require-sigs = false
EOF
fi

echo "==> Determinate Nix installed:"
nix --version
