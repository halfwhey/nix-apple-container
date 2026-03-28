#!/bin/bash
# Test: disabling the module tears down all state correctly.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AGENT_DIR="$HOME/Library/LaunchAgents"

echo "Switching to disabled config..."
sudo darwin-rebuild switch --flake "$REPO_ROOT#ci-disabled"
sleep 3

echo "Checking runtime is stopped..."
if container system status 2>/dev/null; then
  echo "  FAIL: runtime is still running"
  exit 1
fi
echo "  OK: runtime is stopped"

echo "Checking no module-owned launchd agents remain..."
STALE_AGENTS=$(ls "$AGENT_DIR"/dev.apple.container.*.plist 2>/dev/null || true)
if [ -n "$STALE_AGENTS" ]; then
  echo "  FAIL: stale agents found:"
  echo "  $STALE_AGENTS"
  exit 1
fi
echo "  OK: no stale agents"

echo "Checking builder SSH key is removed..."
if [ -f /etc/nix/builder_ed25519 ]; then
  echo "  FAIL: /etc/nix/builder_ed25519 still exists"
  exit 1
fi
echo "  OK: builder SSH key removed"

echo "Checking defaults are deleted..."
if defaults read com.apple.container 2>/dev/null; then
  echo "  FAIL: com.apple.container defaults still exist"
  exit 1
fi
echo "  OK: defaults deleted"

echo "Teardown test passed"

# Re-enable for any subsequent tests
echo "Re-applying integration config..."
sudo darwin-rebuild switch --flake "$REPO_ROOT#ci-integration"
