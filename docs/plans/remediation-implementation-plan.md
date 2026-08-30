# Pi-hole Universal Deployer Production Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remediate all security vulnerabilities, shell robustness bugs, IPv6 networking gaps, container logging limits, and incomplete uninstallation lifecycles identified in the Staff Platform review.

**Architecture:** Maintain a self-contained, high-reliability Bash automation script with hardened filesystem umasks, credential redaction, dual-stack sysctl port configuration, safe container engine invocations, and strict healthcheck exit codes.

**Tech Stack:** Bash 4+, Linux Kernel Sysctl, Systemd / systemd-resolved, Podman / Docker Compose, Caddy, Tailscale Serve.

**Spec:** [`docs/superpowers/specs/2026-08-30-pihole-architectural-remediation-design.md`](file:///home/guptavi/Work/docs/superpowers/specs/2026-08-30-pihole-architectural-remediation-design.md)

## Global Constraints

- Must run idempotently on Arch, Debian, Ubuntu, Fedora, and RHEL.
- Strict error checking: `set -euo pipefail`.
- Secrets must never be written with world-readable permissions (`umask 077`, `chmod 600`).
- No hardcoded cleartext default passwords; auto-generate 32-character tokens when omitted.
- Healthcheck must exit with non-zero code on failures.
- No third-party runtime dependencies beyond standard coreutils, bash, and container runtimes.

---

### Task 1: Core Shell Robustness, Variable Traps & Path Normalization

**Files:**
- Modify: [`pihole-deploy.sh:79-102`](file:///home/guptavi/Work/pihole-deploy.sh#L79-L102), [`pihole-deploy.sh:275-285`](file:///home/guptavi/Work/pihole-deploy.sh#L275-L285), [`pihole-deploy.sh:390-400`](file:///home/guptavi/Work/pihole-deploy.sh#L390-L400), [`pihole-deploy.sh:510-545`](file:///home/guptavi/Work/pihole-deploy.sh#L510-L545)
- Test: [`tests/test_deployer.sh`](file:///home/guptavi/Work/tests/test_deployer.sh)

**Interfaces:**
- Consumes: User inputs for `TARGET_DIR` and `ADMIN_PASSWORD`.
- Produces: Normalized `TARGET_DIR` with tilde expansion, safe container removal invocation, and corrected parameter syntax.

- [ ] **Step 1: Write the failing test for tilde path expansion & argument parsing**

Add to `tests/test_deployer.sh`:
```bash
# Test: Target Directory Tilde Expansion
out=$("${SCRIPT}" --mode container --dir "~/test-pihole-$$" --dry-run)
assert_contains "${out}" "${HOME}/test-pihole-$$" "Test: Tilde path expands to user home directory"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/test_deployer.sh`  
Expected: FAIL (because `~` is not currently expanded when passed in `--dir` or interactive prompts).

- [ ] **Step 3: Implement tilde expansion, empty engine guards, and password syntax fix in `pihole-deploy.sh`**

1. In `parse_args()` and `run_interactive_wizard()`:
```bash
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
```

2. In `detect_environment()`:
```bash
if command -v podman &>/dev/null; then
  CONTAINER_ENGINE="podman"
  if podman compose version &>/dev/null; then
    COMPOSE_CMD="podman compose"
  elif command -v podman-compose &>/dev/null; then
    COMPOSE_CMD="podman-compose"
  elif command -v uvx &>/dev/null; then
    COMPOSE_CMD="uvx podman-compose"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  fi
```

3. In `deploy_container()` and `deploy_tailscale_sidecar()`:
```bash
if [[ -n "${CONTAINER_ENGINE}" ]]; then
  "${CONTAINER_ENGINE}" rm -f pihole tailscale-pihole 2>/dev/null || true
fi
```

4. Fix password assignment in `run_interactive_wizard()`:
```bash
ADMIN_PASSWORD="${input_pass:-}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_deployer.sh`  
Expected: PASS

- [ ] **Step 5: Sync changes to `pihole-universal-deployer/` and verify**

```bash
cp pihole-deploy.sh pihole-universal-deployer/pihole-deploy.sh
```

---

### Task 2: Security Subsystem & Secret Filesystem Permissions

**Files:**
- Modify: [`pihole-deploy.sh:230-245`](file:///home/guptavi/Work/pihole-deploy.sh#L230-L245), [`pihole-deploy.sh:305-320`](file:///home/guptavi/Work/pihole-deploy.sh#L305-L320), [`pihole-deploy.sh:585-640`](file:///home/guptavi/Work/pihole-deploy.sh#L585-L640)
- Test: [`tests/test_deployer.sh`](file:///home/guptavi/Work/tests/test_deployer.sh)

**Interfaces:**
- Consumes: Environment variables `PIHOLE_PASSWORD`, `TS_AUTHKEY`, `--password-stdin` option.
- Produces: Cryptographically secure passwords if unset, `.env` file generated with mode `0600`.

- [ ] **Step 1: Write failing test for file permissions and secure password auto-generation**

Add to `tests/test_deployer.sh`:
```bash
# Test: Secure .env Permissions
"${SCRIPT}" --mode container --dir "${TEST_DIR}/sec-test" --dry-run
perms=$(stat -c "%a" "${TEST_DIR}/sec-test/.env" 2>/dev/null || stat -f "%Lp" "${TEST_DIR}/sec-test/.env" 2>/dev/null || echo "unknown")
assert_contains "${perms}" "600" "Test: .env file created with secure 0600 permissions"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/test_deployer.sh`  
Expected: FAIL (permissions currently default to `644`).

- [ ] **Step 3: Implement `generate_secure_password()`, environment variable ingestion, and `umask 077` in `pihole-deploy.sh`**

```bash
generate_secure_password() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 16
  else
    tr -dc 'A-Za-z0-9!#%_+=' < /dev/urandom | head -c 24 || echo "PiHole$(date +%s)Sec!"
  fi
}
```

In `parse_args()`:
```bash
ADMIN_PASSWORD="${PIHOLE_PASSWORD:-${ADMIN_PASSWORD}}"
TAILSCALE_KEY="${TS_AUTHKEY:-${TAILSCALE_KEY}}"

case "$1" in
  --password-stdin)
    read -r ADMIN_PASSWORD
    shift
    ;;
```

Before writing `.env` in `deploy_container()` and `deploy_tailscale_sidecar()`:
```bash
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  ADMIN_PASSWORD=$(generate_secure_password)
  log_info "Auto-generated secure Pi-hole admin password: ${ADMIN_PASSWORD}"
fi

local env_file="${TARGET_DIR}/.env"
touch "${env_file}"
chmod 600 "${env_file}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_deployer.sh`  
Expected: PASS

- [ ] **Step 5: Sync changes to `pihole-universal-deployer/` and verify**

```bash
cp pihole-deploy.sh pihole-universal-deployer/pihole-deploy.sh
```

---

### Task 3: Dual-Stack IPv4/IPv6 Sysctl & Compose Schema Modernization

**Files:**
- Modify: [`pihole-deploy.sh:105-130`](file:///home/guptavi/Work/pihole-deploy.sh#L105-L130), [`pihole-deploy.sh:245-275`](file:///home/guptavi/Work/pihole-deploy.sh#L245-L275), [`pihole-deploy.sh:340-385`](file:///home/guptavi/Work/pihole-deploy.sh#L340-L385)
- Test: [`tests/test_deployer.sh`](file:///home/guptavi/Work/tests/test_deployer.sh)

**Interfaces:**
- Consumes: System `/proc/sys/net/ipv6/ip_unprivileged_port_start`.
- Produces: Dual-stack sysctl drop-in file and modern `docker-compose.yml` with log rotation limits.

- [ ] **Step 1: Write failing test verifying IPv6 sysctl and compose logging options**

Add to `tests/test_deployer.sh`:
```bash
# Test: Compose Log Rotation & Spec Modernization
"${SCRIPT}" --mode container --dir "${TEST_DIR}/compose-test" --dry-run
compose_content=$(cat "${TEST_DIR}/compose-test/docker-compose.yml")
assert_contains "${compose_content}" "max-size: \"20m\"" "Test: Compose includes log rotation limits"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/test_deployer.sh`  
Expected: FAIL (missing log rotation limits).

- [ ] **Step 3: Implement dual-stack sysctl and update `docker-compose.yml`**

1. In `configure_system_dns_and_ports()`:
```bash
local sysctl_conf="/etc/sysctl.d/50-pihole-unprivileged-ports.conf"
local sysctl_content="net.ipv4.ip_unprivileged_port_start=53"
if [[ -f /proc/sys/net/ipv6/ip_unprivileged_port_start ]]; then
  sysctl_content+=$'\nnet.ipv6.ip_unprivileged_port_start=53'
fi
```

2. In generated `docker-compose.yml` for both container and tailscale modes, remove `version: "3"` and add:
```yaml
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
```

3. In `deploy_tailscale_sidecar()`:
```bash
if [[ ! -c /dev/net/tun ]]; then
  log_warn "/dev/net/tun not found or inaccessible. Tailscale will require userspace networking."
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_deployer.sh`  
Expected: PASS

- [ ] **Step 5: Sync changes to `pihole-universal-deployer/` and verify**

```bash
cp pihole-deploy.sh pihole-universal-deployer/pihole-deploy.sh
```

---

### Task 4: Complete System Teardown & Rollback in Uninstaller

**Files:**
- Modify: [`pihole-deploy.sh:404-428`](file:///home/guptavi/Work/pihole-deploy.sh#L404-L428), [`pihole-deploy.sh:585-640`](file:///home/guptavi/Work/pihole-deploy.sh#L585-L640)
- Test: [`tests/test_deployer.sh`](file:///home/guptavi/Work/tests/test_deployer.sh)

**Interfaces:**
- Consumes: `--purge-system` flag or interactive confirmation.
- Produces: Clean system state restoring `/etc/sysctl.d`, `/etc/systemd/resolved.conf.d`, and Caddy service.

- [ ] **Step 1: Write test for uninstaller purge output**

Add to `tests/test_deployer.sh`:
```bash
# Test: Uninstaller with purge option
out=$("${SCRIPT}" --mode uninstall --dir "${TEST_DIR}/uninstall-test" --purge-system --dry-run)
assert_contains "${out}" "Restoring system DNS and sysctl settings" "Test: Uninstaller purges system configurations"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/test_deployer.sh`  
Expected: FAIL

- [ ] **Step 3: Implement system rollback in `run_uninstall()`**

```bash
PURGE_SYSTEM="false"
# In parse_args: --purge-system) PURGE_SYSTEM="true"; shift ;;

run_uninstall() {
  log_step "Uninstalling and Removing Pi-hole Stack"
  
  if [[ -n "${CONTAINER_ENGINE}" ]]; then
    "${CONTAINER_ENGINE}" rm -f pihole tailscale-pihole 2>/dev/null || true
  fi

  if command -v pihole &>/dev/null; then
    log_info "Calling host pihole uninstall..."
    run_privileged pihole uninstall || true
  fi

  if [[ "${PURGE_SYSTEM}" == "true" ]]; then
    log_step "Restoring system DNS and sysctl settings..."
    local sysctl_conf="/etc/sysctl.d/50-pihole-unprivileged-ports.conf"
    if [[ -f "${sysctl_conf}" ]]; then
      run_privileged rm -f "${sysctl_conf}"
      run_privileged sysctl --system >/dev/null 2>&1 || true
    fi

    local resolved_dir="/etc/systemd/resolved.conf.d"
    run_privileged rm -f "${resolved_dir}/no-stub.conf"
    if [[ -f "${resolved_dir}/20-docker-dns.conf.disabled" ]]; then
      run_privileged mv "${resolved_dir}/20-docker-dns.conf.disabled" "${resolved_dir}/20-docker-dns.conf"
    fi
    run_privileged systemctl restart systemd-resolved 2>/dev/null || true
    
    if systemctl is-active --quiet caddy 2>/dev/null; then
      run_privileged systemctl stop caddy || true
      run_privileged systemctl disable caddy || true
    fi
  fi

  if [[ -d "${TARGET_DIR}" ]]; then
    rm -rf "${TARGET_DIR}"
  fi
  log_success "Pi-hole deployment has been uninstalled."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/test_deployer.sh`  
Expected: PASS

- [ ] **Step 5: Sync changes to `pihole-universal-deployer/` and verify**

```bash
cp pihole-deploy.sh pihole-universal-deployer/pihole-deploy.sh
```

---

### Task 5: Healthcheck Return Code Fix & Comprehensive Test Suite

**Files:**
- Modify: [`pihole-deploy.sh:433-485`](file:///home/guptavi/Work/pihole-deploy.sh#L433-L485)
- Modify: [`tests/test_deployer.sh`](file:///home/guptavi/Work/tests/test_deployer.sh)

**Interfaces:**
- Consumes: Healthcheck status probe results.
- Produces: Non-zero exit code on failures; comprehensive automated test suite.

- [ ] **Step 1: Write test asserting non-zero healthcheck exit code when inactive**

Add to `tests/test_deployer.sh`:
```bash
# Test: Healthcheck non-zero exit code when no service is running
set +e
"${SCRIPT}" --healthcheck >/dev/null 2>&1
hc_exit=$?
set -e
if (( hc_exit != 0 )); then
  echo "  [PASS] Test: Healthcheck exits with non-zero on failure"
  ((PASSED++)) || true
else
  echo "  [FAIL] Test: Healthcheck returned 0 on failed check"
  ((FAILED++)) || true
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/test_deployer.sh`  
Expected: FAIL (because `run_healthcheck` currently returns 0 unconditionally).

- [ ] **Step 3: Fix `run_healthcheck()` in `pihole-deploy.sh`**

```bash
run_healthcheck() {
  ...
  echo -e "\n${BOLD}Healthcheck Summary: ${GREEN}${passed} Passed${NC}, ${RED}${failed} Failed${NC}"
  if (( failed > 0 )); then
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Run the full test suite to verify all tests pass**

Run: `./tests/test_deployer.sh`  
Expected: PASS (all tests pass, 0 failed).

- [ ] **Step 5: Commit changes to repository**

```bash
cd /home/guptavi/Work/pihole-universal-deployer
git add .
git commit -m "feat(hardening): remediate security, container lifecycle, and rollback architecture"
```
