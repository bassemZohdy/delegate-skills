#!/usr/bin/env bash
# tests/run-tests.sh — run all automation tests for delegate-skills
#
# Usage:
#   bash tests/run-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "════════════════════════════════════════"
echo "  delegate-skills test suite"
echo "════════════════════════════════════════"
echo ""
echo "━━━ Structure Tests ━━━"
source "$SCRIPT_DIR/test-structure.sh"
echo "  ─── $PASS passed, $FAIL failed"

echo ""
echo "════════════════════════════════════════"
echo "  Total: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
