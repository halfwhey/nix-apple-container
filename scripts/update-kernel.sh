#!/usr/bin/env bash
set -euo pipefail

# Update kata-containers kernel to the latest release

REPO="kata-containers/kata-containers"
KERNEL_FILE="pkgs/kernel.nix"
MODULE_FILE="module/default.nix"
CURRENT_VER=$(grep 'version ?' "$KERNEL_FILE" | sed 's/.*"\(.*\)".*/\1/')

LATEST=$(gh release view --repo "$REPO" --json tagName -q .tagName)

if [ "$CURRENT_VER" = "$LATEST" ]; then
  echo "kata-containers kernel is up to date ($CURRENT_VER)"
  exit 0
fi

echo "Updating kata-containers kernel: $CURRENT_VER → $LATEST"

URL="https://github.com/$REPO/releases/download/${LATEST}/kata-static-${LATEST}-arm64.tar.zst"
HASH=$(nix-prefetch-url --type sha256 "$URL" 2>/dev/null | xargs nix hash convert --hash-algo sha256 --to sri)

# Update pkgs/kernel.nix
sed -i '' "s|version ? \"${CURRENT_VER}\"|version ? \"${LATEST}\"|" "$KERNEL_FILE"
sed -i '' "s|hash ? \".*\"|hash ? \"${HASH}\"|" "$KERNEL_FILE"

# Find the vmlinux binary name in the new tarball
echo "Fetching tarball to detect vmlinux binary name..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
curl -sL "$URL" | zstd -d | tar -tf - | grep 'vmlinux-' | head -1 > "$TMPDIR/vmlinux_path"
VMLINUX_PATH=$(cat "$TMPDIR/vmlinux_path")

if [ -z "$VMLINUX_PATH" ]; then
  echo "WARNING: could not detect vmlinux binary path in tarball"
  echo "You must manually update the binaryPath default in $MODULE_FILE"
  exit 1
fi

echo "Detected vmlinux path: $VMLINUX_PATH"

# Update the default binaryPath in module/default.nix
CURRENT_BINARY=$(grep 'default = "opt/kata' "$MODULE_FILE" | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$CURRENT_BINARY" ] && [ "$CURRENT_BINARY" != "$VMLINUX_PATH" ]; then
  sed -i '' "s|${CURRENT_BINARY}|${VMLINUX_PATH}|" "$MODULE_FILE"
  echo "Updated $MODULE_FILE binaryPath: $VMLINUX_PATH"
fi

echo "Updated $KERNEL_FILE to $LATEST (hash: $HASH)"
