#!/bin/bash
set -euo pipefail

echo "==> Installing vanilla Nix (multi-user)..."
curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes

# Source nix profile for subsequent provisioners
# shellcheck disable=SC1091
[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && \
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

# Enable flakes and nix-command
mkdir -p ~/.config/nix
cat > ~/.config/nix/nix.conf << 'EOF'
experimental-features = nix-command flakes
EOF

echo "==> Nix installed:"
nix --version
