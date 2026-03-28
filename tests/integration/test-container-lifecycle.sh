#!/bin/bash
# Test: container lifecycle — autoStart containers running, reserved not,
# undeclared containers get reconciled, launchd agents match expected pattern.
set -euo pipefail

AGENT_DIR="$HOME/Library/LaunchAgents"

echo "Checking autoStart containers are running..."
RUNNING=$(container ls --format json 2>/dev/null || echo "[]")

for name in nginx full-options nix-builder; do
  if echo "$RUNNING" | jq -e ".[] | select(.configuration.id == \"$name\")" > /dev/null 2>&1; then
    echo "  OK: $name is running"
  else
    echo "  FAIL: $name is NOT running"
    exit 1
  fi
done

echo "Checking reserved container is NOT running..."
if echo "$RUNNING" | jq -e '.[] | select(.configuration.id == "reserved")' > /dev/null 2>&1; then
  echo "  FAIL: reserved container should not be running"
  exit 1
fi
echo "  OK: reserved is not running"

echo "Checking launchd agents match expected pattern..."
for name in nginx full-options nix-builder; do
  PLIST="$AGENT_DIR/dev.apple.container.${name}.plist"
  if [ -f "$PLIST" ]; then
    echo "  OK: $PLIST exists"
  else
    echo "  FAIL: $PLIST not found"
    exit 1
  fi
done

echo "Testing reconciliation of undeclared containers..."
# Create a container that is NOT in config
container run --name undeclared-test --detach alpine:latest sleep 60 2>/dev/null || true
sleep 2

# Re-apply config — undeclared container should be removed
echo "  Re-applying config..."
sudo darwin-rebuild switch --flake "$(git rev-parse --show-toplevel)#ci-integration"

sleep 3

# Check the undeclared container was removed
if container ls --all --format json 2>/dev/null | jq -e '.[] | select(.configuration.id == "undeclared-test")' > /dev/null 2>&1; then
  echo "  FAIL: undeclared-test was not reconciled"
  container stop undeclared-test 2>/dev/null || true
  container rm undeclared-test 2>/dev/null || true
  exit 1
fi
echo "  OK: undeclared container was reconciled"
