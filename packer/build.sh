#!/bin/bash
# Build a Tart VM image with a local nix-serve binary cache for faster builds.
# Usage: ./build.sh <template.pkr.hcl> [packer args...]
# Example: ./build.sh macos-determinate.pkr.hcl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${1:?Usage: $0 <template.pkr.hcl> [packer args...]}"
shift

# Detect host IP on the vmnet interface (Tart's default subnet)
# Fall back to common defaults if detection fails
HOST_IP=$(ifconfig | grep -A4 'bridge100\|vmnet' | grep 'inet ' | awk '{print $2}' | head -1)
if [ -z "$HOST_IP" ]; then
  # Try common Tart host IPs
  for ip in 192.168.67.1 192.168.64.1; do
    if ifconfig | grep -q "$ip"; then
      HOST_IP="$ip"
      break
    fi
  done
fi

SERVE_PORT=5000
NIX_SERVE_PID=""

cleanup() {
  if [ -n "$NIX_SERVE_PID" ]; then
    echo "==> Stopping nix-serve (PID $NIX_SERVE_PID)..."
    kill "$NIX_SERVE_PID" 2>/dev/null || true
    wait "$NIX_SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -n "$HOST_IP" ]; then
  echo "==> Starting nix-serve on ${HOST_IP}:${SERVE_PORT}..."
  nix run nixpkgs#nix-serve-ng -- --listen "${HOST_IP}:${SERVE_PORT}" &
  NIX_SERVE_PID=$!
  sleep 2

  # Verify it's serving
  if curl -sf "http://${HOST_IP}:${SERVE_PORT}/nix-cache-info" > /dev/null 2>&1; then
    echo "==> nix-serve running at http://${HOST_IP}:${SERVE_PORT}"
    NIX_SERVE_HOST="${HOST_IP}:${SERVE_PORT}"
  else
    echo "==> WARNING: nix-serve failed to start, building without local cache"
    kill "$NIX_SERVE_PID" 2>/dev/null || true
    NIX_SERVE_PID=""
    NIX_SERVE_HOST=""
  fi
else
  echo "==> No vmnet interface detected, building without local cache"
  NIX_SERVE_HOST=""
fi

cd "$SCRIPT_DIR"
packer init "$TEMPLATE"
packer build -var "nix_serve_host=${NIX_SERVE_HOST}" "$@" "$TEMPLATE"
