#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for pihole-deploy.sh
# ==============================================================================
set -euo pipefail

readonly SCRIPT="/home/guptavi/Work/pihole-deploy.sh"
readonly TEST_DIR="/tmp/pihole-test-$$"

PASSED=0
FAILED=0

assert_contains() {
  local output="$1"
  local expected="$2"
  local test_name="$3"

  if [[ "${output}" == *"${expected}"* ]]; then
    echo "  [PASS] ${test_name}"
    ((PASSED++)) || true
  else
    echo "  [FAIL] ${test_name} (Expected '${expected}' in output)"
    ((FAILED++)) || true
  fi
}

cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

echo "==> Running Automated Tests for pihole-deploy.sh..."

# Test 1: CLI Help Output
out=$("${SCRIPT}" --help)
assert_contains "${out}" "Usage:" "Test 1: Help message displays usage"

# Test 2: Dry Run - Standalone Mode
out=$("${SCRIPT}" --mode standalone --domain "pi.example.com" --password "TestPass123" --dry-run)
assert_contains "${out}" "Topology 1: Standalone Host Installation" "Test 2: Dry-run standalone topology"

# Test 3: Dry Run - Container Mode
out=$("${SCRIPT}" --mode container --dir "${TEST_DIR}/c1" --password "TestPass123" --dry-run)
assert_contains "${out}" "Topology 2: Rootless Container Stack" "Test 3: Dry-run container topology"

# Test 4: Dry Run - Tailscale Sidecar Mode with Auth Key
out=$("${SCRIPT}" --mode tailscale --dir "${TEST_DIR}/ts1" --tailscale-key "tskey-auth-12345" --dry-run)
assert_contains "${out}" "Topology 3: Tailscale Sidecar" "Test 4: Dry-run Tailscale topology with Auth Key"

# Test 5: Dry Run - Tailscale Sidecar Mode with OAuth Key (Auto-Tag)
out=$("${SCRIPT}" --mode tailscale --dir "${TEST_DIR}/ts2" --tailscale-key "tskey-client-12345" --tailscale-tag "tag:pihole" --dry-run)
assert_contains "${out}" "Detected Tailscale OAuth Client Secret" "Test 5: Dry-run Tailscale OAuth key tag detection"

# Test 6: Healthcheck Execution
out=$("${SCRIPT}" --healthcheck)
assert_contains "${out}" "Healthcheck Summary" "Test 6: Healthcheck execution succeeds"

echo ""
echo "Test Results: ${PASSED} Passed, ${FAILED} Failed"
if (( FAILED > 0 )); then
  exit 1
fi
