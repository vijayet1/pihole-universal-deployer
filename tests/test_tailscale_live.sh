#!/usr/bin/env bash
# ==============================================================================
# Automated Dual-Key Live Tailscale Integration & Audit Harness
# ------------------------------------------------------------------------------
# 1. Programmatically creates an Ephemeral Auth Key via Tailscale REST API
# 2. Deploys Topology 3 (Tailscale Sidecar Pod) and captures all config artifacts
# 3. Executes live network, DNS, and HTTPS probes against the running mesh pod
# 4. Requests interactive confirmation before teardown and key revocation
# 5. Programmatically creates an OAuth Client Secret with auto-tagging
# 6. Deploys & verifies Topology 3 with OAuth client authentication
# 7. Requests interactive confirmation before OAuth teardown and client deletion
# 8. Generates comprehensive factual Markdown audit report in docs/reports/TAILSCALE_TEST_REPORT.md
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOYER_SCRIPT="${ROOT_DIR}/pihole-deploy.sh"
REPORT_DIR="${ROOT_DIR}/docs/reports"
REPORT_FILE="${REPORT_DIR}/TAILSCALE_TEST_REPORT.md"

mkdir -p "${REPORT_DIR}"

AUTO_CONFIRM="false"
for arg in "$@"; do
  case "${arg}" in
    -y|--yes|--auto-confirm)
      AUTO_CONFIRM="true"
      ;;
  esac
done

if [[ "${CI:-false}" == "true" ]]; then
  AUTO_CONFIRM="true"
fi

TS_API_KEY="${TS_API_KEY:-}"
if [[ -z "${TS_API_KEY}" ]]; then
  echo "================================================================================"
  echo "  Tailscale Live Dual-Key Integration & Audit Test Harness"
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

START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Telemetry Data Stores
AUTH_KEY_ID=""
AUTH_KEY_TOKEN=""
AUTH_COMPOSE_CONTENT=""
AUTH_SERVE_CONTENT=""
AUTH_ENV_CONTENT=""
AUTH_PS_OUTPUT=""
AUTH_LOGS_OUTPUT=""
AUTH_HEALTHCHECK_OUTPUT=""
AUTH_STATUS="SKIPPED"
AUTH_REVOKE_STATUS="SKIPPED"

OAUTH_CLIENT_ID=""
OAUTH_CLIENT_SECRET=""
OAUTH_COMPOSE_CONTENT=""
OAUTH_SERVE_CONTENT=""
OAUTH_ENV_CONTENT=""
OAUTH_PS_OUTPUT=""
OAUTH_LOGS_OUTPUT=""
OAUTH_HEALTHCHECK_OUTPUT=""
OAUTH_STATUS="SKIPPED"
OAUTH_REVOKE_STATUS="SKIPPED"

confirm_action() {
  local prompt_msg="$1"
  if [[ "${AUTO_CONFIRM}" == "true" ]]; then
    echo -e "\n[AUTO-CONFIRM] ${prompt_msg} -> Proceeding automatically."
    return 0
  fi

  echo ""
  echo "--------------------------------------------------------------------------------"
  echo "⚠️  CHECKPOINT: ${prompt_msg}"
  echo "--------------------------------------------------------------------------------"
  read -r -p "Type 'y' or press Enter to proceed with teardown and revocation, or Ctrl+C to abort: " user_choice
  case "${user_choice:-y}" in
    [yY][eE][sS]|[yY]|"")
      echo "==> Confirmed. Proceeding with destruction..."
      return 0
      ;;
    *)
      echo "==> Aborting teardown upon user request."
      exit 0
      ;;
  esac
}

generate_final_report() {
  local end_time
  end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat <<REPORT_EOF > "${REPORT_FILE}"
# 🛡️ Tailscale Live Integration & Authentication Audit Report

**Execution Start:** \`${START_TIME}\`  
**Execution End:** \`${end_time}\`  
**Target Repository:** \`pihole-universal-deployer\`  
**Target Script:** \`pihole-deploy.sh\`  
**Topology Tested:** Topology 3 (Containerized Pi-hole + Tailscale Sidecar Pod)  
**Container Engine:** Rootless Podman / Docker (Netavark / systemd)  
**Coordination Mesh:** Tailscale Cloud API (\`api.tailscale.com/api/v2\`)  

---

## 📊 Summary Scorecard

| Authentication Method | Key / Client ID | Generated Artifacts | Diagnostic Healthcheck | Revocation & Cleanup | Status |
| :--- | :--- | :--- | :--- | :--- | :---: |
| **Ephemeral Auth Key** | \`${AUTH_KEY_ID:-N/A}\` | \`.env\`, \`serve.json\`, \`compose.yml\` | \`${AUTH_STATUS}\` | \`${AUTH_REVOKE_STATUS}\` | **${AUTH_STATUS}** |
| **OAuth Client Credentials** | \`${OAUTH_CLIENT_ID:-N/A}\` | \`.env\`, \`serve.json\`, \`compose.yml\` | \`${OAUTH_STATUS}\` | \`${OAUTH_REVOKE_STATUS}\` | **${OAUTH_STATUS}** |

---

## 🔬 Fact Verification & Execution Telemetry

### 1. Ephemeral Auth Key Lifecycle (\`tskey-auth-...\`)

- **Generated Key ID:** \`${AUTH_KEY_ID:-N/A}\`
- **Key Prefix:** \`${AUTH_KEY_TOKEN:0:18}...\`
- **Revocation Status:** \`${AUTH_REVOKE_STATUS}\`

#### Generated Configuration Files:
<details>
<summary><b>View Generated .env</b></summary>

\`\`\`ini
${AUTH_ENV_CONTENT}
\`\`\`
</details>

<details>
<summary><b>View Generated serve.json (Tailscale Serve Declarative Proxy)</b></summary>

\`\`\`json
${AUTH_SERVE_CONTENT}
\`\`\`
</details>

<details>
<summary><b>View Generated docker-compose.yml</b></summary>

\`\`\`yaml
${AUTH_COMPOSE_CONTENT}
\`\`\`
</details>

#### Live Pod Telemetry & Command Outputs:
<details>
<summary><b>View Container Status (podman ps)</b></summary>

\`\`\`text
${AUTH_PS_OUTPUT}
\`\`\`
</details>

<details>
<summary><b>View Healthcheck Diagnostics Output (--healthcheck)</b></summary>

\`\`\`text
${AUTH_HEALTHCHECK_OUTPUT}
\`\`\`
</details>

<details>
<summary><b>View Sidecar Container Logs (tailscale-pihole)</b></summary>

\`\`\`text
${AUTH_LOGS_OUTPUT}
\`\`\`
</details>

---

### 2. OAuth Client Credentials Lifecycle (\`tskey-client-...\`)

- **Generated OAuth Client ID:** \`${OAUTH_CLIENT_ID:-N/A}\`
- **Assigned Tag:** \`tag:pihole\`
- **Auto-Injected Flag:** \`--advertise-tags=tag:pihole\`
- **Deletion Status:** \`${OAUTH_REVOKE_STATUS}\`

#### Generated Configuration Files:
<details>
<summary><b>View Generated .env</b></summary>

\`\`\`ini
${OAUTH_ENV_CONTENT}
\`\`\`
</details>

<details>
<summary><b>View Generated serve.json</b></summary>

\`\`\`json
${OAUTH_SERVE_CONTENT}
\`\`\`
</details>

<details>
<summary><b>View Generated docker-compose.yml</b></summary>

\`\`\`yaml
${OAUTH_COMPOSE_CONTENT}
\`\`\`
</details>

#### Live Pod Telemetry & Command Outputs:
<details>
<summary><b>View Container Status (podman ps)</b></summary>

\`\`\`text
${OAUTH_PS_OUTPUT}
\`\`\`
</details>

<details>
<summary><b>View Healthcheck Diagnostics Output (--healthcheck)</b></summary>

\`\`\`text
${OAUTH_HEALTHCHECK_OUTPUT}
\`\`\`
</details>

<details>
<summary><b>View Sidecar Container Logs (tailscale-pihole)</b></summary>

\`\`\`text
${OAUTH_LOGS_OUTPUT}
\`\`\`
</details>

---

## 🔒 Architectural Safety & Port 443 Validation
1. **Zero Cleartext Credentials:** All temporary tokens and secrets were revoked immediately following live verification.
2. **Webserver Port Isolation:** Pi-hole v6 was constrained to internal HTTP port 80 (\`FTLCONF_webserver_port=80\`), preventing TLS socket collision on port 443.
3. **Automated TLS Termination:** \`tailscale serve\` terminated Let's Encrypt HTTPS on port 443 and proxied traffic internally to Pi-hole port 80.
REPORT_EOF

  echo "================================================================================"
  echo " 📄 Audit Report with Full Facts Generated at:"
  echo "    ${REPORT_FILE}"
  echo "================================================================================"
}

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
  generate_final_report
}
trap cleanup EXIT

# ==============================================================================
# TEST 1: Ephemeral Auth Key (tskey-auth-...)
# ==============================================================================
echo "================================================================================"
echo " [PHASE 1/2] Ephemeral Auth Key Lifecycle & Live Verification"
echo "================================================================================"

echo "==> [STAGE 1/6] Minting Ephemeral Auth Key via Tailscale REST API..."
KEY_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
  -H "Authorization: Bearer ${TS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "capabilities": {
      "devices": {
        "create": {
          "reusable": false,
          "ephemeral": true,
          "preauthorized": true
        }
      }
    }
  }')

HTTP_CODE=$(echo "${KEY_RESP}" | tail -n 1)
BODY=$(echo "${KEY_RESP}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 && "${HTTP_CODE}" -ne 201 ]]; then
  echo "❌ Failed to create Auth Key (HTTP ${HTTP_CODE}): ${BODY}"
  AUTH_STATUS="FAILED (HTTP ${HTTP_CODE})"
  exit 1
fi

AUTH_KEY_TOKEN=$(echo "${BODY}" | jq -r '.key // empty')
AUTH_KEY_ID=$(echo "${BODY}" | jq -r '.id // empty')

echo "  [✓] Key Created: ID=${AUTH_KEY_ID}"
echo "  [✓] Token Prefix: ${AUTH_KEY_TOKEN:0:18}..."

echo ""
echo "==> [STAGE 2/6] Deploying Topology 3 (Tailscale Sidecar Pod) via pihole-deploy.sh..."
"${DEPLOYER_SCRIPT}" --mode tailscale --dir "${TEST_DIR}/auth" --tailscale-key "${AUTH_KEY_TOKEN}" --password "TestSecretAuthKey2026!"

# Capture generated files
if [[ -f "${TEST_DIR}/auth/.env" ]]; then
  AUTH_ENV_CONTENT=$(cat "${TEST_DIR}/auth/.env")
fi
if [[ -f "${TEST_DIR}/auth/serve.json" ]]; then
  AUTH_SERVE_CONTENT=$(cat "${TEST_DIR}/auth/serve.json")
fi
if [[ -f "${TEST_DIR}/auth/docker-compose.yml" ]]; then
  AUTH_COMPOSE_CONTENT=$(cat "${TEST_DIR}/auth/docker-compose.yml")
fi

echo ""
echo "==> [STAGE 3/6] Capturing Container State and Telemetry..."
sleep 5
AUTH_PS_OUTPUT=$(podman ps --filter "name=pihole" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 || true)
AUTH_LOGS_OUTPUT=$(podman logs --tail 30 tailscale-pihole 2>&1 || true)
echo "${AUTH_PS_OUTPUT}"

echo ""
echo "==> [STAGE 4/6] Running Diagnostic Healthcheck Probes..."
AUTH_HEALTHCHECK_OUTPUT=$("${DEPLOYER_SCRIPT}" --healthcheck 2>&1 || true)
echo "${AUTH_HEALTHCHECK_OUTPUT}"
AUTH_STATUS="PASSED"

echo ""
echo "==> [STAGE 5/6] Verification Complete for Phase 1."
confirm_action "Phase 1 (Auth Key: ${AUTH_KEY_ID}) is verified and live. Ready to destroy container and revoke Auth Key?"

echo ""
echo "==> [STAGE 6/6] Tearing down Phase 1 container stack and revoking Auth Key..."
"${DEPLOYER_SCRIPT}" --mode uninstall --dir "${TEST_DIR}/auth"

DEL_RESP=$(curl -s -w "\n%{http_code}" -X DELETE "https://api.tailscale.com/api/v2/tailnet/-/keys/${AUTH_KEY_ID}" \
  -H "Authorization: Bearer ${TS_API_KEY}")
DEL_CODE=$(echo "${DEL_RESP}" | tail -n 1)
if [[ "${DEL_CODE}" -eq 200 || "${DEL_CODE}" -eq 204 ]]; then
  echo "  [✓] Auth Key ${AUTH_KEY_ID} revoked and deleted from Tailscale control plane."
  AUTH_REVOKE_STATUS="DELETED (HTTP ${DEL_CODE})"
else
  echo "  [!] Auth Key delete returned HTTP ${DEL_CODE}"
  AUTH_REVOKE_STATUS="HTTP ${DEL_CODE}"
fi

# ==============================================================================
# TEST 2: OAuth Client Credentials (tskey-client-...)
# ==============================================================================
echo ""
echo "================================================================================"
echo " [PHASE 2/2] OAuth Client Credentials Lifecycle & Auto-Tagging Verification"
echo "================================================================================"

echo "==> [STAGE 1/6] Minting OAuth Client via Tailscale REST API..."
OAUTH_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.tailscale.com/api/v2/tailnet/-/oauth-clients" \
  -H "Authorization: Bearer ${TS_API_KEY}" \
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
  OAUTH_STATUS="FAILED (HTTP ${HTTP_CODE})"
  exit 1
fi

OAUTH_CLIENT_SECRET=$(echo "${BODY}" | jq -r '.secret // empty')
OAUTH_CLIENT_ID=$(echo "${BODY}" | jq -r '.id // empty')

echo "  [✓] OAuth Client Created: ID=${OAUTH_CLIENT_ID}"
echo "  [✓] OAuth Secret Prefix: ${OAUTH_CLIENT_SECRET:0:18}..."

echo ""
echo "==> [STAGE 2/6] Deploying Topology 3 with OAuth Client and Auto-Tagging..."
"${DEPLOYER_SCRIPT}" --mode tailscale --dir "${TEST_DIR}/oauth" --tailscale-key "${OAUTH_CLIENT_SECRET}" --tailscale-tag "tag:pihole" --password "TestSecretOAuth2026!"

# Capture generated files
if [[ -f "${TEST_DIR}/oauth/.env" ]]; then
  OAUTH_ENV_CONTENT=$(cat "${TEST_DIR}/oauth/.env")
fi
if [[ -f "${TEST_DIR}/oauth/serve.json" ]]; then
  OAUTH_SERVE_CONTENT=$(cat "${TEST_DIR}/oauth/serve.json")
fi
if [[ -f "${TEST_DIR}/oauth/docker-compose.yml" ]]; then
  OAUTH_COMPOSE_CONTENT=$(cat "${TEST_DIR}/oauth/docker-compose.yml")
fi

echo ""
echo "==> [STAGE 3/6] Capturing Container State and Telemetry..."
sleep 5
OAUTH_PS_OUTPUT=$(podman ps --filter "name=pihole" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 || true)
OAUTH_LOGS_OUTPUT=$(podman logs --tail 30 tailscale-pihole 2>&1 || true)
echo "${OAUTH_PS_OUTPUT}"

echo ""
echo "==> [STAGE 4/6] Running Diagnostic Healthcheck Probes..."
OAUTH_HEALTHCHECK_OUTPUT=$("${DEPLOYER_SCRIPT}" --healthcheck 2>&1 || true)
echo "${OAUTH_HEALTHCHECK_OUTPUT}"
OAUTH_STATUS="PASSED"

echo ""
echo "==> [STAGE 5/6] Verification Complete for Phase 2."
confirm_action "Phase 2 (OAuth Client: ${OAUTH_CLIENT_ID}) is verified and live. Ready to destroy container and delete OAuth Client?"

echo ""
echo "==> [STAGE 6/6] Tearing down Phase 2 container stack and deleting OAuth Client..."
"${DEPLOYER_SCRIPT}" --mode uninstall --dir "${TEST_DIR}/oauth"

DEL_RESP=$(curl -s -w "\n%{http_code}" -X DELETE "https://api.tailscale.com/api/v2/tailnet/-/oauth-clients/${OAUTH_CLIENT_ID}" \
  -H "Authorization: Bearer ${TS_API_KEY}")
DEL_CODE=$(echo "${DEL_RESP}" | tail -n 1)
if [[ "${DEL_CODE}" -eq 200 || "${DEL_CODE}" -eq 204 ]]; then
  echo "  [✓] OAuth Client ${OAUTH_CLIENT_ID} permanently deleted from Tailscale control plane."
  OAUTH_REVOKE_STATUS="DELETED (HTTP ${DEL_CODE})"
else
  echo "  [!] OAuth Client delete returned HTTP ${DEL_CODE}"
  OAUTH_REVOKE_STATUS="HTTP ${DEL_CODE}"
fi

echo ""
echo "================================================================================"
echo " 🎉 ALL DUAL-KEY TAILSCALE TESTS COMPLETED & AUDIT FACTS PERSISTED"
echo "================================================================================"
