# 🛡️ Pi-hole Universal Deployer for Linux

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Platform-Linux%20%28Arch%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20Fedora%29-FCC624.svg)](https://kernel.org)
[![Podman / Docker](https://img.shields.io/badge/Containers-Podman%20%7C%20Docker-892CA0.svg)](https://podman.io)
[![Tailscale](https://img.shields.io/badge/Tailscale-Mesh%20VPN%20%2B%20TLS-000000.svg)](https://tailscale.com)

A robust, idempotent, and production-ready Linux automation tool that deploys and manages **Pi-hole** across three distinct topologies:

1. **Standalone Host OS** with optional automated Let's Encrypt HTTPS (via Caddy reverse proxy).
2. **Rootless Containers (Podman / Docker)** with automated kernel `sysctl` unprivileged port 53 allocation, `systemd-resolved` conflict resolution, and boot persistence.
3. **Containerized Pi-hole + Tailscale Sidecar** with automated Let's Encrypt TLS termination (`tailscale serve`), OAuth Client & Auth Key support, and Pi-hole v6 port 443 conflict resolution.

---

## 📐 Architecture Overview

```mermaid
graph TD
    subgraph "Topology 1: Standalone Host"
        H_DNS[Host Port 53 - pihole-FTL]
        H_WEB[Host Port 80 - Pi-hole Web]
        H_TLS[Host Port 443 - Caddy / Let's Encrypt] -->|Proxy :80| H_WEB
    end

    subgraph "Topology 2: Rootless Container"
        C_SYSCTL[sysctl: ip_unprivileged_port_start=53]
        C_POD[Pi-hole Container]
        C_POD -->|Host Port 53| C_DNS[DNS Queries]
        C_POD -->|Host Port 8080| C_ADMIN[Web Admin UI]
    end

    subgraph "Topology 3: Tailscale + Pi-hole Sidecar Pod"
        TS_NET[Tailscale Network / Mesh]
        subgraph "Shared Network Namespace"
            TS_CONT[Tailscale Container: 'pihole']
            PI_CONT[Pi-hole Container]
            TS_CONT -->|TLS Termination :443| TS_SERVE[Tailscale Serve]
            TS_SERVE -->|Internal Proxy :80| PI_CONT
            TS_CONT -->|Tailnet Port 53| PI_CONT
        end
        TS_NET -->|HTTPS :443 / DNS :53| TS_CONT
    end
```

---

## ✨ Features & Idempotency Guarantees

* **Automated Port 53 Resolution:** Fixes the common Linux issue where rootless containers cannot bind privileged ports `< 1024` by configuring `net.ipv4.ip_unprivileged_port_start=53`.
* **Systemd-Resolved Stub Isolation:** Automatically resolves port 53 binding conflicts with `systemd-resolved` by creating drop-in overrides (`DNSStubListener=no`).
* **Pi-hole v6 HTTPS Conflict Avoidance:** In shared network pods (Tailscale sidecars), prevents Pi-hole's built-in self-signed TLS server from colliding with Tailscale Serve by setting `FTLCONF_webserver_port=80`.
* **Tailscale OAuth & Reusable Auth Keys:** Auto-detects `tskey-client-*` vs `tskey-auth-*` keys and automatically configures `--advertise-tags`.
* **Interactive TUI Wizard & CLI Flags:** Run interactively or automate via command-line arguments.
* **Built-in Diagnostics & Testing:** Includes `--healthcheck` and a test suite.

---

## 🚀 Quick Start

### 1. Clone & Run Interactively
```bash
git clone https://github.com/vijayet1/pihole-universal-deployer.git
cd pihole-universal-deployer
./pihole-deploy.sh
```

---

## 📖 CLI Usage & Topologies

### Topology 1: Standalone Host with Let's Encrypt HTTPS
Installs Pi-hole natively on the host OS and sets up Caddy for automated SSL certificates:
```bash
./pihole-deploy.sh \
  --mode standalone \
  --domain "pihole.yourdomain.com" \
  --password "YourStrongPassword123!"
```

### Topology 2: Rootless Container (Podman / Docker)
Deploys a rootless container stack with automatic sysctl/systemd port 53 fixes:
```bash
./pihole-deploy.sh \
  --mode container \
  --dir ~/pihole \
  --port 8080 \
  --password "YourStrongPassword123!"
```

### Topology 3: Tailscale Sidecar Pod (Automated TLS & OAuth)
Deploys the paired Tailscale + Pi-hole pod with zero host port conflicts and clean HTTPS on port 443:
```bash
# Using a Standard Reusable Auth Key
./pihole-deploy.sh \
  --mode tailscale \
  --dir ~/pihole \
  --tailscale-key "tskey-auth-kXXXXX" \
  --password "YourStrongPassword123!"

# Or using an OAuth Client Secret
./pihole-deploy.sh \
  --mode tailscale \
  --dir ~/pihole \
  --tailscale-key "tskey-client-kXXXXX" \
  --tailscale-tag "tag:pihole" \
  --password "YourStrongPassword123!"
```

---

## 🔍 Diagnostics & Testing

```bash
# Run healthcheck on existing deployment
./pihole-deploy.sh --healthcheck

# Run automated test suite
./tests/test_deployer.sh
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
