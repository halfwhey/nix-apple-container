#!/bin/bash
# Build a Tart VM image with a local nix-serve binary cache for faster builds.
# Usage: ./build.sh <template.pkr.hcl> [packer args...]
# Example: ./build.sh macos-determinate.pkr.hcl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${1:?Usage: $0 <template.pkr.hcl> [packer args...]}"
shift

NIX_SERVE_HOST='*'
NIX_SERVE_PORT='5000'
NIX_SERVE_PID=""

cleanup() {
  if [ -n "$NIX_SERVE_PID" ]; then
    echo "==> Stopping nix-serve (PID $NIX_SERVE_PID)..."
    kill "$NIX_SERVE_PID" 2>/dev/null || true
    wait "$NIX_SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "==> Starting nix-serve on ${NIX_SERVE_HOST}:${NIX_SERVE_PORT}..."
nix-serve --host "$NIX_SERVE_HOST" --port "${NIX_SERVE_PORT}" --priority 1 &
NIX_SERVE_PID=$!
sleep 2

VM_CACHE="192.168.67.1:${NIX_SERVE_PORT}"

if curl -sf "http://127.0.0.1:${NIX_SERVE_PORT}/nix-cache-info" > /dev/null 2>&1; then
  echo "==> nix-serve running (VM will use http://${VM_CACHE})"
else
  echo "==> WARNING: nix-serve failed to start, building without local cache"
  kill "$NIX_SERVE_PID" 2>/dev/null || true
  NIX_SERVE_PID=""
  VM_CACHE=""
fi

cd "$SCRIPT_DIR"
packer init "$TEMPLATE"
packer build -on-error=abort -var "nix_serve_host=${VM_CACHE}" "$@" "$TEMPLATE"
