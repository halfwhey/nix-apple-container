#!/bin/bash
# Integration test orchestrator.
# Runs each test script, tracks pass/fail, exits non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

run_test() {
  local name="$1"
  local script="$2"
  echo ""
  echo "=========================================="
  echo " TEST: $name"
  echo "=========================================="
  if bash "$script"; then
    echo "  PASS: $name"
    ((PASS++))
  else
    echo "  FAIL: $name"
    ((FAIL++))
    FAILED_TESTS+=("$name")
  fi
}

run_test "runtime"             "$SCRIPT_DIR/test-runtime.sh"
run_test "container-lifecycle" "$SCRIPT_DIR/test-container-lifecycle.sh"
run_test "image-loading"       "$SCRIPT_DIR/test-image-loading.sh"
run_test "linux-builder"       "$SCRIPT_DIR/test-linux-builder.sh"
run_test "teardown"            "$SCRIPT_DIR/test-teardown.sh"

echo ""
echo "=========================================="
echo " RESULTS: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
