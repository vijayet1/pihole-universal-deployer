# Architecture & Design Specification: Pi-hole Universal Deployer Production Hardening

- **Document ID:** `SPEC-2026-08-30-PIHOLE-REMEDIATION`
- **Author:** System Architect & Staff Platform Engineer
- **Date:** 2026-08-30
- **Status:** Approved / In-Planning
- **Target File:** `pihole-deploy.sh`
- **Test File:** `tests/test_deployer.sh`

---

## 1. Executive Summary & Goals

This specification details the production hardening and architectural remediation for the Universal Pi-hole Deployer (`pihole-deploy.sh`). The goal is to address all critical vulnerabilities, edge-case bugs, container lifecycle shortcomings, and teardown state management identified in the Staff Platform Engineer review.

---

## 2. Architectural Subsystems & Specifications

### 2.1 Security & Secrets Management Subsystem

1. **Process Table Argument Redaction:**
   - Support `PIHOLE_PASSWORD` and `TAILSCALE_AUTHKEY` / `TAILSCALE_KEY` environment variables.
   - Support `--password-stdin` for non-interactive automation (e.g. `cat secret.txt | ./pihole-deploy.sh --password-stdin`).
   - If `--password` or `--tailscale-key` is passed on CLI, accept it with an informative security notice encouraging environment variables.

2. **Filesystem Permission Hardening:**
   - Explicitly enforce `umask 077` and `chmod 600` when writing `.env` files containing credentials (`TS_AUTHKEY`, `WEBPASSWORD`).
   - Restrict permissions on `${TARGET_DIR}/serve.json` to `0644` or `0600`.

3. **Secure Credential Generation:**
   - Remove hardcoded default password fallback (`AdminPass123!`).
   - In non-interactive mode, if no password is provided via CLI, stdin, or environment variable, auto-generate a 32-character cryptographically secure token using `openssl rand -hex 16` (fallback to `/dev/urandom`), log it securely to the operator, and write it to `.env`.

---

### 2.2 Shell Robustness & Bug Fixes

1. **Typo Elimination in Parameter Expansion:**
   - Fix `ADMIN_PASSWORD="${input_pass:-$(generate_secure_password)}"` instead of the typo with trailing `}`.
2. **Safe Container Cleanup:**
   - Replace unquoted `${CONTAINER_ENGINE} rm -f ...` with a check ensuring `CONTAINER_ENGINE` is non-empty to prevent accidental invocation of `rm -f` against local files.
3. **Interactive Path Normalization:**
   - Expand tilde (`~`) in interactive input paths (`TARGET_DIR="${TARGET_DIR/#\~/$HOME}"`).
4. **Enhanced Compose Discovery:**
   - Update `detect_environment()` to check `podman compose` in addition to `podman-compose`, `docker compose`, `docker-compose`, and `uvx podman-compose`.

---

### 2.3 Kernel & Container Networking Subsystem

1. **Dual-Stack IPv4 & IPv6 Unprivileged Port Sysctl:**
   - Configure `/etc/sysctl.d/50-pihole-unprivileged-ports.conf` to set:
     ```ini
     net.ipv4.ip_unprivileged_port_start=53
     net.ipv6.ip_unprivileged_port_start=53
     ```
   - Only apply IPv6 sysctl if `/proc/sys/net/ipv6/ip_unprivileged_port_start` is present on the host.

2. **Container Log Rotation:**
   - Add standard log limits to generated `docker-compose.yml`:
     ```yaml
     logging:
       driver: "json-file"
       options:
         max-size: "20m"
         max-file: "3"
     ```

3. **Modern Compose Spec:**
   - Remove deprecated `version: "3"` top-level key from `docker-compose.yml`.

4. **Tailscale Rootless Device Handling:**
   - In Topology 3, verify availability of `/dev/net/tun`. If inaccessible in unprivileged user namespaces, provide actionable logging or fallback configuration.

---

### 2.4 Lifecycle & Teardown Subsystem

1. **Comprehensive Rollback (`run_uninstall`):**
   - Provide an optional `--purge-system` flag or interactive prompt:
     - Remove container stack and `${TARGET_DIR}`.
     - Remove `/etc/sysctl.d/50-pihole-unprivileged-ports.conf` and re-apply sysctl.
     - Remove `/etc/systemd/resolved.conf.d/no-stub.conf`.
     - Restore `/etc/systemd/resolved.conf.d/20-docker-dns.conf` if previously disabled.
     - Restart `systemd-resolved`.
     - Stop and disable `caddy` service if configured for Pi-hole.

---

### 2.5 Diagnostics & Automated Testing Subsystem

1. **Strict Healthcheck Exit Codes:**
   - Update `run_healthcheck` to return exit code `0` only if `failed == 0`, and return `1` if `failed > 0`.
2. **Automated Test Suite Expansion (`test_deployer.sh`):**
   - Test CLI help, dry-runs for all topologies.
   - Test password auto-generation.
   - Test `.env` file permissions (`0600`).
   - Test healthcheck non-zero exit code when no instance is active.
   - Test tilde expansion for target directory paths.
