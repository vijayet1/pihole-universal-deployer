#!/usr/bin/env bash
# ==============================================================================
# Automated Dual-Key Live Tailscale Integration Test
# ------------------------------------------------------------------------------
# 1. Programmatically creates an Ephemeral Auth Key via Tailscale API
# 2. Deploys & verifies Topology 3 (Auth Key Mode)
# 3. Tears down and deletes the Auth Key
# 4. Programmatically creates an OAuth Client Secret via Tailscale API
# 5. Deploys & verifies Topology 3 (OAuth Mode with auto-tagging)
# 6. Tears down and deletes the OAuth Client
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER_SCRIPT="$(cd "${SCRIPT_DIR}/.." && pwd)/pihole-deploy.sh"

TS_API_KEY="${TS_API_KEY:-}"
if [[ -z "${TS_API_KEY}" ]]; then
  echo "================================================================================"
  echo "  Tailscale Live Dual-Key Integration Test Harness"
  echo "================================================================================"
  echo "Error: TS_API_KEY environment variable is not set."
  echo ""
  echo "To run this automated test against your tailnet:"
  echo "  1. Generate an API token at: https://login.tailscale.com/admin/settings/keys"
  echo "  2. Run:"
  echo "       export TS_API_KEY=\"tskey-api-kXXXXX\""
  echo "       ./tests/test_tailscale_live.sh"
  echo "================================================================================"
  exit 1
fi

readonly TEST_DIR="/tmp/pihole-tailscale-live-$$"
mkdir -p "${TEST_DIR}"

cleanup() {
  echo ""
  echo "==> Cleaning up test instances and temporary directories..."
  "${DEPLOYER_SCRIPT}" --mode uninstall --dir "${TEST_DIR}/auth" >/dev/null 2>&1 || true
  "${DEPLOYER_SCRIPT}" --mode uninstall --dir "${TEST_DIR}/oauth" >/dev/null 2>&1 || true
  if command -v podman &>/dev/null; then
    podman unshare rm -rf "${TEST_DIR}" 2>/dev/null || rm -rf "${TEST_DIR}" 2>/dev/null || true
  else
    rm -rf "${TEST_DIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# TEST 1: Ephemeral Auth Key (tskey-auth-...)
# ------------------------------------------------------------------------------
echo "================================================================================"
echo " [TEST 1/2] Programmatic Ephemeral Auth Key Lifecycle & Verification"
echo "================================================================================"
echo "==> Minting Ephemeral Auth Key via Tailscale REST API..."
KEY_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.tailscale.com/v2/tailnet/-/keys" \
  -u "${TS_API_KEY}:" \
  -H "Content-Type: application/json" \
  -d '{
    "capabilities": {
      "devices": {
        "create": {
          "reusable": false,
          "ephemeral": true,
          "preauthorized": true,
          "tags": ["tag:pihole"]
        }
      }
    }
  }')

HTTP_CODE=$(echo "${KEY_RESP}" | tail -n 1)
BODY=$(echo "${KEY_RESP}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 && "${HTTP_CODE}" -ne 201 ]]; then
  echo "❌ Failed to create Auth Key (HTTP ${HTTP_CODE}): ${BODY}"
  exit 1
fi

AUTH_KEY=$(echo "${BODY}" | jq -r '.key // empty')
KEY_ID=$(echo "${BODY}" | jq -r '.id // empty')

if [[ -z "${AUTH_KEY}" || "${AUTH_KEY}" == "null" ]]; then
  echo "❌ Auth Key empty in response: ${BODY}"
  exit 1
fi
echo "  [✓] Ephemeral Auth Key generated: ${AUTH_KEY:0:18}... (ID: ${KEY_ID})"

echo "==> Deploying Topology 3 with Ephemeral Auth Key..."
"${DEPLOYER_SCRIPT}" --mode tailscale --dir "${TEST_DIR}/auth" --tailscale-key "${AUTH_KEY}" --password "TestSecretAuthKey2026!"

echo "==> Verifying Deployment Diagnostics..."
"${DEPLOYER_SCRIPT}" --healthcheck

echo "==> Tearing down Auth Key deployment..."
"${DEPLOYER_SCRIPT}" --mode uninstall --dir "${TEST_DIR}/auth"

echo "==> Deleting Auth Key from Tailscale API..."
curl -s -X DELETE "https://api.tailscale.com/v2/tailnet/-/keys/${KEY_ID}" -u "${TS_API_KEY}:" >/dev/null
echo "  [✓] Auth Key ${KEY_ID} revoked and deleted."

# ------------------------------------------------------------------------------
# TEST 2: OAuth Client Credentials (tskey-client-...)
# ------------------------------------------------------------------------------
echo ""
echo "================================================================================"
echo " [TEST 2/2] Programmatic OAuth Client Credentials Lifecycle & Auto-Tagging"
echo "================================================================================"
echo "==> Minting OAuth Client via Tailscale REST API..."
OAUTH_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.tailscale.com/v2/tailnet/-/oauth-clients" \
  -u "${TS_API_KEY}:" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pihole-automated-test-client",
    "description": "Temporary client for automated Pi-hole deployment testing",
    "scopes": ["devices:core"],
    "tags": ["tag:pihole"]
  }')

HTTP_CODE=$(echo "${OAUTH_RESP}" | tail -n 1)
BODY=$(echo "${OAUTH_RESP}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 && "${HTTP_CODE}" -ne 201 ]]; then
  echo "❌ Failed to create OAuth Client (HTTP ${HTTP_CODE}): ${BODY}"
  exit 1
fi

OAUTH_SECRET=$(echo "${BODY}" | jq -r '.secret // empty')
OAUTH_ID=$(echo "${BODY}" | jq -r '.id // empty')

if [[ -z "${OAUTH_SECRET}" || "${OAUTH_SECRET}" == "null" ]]; then
  echo "❌ OAuth Client Secret empty in response: ${BODY}"
  exit 1
fi
echo "  [✓] OAuth Client created: ID=${OAUTH_ID}"

echo "==> Deploying Topology 3 with OAuth Client Secret..."
"${DEPLOYER_SCRIPT}" --mode tailscale --dir "${TEST_DIR}/oauth" --tailscale-key "${OAUTH_SECRET}" --tailscale-tag "tag:pihole" --password "TestSecretOAuth2026!"

echo "==> Verifying Deployment Diagnostics..."
"${DEPLOYER_SCRIPT}" --healthcheck

echo "==> Tearing down OAuth deployment..."
"${DEPLOYER_SCRIPT}" --mode uninstall --dir "${TEST_DIR}/oauth"

echo "==> Deleting OAuth Client from Tailscale API..."
curl -s -X DELETE "https://api.tailscale.com/v2/tailnet/-/oauth-clients/${OAUTH_ID}" -u "${TS_API_KEY}:" >/dev/null
echo "  [✓] OAuth Client ${OAUTH_ID} permanently deleted."

echo ""
echo "================================================================================"
echo " 🎉 ALL TAILSCALE INTEGRATION TESTS PASSED (Both Auth Key & OAuth Verified)"
echo "================================================================================"
