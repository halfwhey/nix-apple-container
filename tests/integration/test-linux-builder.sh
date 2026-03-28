#!/bin/bash
# Test: linux builder SSH access and remote build capability.
set -euo pipefail

SSH_KEY="/etc/nix/builder_ed25519"
SSH_PORT=31022

echo "Checking builder SSH key exists..."
if [ ! -f "$SSH_KEY" ]; then
  echo "FAIL: $SSH_KEY not found"
  exit 1
fi
echo "  OK: SSH key exists"

# Wait for builder to be ready (SSH may take a moment after container start)
echo "Waiting for builder SSH to be ready..."
RETRIES=30
for i in $(seq 1 $RETRIES); do
  if ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 root@localhost true 2>/dev/null; then
    echo "  OK: SSH connection succeeded (attempt $i)"
    break
  fi
  if [ "$i" -eq "$RETRIES" ]; then
    echo "  FAIL: SSH not ready after $RETRIES attempts"
    exit 1
  fi
  sleep 2
done

echo "Checking nix is available in builder..."
BUILDER_NIX_VERSION=$(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@localhost "nix --version" 2>/dev/null)
echo "  OK: Builder nix version: $BUILDER_NIX_VERSION"

echo "Testing aarch64-linux remote build..."
# Build a trivial derivation via the remote builder
nix build --impure --expr '
  let pkgs = (import <nixpkgs> { system = "aarch64-linux"; });
  in pkgs.runCommand "builder-test" {} "echo hello > $out"
' -o /tmp/builder-test-result 2>&1 || {
  echo "  FAIL: remote build failed"
  exit 1
}

if [ -f /tmp/builder-test-result ] || [ -L /tmp/builder-test-result ]; then
  echo "  OK: aarch64-linux remote build succeeded"
  rm -f /tmp/builder-test-result
else
  echo "  FAIL: build result not found"
  exit 1
fi

echo "Linux builder test passed"
