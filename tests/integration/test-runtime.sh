#!/bin/bash
# Test: runtime is started and kernel is installed correctly.
set -euo pipefail

echo "Checking container runtime status..."
container system status

APP_SUPPORT="$HOME/Library/Application Support/com.apple.container"
KERNEL_LINK="$APP_SUPPORT/kernels/default.kernel-arm64"

echo "Checking kernel symlink..."
if [ ! -L "$KERNEL_LINK" ]; then
  echo "FAIL: $KERNEL_LINK is not a symlink"
  exit 1
fi

TARGET=$(readlink "$KERNEL_LINK")
if [[ "$TARGET" != /nix/store/* ]]; then
  echo "FAIL: kernel symlink does not point to Nix store: $TARGET"
  exit 1
fi

if [ ! -f "$TARGET" ]; then
  echo "FAIL: kernel symlink target does not exist: $TARGET"
  exit 1
fi

echo "Runtime is running, kernel symlink points to: $TARGET"
