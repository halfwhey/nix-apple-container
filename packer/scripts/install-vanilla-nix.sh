#!/bin/bash
set -euo pipefail

NIX_VERSION="${NIX_VERSION:-2.33.3}"

echo "==> Installing vanilla Nix ${NIX_VERSION} (multi-user)..."
curl -L "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" | sh -s -- --daemon --yes

# Explicit PATH (packer SSH sessions don't reload shell profiles)
export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"

# Enable flakes and nix-command
mkdir -p ~/.config/nix
cat > ~/.config/nix/nix.conf << 'EOF'
experimental-features = nix-command flakes
EOF

# If a local nix-serve is provided, configure as preferred substituter
if [ -n "${NIX_SERVE_HOST:-}" ]; then
  echo "==> Configuring local binary cache at ${NIX_SERVE_HOST}..."
  cat << EOF >> ~/.config/nix/nix.conf
substituters = http://${NIX_SERVE_HOST} https://cache.nixos.org
trusted-substituters = http://${NIX_SERVE_HOST}
require-sigs = false
EOF
fi

echo "==> Nix installed:"
nix --version
