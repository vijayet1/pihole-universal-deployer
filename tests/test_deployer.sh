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

# Test 7: Target Directory Tilde Expansion
out=$("${SCRIPT}" --mode container --dir "~/test-pihole-$$" --dry-run)
assert_contains "${out}" "${HOME}/test-pihole-$$" "Test 7: Tilde path expands to user home directory"

# Test 8: Secure .env Permissions
"${SCRIPT}" --mode container --dir "${TEST_DIR}/sec-test" --dry-run
perms=$(stat -c "%a" "${TEST_DIR}/sec-test/.env" 2>/dev/null || stat -f "%Lp" "${TEST_DIR}/sec-test/.env" 2>/dev/null || echo "unknown")
assert_contains "${perms}" "600" "Test 8: .env file created with secure 0600 permissions"

# Test 9: Secure Password Auto-generation when unset
out=$("${SCRIPT}" --mode container --dir "${TEST_DIR}/sec-pass" --dry-run)
assert_contains "${out}" "Auto-generated secure Pi-hole admin password" "Test 9: Auto-generates secure password when none provided"
env_pass=$(grep "^WEBPASSWORD=" "${TEST_DIR}/sec-pass/.env" | cut -d'=' -f2)
if [[ -n "${env_pass}" && "${env_pass}" != "AdminPass123!" ]]; then
  echo "  [PASS] Test 10: WEBPASSWORD is set to non-default generated secret"
  ((PASSED++)) || true
else
  echo "  [FAIL] Test 10: WEBPASSWORD contains hardcoded default: '${env_pass}'"
  ((FAILED++)) || true
fi

# Test 11: Environment variable ingestion (PIHOLE_PASSWORD)
PIHOLE_PASSWORD="EnvSecretPassword987!" "${SCRIPT}" --mode container --dir "${TEST_DIR}/sec-env" --dry-run
env_val=$(grep "^WEBPASSWORD=" "${TEST_DIR}/sec-env/.env" | cut -d'=' -f2)
assert_contains "${env_val}" "EnvSecretPassword987!" "Test 11: Ingests PIHOLE_PASSWORD environment variable"

# Test 12: Environment variable ingestion (TS_AUTHKEY)
TS_AUTHKEY="tskey-auth-env-test" "${SCRIPT}" --mode tailscale --dir "${TEST_DIR}/sec-ts" --dry-run
ts_val=$(grep "^TS_AUTHKEY=" "${TEST_DIR}/sec-ts/.env" | cut -d'=' -f2)
assert_contains "${ts_val}" "tskey-auth-env-test" "Test 12: Ingests TS_AUTHKEY environment variable"

# Test 13: Password via Stdin (--password-stdin)
echo "StdinPassword123!" | "${SCRIPT}" --mode container --dir "${TEST_DIR}/sec-stdin" --password-stdin --dry-run
stdin_val=$(grep "^WEBPASSWORD=" "${TEST_DIR}/sec-stdin/.env" | cut -d'=' -f2)
assert_contains "${stdin_val}" "StdinPassword123!" "Test 13: Ingests password from --password-stdin"

echo ""
echo "Test Results: ${PASSED} Passed, ${FAILED} Failed"
if (( FAILED > 0 )); then
  exit 1
fi

