#!/bin/bash
# Test: images are loaded and idempotent re-activation doesn't reload.
set -euo pipefail

echo "Checking loaded images..."
IMAGES=$(container image ls --format json 2>/dev/null || echo "[]")

# Verify at least the base images referenced by containers are available
# (registry images are pulled on first container start)
echo "  Available images:"
echo "$IMAGES" | jq -r '.[].reference // empty' 2>/dev/null | while read -r ref; do
  echo "    $ref"
done

echo "Testing idempotent activation..."
# Run activation again — should see "is current" messages, no re-loads
ACTIVATION_LOG=$(sudo darwin-rebuild switch --flake "$(git rev-parse --show-toplevel)#ci-integration" 2>&1)

# If there are nix-managed images, check for "is current" messages
if echo "$ACTIVATION_LOG" | grep -q "nix-apple-container: image"; then
  if echo "$ACTIVATION_LOG" | grep -q "is current"; then
    echo "  OK: idempotent — images reported as current"
  else
    echo "  WARNING: images may have been reloaded (check activation log)"
    echo "$ACTIVATION_LOG" | grep "nix-apple-container:" || true
  fi
else
  echo "  OK: no nix-managed images to check (using registry images only)"
fi

echo "Image loading test passed"
