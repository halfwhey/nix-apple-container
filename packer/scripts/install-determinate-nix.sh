#!/bin/bash
set -euo pipefail

echo "==> Installing Determinate Nix..."
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install macos --no-confirm --determinate

# Explicit PATH (packer SSH sessions don't reload shell profiles)
export PATH="/usr/local/bin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"

# If a local nix-serve is provided, configure it as preferred substituter
if [ -n "${NIX_SERVE_HOST:-}" ]; then
  echo "==> Configuring local binary cache at ${NIX_SERVE_HOST}..."
  cat << EOF | sudo tee /etc/nix/nix.custom.conf
substituters = http://${NIX_SERVE_HOST} https://cache.nixos.org https://install.determinate.systems
trusted-substituters = http://${NIX_SERVE_HOST}
require-sigs = false
EOF
  sudo launchctl kickstart -k system/org.nixos.nix-daemon
fi

echo "==> Determinate Nix installed:"
nix --version
