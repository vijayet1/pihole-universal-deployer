#!/usr/bin/env bash
# ==============================================================================
# Pi-hole Universal Deployment Tool (pihole-deploy.sh)
# ------------------------------------------------------------------------------
# Supports 3 Topologies:
#   1. Standalone (Host OS) + Optional Automated Let's Encrypt HTTPS (Caddy)
#   2. Rootless Container Stack (Podman / Docker) with Port 53 & systemd fixes
#   3. Containerized Pi-hole + Tailscale Sidecar with Automated TLS & OAuth
#   4. Uninstaller / Rollback Mode
#
# Idempotent, robust, and compatible with Arch, Debian, Ubuntu, Fedora, RHEL.
# ==============================================================================

set -euo pipefail

# --- Color Definitions & Logging ---
readonly BOLD='\033[1m'
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} ${BOLD}$*${NC}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} ${BOLD}$*${NC}" >&2; }
log_step()    { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }

# --- Default Configurations ---
DEPLOY_MODE=""
TARGET_DIR="${HOME}/pihole"
ADMIN_PASSWORD=""
TIMEZONE=""
CUSTOM_DOMAIN=""
TAILSCALE_KEY=""
TAILSCALE_TAG="tag:pihole"
HTTP_PORT="8080"
ENABLE_SYSTEMD="true"
PURGE_SYSTEM="false"
DRY_RUN="false"

# --- Helper: Privilege Escalation ---
run_privileged() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] sudo $*"
    return 0
  fi

  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo &>/dev/null; then
    sudo "$@"
  elif command -v pkexec &>/dev/null; then
    pkexec "$@"
  else
    log_error "Root privileges required, but neither sudo nor pkexec was found."
    exit 1
  fi
}

# --- Helper: Secure Password Generation ---
generate_secure_password() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 16
  else
    LC_ALL=C tr -dc 'A-Za-z0-9!#%_+=' < /dev/urandom | (head -c 32; true)
  fi
}

# --- System Detection ---
detect_environment() {
  log_step "Detecting Environment & System Capabilities"

  # Timezone Detection
  if [[ -z "${TIMEZONE}" ]]; then
    if command -v timedatectl &>/dev/null; then
      TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    elif [[ -f /etc/timezone ]]; then
      TIMEZONE=$(cat /etc/timezone)
    else
      TIMEZONE="UTC"
    fi
  fi
  log_info "Detected Timezone: ${TIMEZONE}"

  # Container Engine Detection
  CONTAINER_ENGINE=""
  COMPOSE_CMD=""
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
  elif command -v docker &>/dev/null; then
    CONTAINER_ENGINE="docker"
    if docker compose version &>/dev/null; then
      COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
      COMPOSE_CMD="docker-compose"
    fi
  fi

  log_info "Container Engine: ${CONTAINER_ENGINE:-None detected}"
  log_info "Compose Provider: ${COMPOSE_CMD:-None detected}"
}

# --- Kernel & Systemd Port 53 Fixes ---
configure_system_dns_and_ports() {
  log_step "Configuring Kernel Ports and Resolving DNS Port 53 Conflicts"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would configure sysctl unprivileged ports and resolved drop-ins."
    return 0
  fi

  # 1. Allow rootless unprivileged ports >= 53
  local sysctl_conf="/etc/sysctl.d/50-pihole-unprivileged-ports.conf"
  local sysctl_content="net.ipv4.ip_unprivileged_port_start=53"
  if [[ -f /proc/sys/net/ipv6/ip_unprivileged_port_start ]]; then
    sysctl_content+=$'\nnet.ipv6.ip_unprivileged_port_start=53'
  fi

  local current_port_start
  current_port_start=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo "1024")
  local need_sysctl_update="false"
  if (( current_port_start > 53 )); then
    need_sysctl_update="true"
  elif [[ ! -f "${sysctl_conf}" ]] && ! grep -q -r -s -E "ip_unprivileged_port_start[[:space:]]*=[[:space:]]*53" /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null; then
    need_sysctl_update="true"
  elif [[ -f "${sysctl_conf}" ]] && [[ -f /proc/sys/net/ipv6/ip_unprivileged_port_start ]] && ! grep -q "net.ipv6.ip_unprivileged_port_start=53" "${sysctl_conf}"; then
    need_sysctl_update="true"
  fi

  if [[ "${need_sysctl_update}" == "true" ]]; then
    log_info "Enabling unprivileged port 53 in sysctl..."
    printf "%s\n" "${sysctl_content}" | run_privileged tee "${sysctl_conf}" >/dev/null
    run_privileged sysctl --system >/dev/null
    log_success "Kernel unprivileged port threshold lowered to 53."
  else
    log_info "Sysctl unprivileged port threshold is already set."
  fi

  # 2. Disable systemd-resolved DNSStubListener if active
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log_info "systemd-resolved is active. Checking for port 53 stub conflicts..."
    local resolved_dir="/etc/systemd/resolved.conf.d"
    local stub_conf="${resolved_dir}/no-stub.conf"
    local docker_stub="${resolved_dir}/20-docker-dns.conf"
    local need_resolved_restart="false"

    # Create no-stub override if missing
    if [[ ! -f "${stub_conf}" ]]; then
      log_info "Disabling systemd-resolved DNSStubListener..."
      run_privileged mkdir -p "${resolved_dir}"
      printf "[Resolve]\nDNSStubListener=no\n" | run_privileged tee "${stub_conf}" >/dev/null
      need_resolved_restart="true"
    fi

    # Disable conflicting Docker extra stubs (e.g. 20-docker-dns.conf)
    if [[ -f "${docker_stub}" ]]; then
      log_warn "Found conflicting Docker stub listener (${docker_stub}). Disabling it..."
      run_privileged mv "${docker_stub}" "${docker_stub}.disabled"
      need_resolved_restart="true"
    fi

    if [[ "${need_resolved_restart}" == "true" ]]; then
      log_info "Restarting systemd-resolved..."
      run_privileged systemctl restart systemd-resolved || true
    fi
    log_success "systemd-resolved configured without port 53 conflict."
  fi

  # 3. Stop any background QEMU podman-machine gvproxy if on Linux
  if command -v podman &>/dev/null; then
    local running_vms
    running_vms=$(podman machine list 2>/dev/null | grep -E "Currently running|running" || true)
    if [[ -n "${running_vms}" ]]; then
      log_warn "Detected running 'podman machine' VM holding port 53 via gvproxy. Stopping it..."
      podman machine stop || true
    fi
  fi
}

# ==============================================================================
# TOPOLOGY 1: Standalone Host Deployment
# ==============================================================================
deploy_standalone() {
  log_step "Deploying Topology 1: Standalone Host Installation"

  if [[ -f /usr/local/bin/pihole ]] || command -v pihole &>/dev/null; then
    log_info "Pi-hole is already installed on this host."
  else
    log_info "Downloading and running official Pi-hole unattended installer..."
    if [[ "${DRY_RUN}" != "true" ]]; then
      mkdir -p /etc/pihole
      if [[ -n "${ADMIN_PASSWORD}" ]]; then
        run_privileged bash -c "curl -sSL https://install.pi-hole.net | bash --unattended"
      else
        curl -sSL https://install.pi-hole.net | bash
      fi
    fi
  fi

  # Set admin password if provided
  if [[ -n "${ADMIN_PASSWORD}" && "${DRY_RUN}" != "true" ]]; then
    log_info "Setting Pi-hole web admin password..."
    run_privileged pihole setpassword "${ADMIN_PASSWORD}"
  fi

  # Optional Automated Let's Encrypt HTTPS via Caddy
  if [[ -n "${CUSTOM_DOMAIN}" ]]; then
    log_step "Configuring Automated Let's Encrypt HTTPS for ${CUSTOM_DOMAIN} (via Caddy)"
    if ! command -v caddy &>/dev/null && [[ "${DRY_RUN}" != "true" ]]; then
      log_info "Installing Caddy webserver..."
      if command -v pacman &>/dev/null; then
        run_privileged pacman -S --noconfirm caddy
      elif command -v apt-get &>/dev/null; then
        run_privileged apt-get update && run_privileged apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | run_privileged gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLF 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | run_privileged tee /etc/apt/sources.list.d/caddy-stable.list
        run_privileged apt-get update && run_privileged apt-get install -y caddy
      elif command -v dnf &>/dev/null; then
        run_privileged dnf install -y 'dnf-command(copr)'
        run_privileged dnf copr enable -y @caddy/caddy
        run_privileged dnf install -y caddy
      fi
    fi

    # Create Caddy reverse proxy config
    local caddyfile="/etc/caddy/Caddyfile"
    log_info "Writing automated HTTPS Caddyfile to ${caddyfile}..."
    if [[ "${DRY_RUN}" != "true" ]]; then
      cat <<EOF | run_privileged tee "${caddyfile}" >/dev/null
${CUSTOM_DOMAIN} {
    reverse_proxy 127.0.0.1:80
}
EOF
      run_privileged systemctl enable --now caddy
      run_privileged systemctl restart caddy
      log_success "Let's Encrypt TLS active at: https://${CUSTOM_DOMAIN}/admin"
    fi
  fi
}

# ==============================================================================
# TOPOLOGY 2: Rootless Container Deployment
# ==============================================================================
deploy_container() {
  log_step "Deploying Topology 2: Rootless Container Stack (Podman / Docker)"

  configure_system_dns_and_ports

  mkdir -p "${TARGET_DIR}/etc-pihole" "${TARGET_DIR}/etc-dnsmasq.d"

  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD=$(generate_secure_password)
    log_info "Auto-generated secure Pi-hole admin password: ${ADMIN_PASSWORD}"
  fi

  # 1. Create .env
  local env_file="${TARGET_DIR}/.env"
  log_info "Creating environment file: ${env_file}"
  (umask 077 && touch "${env_file}")
  chmod 600 "${env_file}"
  cat <<EOF > "${env_file}"
TZ=${TIMEZONE}
WEBPASSWORD=${ADMIN_PASSWORD}
FTLCONF_webserver_api_password=${ADMIN_PASSWORD}
FTLCONF_dns_listeningMode=all
FTLCONF_dns_upstreams=1.1.1.1;8.8.8.8
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=8.8.8.8
EOF

  # 2. Create docker-compose.yml
  local compose_file="${TARGET_DIR}/docker-compose.yml"
  log_info "Writing ${compose_file}..."
  cat <<EOF > "${compose_file}"
services:
  pihole:
    container_name: pihole
    image: docker.io/pihole/pihole:latest
    network_mode: "bridge"
    restart: unless-stopped
    dns:
      - 1.1.1.1
      - 8.8.8.8
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "${HTTP_PORT}:80/tcp"
    environment:
      - TZ=\${TZ}
      - WEBPASSWORD=\${WEBPASSWORD}
      - FTLCONF_webserver_api_password=\${FTLCONF_webserver_api_password}
      - FTLCONF_dns_listeningMode=\${FTLCONF_dns_listeningMode}
      - FTLCONF_dns_upstreams=\${FTLCONF_dns_upstreams}
      - PIHOLE_DNS_1=\${PIHOLE_DNS_1}
      - PIHOLE_DNS_2=\${PIHOLE_DNS_2}
    volumes:
      - ./etc-pihole:/etc/pihole:Z
      - ./etc-dnsmasq.d:/etc/dnsmasq.d:Z
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Stack generated in ${TARGET_DIR}. Skipping execution."
    return 0
  fi

  # 3. Launch Stack
  log_info "Starting container stack via ${COMPOSE_CMD}..."
  if [[ -n "${CONTAINER_ENGINE}" ]]; then
    "${CONTAINER_ENGINE}" rm -f pihole 2>/dev/null || true
  fi
  (cd "${TARGET_DIR}" && ${COMPOSE_CMD} up -d)

  # 4. Configure Systemd User Service & Linger for Boot Autostart
  if [[ "${CONTAINER_ENGINE}" == "podman" && "${ENABLE_SYSTEMD}" == "true" ]]; then
    if [[ "$(loginctl show-user "${USER}" --property=Linger 2>/dev/null)" != "Linger=yes" ]]; then
      log_info "Enabling systemd linger for user ${USER}..."
      loginctl enable-linger "${USER}" 2>/dev/null || run_privileged loginctl enable-linger "${USER}" 2>/dev/null || true
    fi
  fi

  log_success "Pi-hole container deployed successfully!"
  log_info "Web Dashboard: http://localhost:${HTTP_PORT}/admin"
}

# ==============================================================================
# TOPOLOGY 3: Tailscale + Pi-hole Sidecar Deployment
# ==============================================================================
deploy_tailscale_sidecar() {
  log_step "Deploying Topology 3: Tailscale Sidecar + Pi-hole with Automated TLS"

  if [[ ! -c /dev/net/tun ]]; then
    log_warn "/dev/net/tun not found or inaccessible. Tailscale will require userspace networking."
  fi

  mkdir -p "${TARGET_DIR}/etc-pihole" "${TARGET_DIR}/etc-dnsmasq.d" "${TARGET_DIR}/tailscale-state"

  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD=$(generate_secure_password)
    log_info "Auto-generated secure Pi-hole admin password: ${ADMIN_PASSWORD}"
  fi

  # Detect OAuth vs Auth Key
  local extra_args=""
  if [[ "${TAILSCALE_KEY}" == tskey-client-* ]]; then
    log_info "Detected Tailscale OAuth Client Secret. Adding --advertise-tags=${TAILSCALE_TAG}..."
    extra_args="--advertise-tags=${TAILSCALE_TAG}"
  fi

  # 1. Create .env
  local env_file="${TARGET_DIR}/.env"
  log_info "Writing ${env_file}..."
  (umask 077 && touch "${env_file}")
  chmod 600 "${env_file}"
  cat <<EOF > "${env_file}"
TS_AUTHKEY=${TAILSCALE_KEY}
TZ=${TIMEZONE}
WEBPASSWORD=${ADMIN_PASSWORD}
FTLCONF_webserver_api_password=${ADMIN_PASSWORD}
FTLCONF_dns_upstreams=1.1.1.1;8.8.8.8
EOF

  # 2. Create serve.json for Tailscale Serve (HTTPS 443 -> HTTP 80)
  local serve_file="${TARGET_DIR}/serve.json"
  log_info "Writing Tailscale Serve declarative config to ${serve_file}..."
  (umask 077 && touch "${serve_file}")
  chmod 600 "${serve_file}"
  cat <<'EOF' > "${serve_file}"
{
  "TCP": {
    "443": {
      "HTTPS": true
    }
  },
  "Web": {
    "${TS_CERT_DOMAIN}:443": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:80"
        }
      }
    }
  }
}
EOF

  # 3. Create docker-compose.yml
  local compose_file="${TARGET_DIR}/docker-compose.yml"
  log_info "Writing sidecar ${compose_file}..."
  cat <<EOF > "${compose_file}"
services:
  tailscale:
    container_name: tailscale-pihole
    image: docker.io/tailscale/tailscale:latest
    hostname: pihole
    dns:
      - 1.1.1.1
      - 8.8.8.8
    environment:
      - TS_AUTHKEY=\${TS_AUTHKEY}
$( [[ -n "${extra_args}" ]] && echo "      - TS_EXTRA_ARGS=${extra_args}" )
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_SERVE_CONFIG=/config/serve.json
    volumes:
      - ./tailscale-state:/var/lib/tailscale:Z
      - ./serve.json:/config/serve.json:ro,Z
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"

  pihole:
    container_name: pihole
    image: docker.io/pihole/pihole:latest
    depends_on:
      - tailscale
    network_mode: "service:tailscale"
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
      - WEBPASSWORD=\${WEBPASSWORD}
      - FTLCONF_webserver_api_password=\${FTLCONF_webserver_api_password}
      - FTLCONF_dns_listeningMode=all
      - FTLCONF_dns_upstreams=\${FTLCONF_dns_upstreams}
      - FTLCONF_webserver_port=80
      - PIHOLE_DNS_1=1.1.1.1
      - PIHOLE_DNS_2=8.8.8.8
    volumes:
      - ./etc-pihole:/etc/pihole:Z
      - ./etc-dnsmasq.d:/etc/dnsmasq.d:Z
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"
EOF

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Tailscale sidecar stack generated in ${TARGET_DIR}. Skipping execution."
    return 0
  fi

  # 4. Clean previous instances and launch
  log_info "Launching Tailscale + Pi-hole pod..."
  if [[ -n "${CONTAINER_ENGINE}" ]]; then
    "${CONTAINER_ENGINE}" rm -f pihole tailscale-pihole 2>/dev/null || true
  fi
  (cd "${TARGET_DIR}" && ${COMPOSE_CMD} up -d)

  log_success "Tailscale Pi-hole Pod is starting!"
  log_info "Verify registration: podman logs -f tailscale-pihole"
  log_info "Once connected, access via HTTPS without port numbers at:"
  log_info "  https://pihole.<your-tailnet>.ts.net/admin"
}

# ==============================================================================
# Uninstall / Rollback Functionality
# ==============================================================================
run_uninstall() {
  log_step "Uninstalling and Removing Pi-hole Stack"

  # 1. Stop Containers if running
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would remove containers if running."
  elif [[ -n "${CONTAINER_ENGINE}" ]]; then
    "${CONTAINER_ENGINE}" rm -f pihole tailscale-pihole 2>/dev/null || true
  else
    if command -v podman &>/dev/null; then
      podman rm -f pihole tailscale-pihole 2>/dev/null || true
    elif command -v docker &>/dev/null; then
      docker rm -f pihole tailscale-pihole 2>/dev/null || true
    fi
  fi

  # 2. Standalone Pi-hole removal if installed
  if command -v pihole &>/dev/null; then
    log_info "Calling host pihole uninstall..."
    run_privileged pihole uninstall || true
  fi

  # 3. System Rollback & Purge
  if [[ "${PURGE_SYSTEM}" == "true" ]]; then
    log_step "Restoring system DNS and sysctl settings..."
    local sysctl_conf="/etc/sysctl.d/50-pihole-unprivileged-ports.conf"
    if [[ -f "${sysctl_conf}" ]] || [[ "${DRY_RUN}" == "true" ]]; then
      run_privileged rm -f "${sysctl_conf}"
      run_privileged sysctl --system >/dev/null 2>&1 || true
    fi

    local resolved_dir="/etc/systemd/resolved.conf.d"
    run_privileged rm -f "${resolved_dir}/no-stub.conf"
    if [[ -f "${resolved_dir}/20-docker-dns.conf.disabled" ]] || [[ "${DRY_RUN}" == "true" ]]; then
      run_privileged mv "${resolved_dir}/20-docker-dns.conf.disabled" "${resolved_dir}/20-docker-dns.conf"
    fi
    run_privileged systemctl restart systemd-resolved 2>/dev/null || true

    if [[ -f "/etc/caddy/Caddyfile" ]] || [[ "${DRY_RUN}" == "true" ]]; then
      run_privileged rm -f "/etc/caddy/Caddyfile"
    fi

    if systemctl is-active --quiet caddy 2>/dev/null || [[ "${DRY_RUN}" == "true" ]]; then
      run_privileged systemctl stop caddy || true
      run_privileged systemctl disable caddy || true
    fi
  fi

  # 4. Clean deployment directory
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would remove deployment directory: ${TARGET_DIR}"
  elif [[ -d "${TARGET_DIR}" ]]; then
    log_warn "Removing deployment directory: ${TARGET_DIR}"
    if command -v podman &>/dev/null; then
      podman unshare rm -rf "${TARGET_DIR}" 2>/dev/null || rm -rf "${TARGET_DIR}" 2>/dev/null || run_privileged rm -rf "${TARGET_DIR}" || true
    else
      rm -rf "${TARGET_DIR}" 2>/dev/null || run_privileged rm -rf "${TARGET_DIR}" || true
    fi
  fi

  log_success "Pi-hole deployment has been uninstalled."
}

# ==============================================================================
# Healthcheck Functionality
# ==============================================================================
run_healthcheck() {
  log_step "Running Pi-hole Deployment Healthcheck"

  local passed=0
  local failed=0

  # Check Container Status
  if command -v podman &>/dev/null && podman ps --filter name=pihole --format "{{.Status}}" 2>/dev/null | grep -i "up" >/dev/null 2>&1; then
    log_success "[PASS] Pi-hole container is UP and running."
    ((passed++)) || true
    if podman exec pihole pihole status 2>/dev/null | grep -i "listening" >/dev/null 2>&1; then
      log_success "[PASS] pihole-FTL DNS engine is active and listening."
      ((passed++)) || true
    fi
  elif command -v docker &>/dev/null && docker ps --filter name=pihole --format "{{.Status}}" 2>/dev/null | grep -i "up" >/dev/null 2>&1; then
    log_success "[PASS] Pi-hole container is UP and running."
    ((passed++)) || true
    if docker exec pihole pihole status 2>/dev/null | grep -i "listening" >/dev/null 2>&1; then
      log_success "[PASS] pihole-FTL DNS engine is active and listening."
      ((passed++)) || true
    fi
  elif command -v pihole &>/dev/null; then
    log_success "[PASS] Host Pi-hole binary is installed."
    ((passed++)) || true
    if pihole status 2>/dev/null | grep -i "listening" >/dev/null 2>&1; then
      log_success "[PASS] Host Pi-hole DNS engine is active."
      ((passed++)) || true
    fi
  else
    log_error "[FAIL] No running Pi-hole container or host service found."
    ((failed++)) || true
  fi

  # Check Tailscale Sidecar if present
  if command -v podman &>/dev/null && podman ps --filter name=tailscale-pihole --format "{{.Status}}" 2>/dev/null | grep -i "up" >/dev/null 2>&1; then
    log_success "[PASS] Tailscale sidecar container is UP."
    ((passed++)) || true
    local ts_ip
    ts_ip=$(podman exec tailscale-pihole tailscale ip -4 2>/dev/null || true)
    if [[ -n "${ts_ip}" ]]; then
      log_success "[PASS] Tailscale Node IP: ${ts_ip}"
      ((passed++)) || true
    fi
  fi

  # Check Web Admin Response
  if curl -sI http://127.0.0.1:8080/admin/ >/dev/null 2>&1 || curl -sI http://127.0.0.1/admin/ >/dev/null 2>&1 || curl -k -sI https://127.0.0.1/admin/ >/dev/null 2>&1; then
    log_success "[PASS] Web Admin dashboard is responding."
    ((passed++)) || true
  else
    log_warn "[WARN] Web dashboard did not respond locally on standard ports."
    ((failed++)) || true
  fi

  echo -e "\n${BOLD}Healthcheck Summary: ${GREEN}${passed} Passed${NC}, ${RED}${failed} Failed${NC}"
  if (( failed > 0 )); then
    return 1
  fi
  return 0
}

# ==============================================================================
# Interactive Wizard
# ==============================================================================
run_interactive_wizard() {
  echo -e "${PURPLE}${BOLD}"
  echo "  ██████╗ ██╗██╗  ██╗ ██████╗ ██╗     ███████╗"
  echo "  ██╔══██╗██║██║  ██║██╔═══██╗██║     ██╔════╝"
  echo "  ██████╔╝██║███████║██║   ██║██║     █████╗  "
  echo "  ██╔═══╝ ██║██╔══██║██║   ██║██║     ██╔══╝  "
  echo "  ██║     ██║██║  ██║╚██████╔╝███████╗███████╗"
  echo "  ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝"
  echo -e "${NC}"
  echo -e "${BOLD}Universal Pi-hole Automated Deployment Script${NC}\n"

  echo "Select Deployment Topology:"
  echo "  1) Standalone (Host OS) + Optional Let's Encrypt HTTPS"
  echo "  2) Containerized (Podman / Docker) with Port 53 & systemd fixes"
  echo "  3) Containerized Pi-hole + Tailscale Sidecar (Automated TLS & OAuth)"
  echo "  4) Uninstall / Remove Pi-hole"
  echo ""
  read -rp "Enter choice [1-4]: " choice

  case "${choice}" in
    1)
      DEPLOY_MODE="standalone"
      read -rp "Configure automated Let's Encrypt HTTPS domain? (Leave empty for none): " CUSTOM_DOMAIN
      ;;
    2)
      DEPLOY_MODE="container"
      read -rp "Target Directory [${TARGET_DIR}]: " input_dir
      TARGET_DIR="${input_dir:-$TARGET_DIR}"
      TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
      read -rp "Web UI Host Port [${HTTP_PORT}]: " input_port
      HTTP_PORT="${input_port:-$HTTP_PORT}"
      ;;
    3)
      DEPLOY_MODE="tailscale"
      read -rp "Target Directory [${TARGET_DIR}]: " input_dir
      TARGET_DIR="${input_dir:-$TARGET_DIR}"
      TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
      read -rp "Enter Tailscale Auth Key or OAuth Secret (tskey-...): " TAILSCALE_KEY
      if [[ "${TAILSCALE_KEY}" == tskey-client-* ]]; then
        read -rp "OAuth Tag [${TAILSCALE_TAG}]: " input_tag
        TAILSCALE_TAG="${input_tag:-$TAILSCALE_TAG}"
      fi
      ;;
    4)
      DEPLOY_MODE="uninstall"
      read -rp "Target Directory to remove [${TARGET_DIR}]: " input_dir
      TARGET_DIR="${input_dir:-$TARGET_DIR}"
      TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
      read -rp "Purge system DNS, sysctl settings, and stop Caddy? (y/N): " purge_choice
      if [[ "${purge_choice}" =~ ^[Yy]$ ]]; then
        PURGE_SYSTEM="true"
      fi
      ;;
    *)
      log_error "Invalid selection. Exiting."
      exit 1
      ;;
  esac

  if [[ "${DEPLOY_MODE}" != "uninstall" ]]; then
    read -rsp "Set Pi-hole Admin Password [leave blank to auto-generate]: " input_pass
    echo ""
    ADMIN_PASSWORD="${input_pass:-}"
  fi
}

# ==============================================================================
# Argument Parsing & CLI Dispatch
# ==============================================================================
print_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Topologies:
  --mode standalone        Deploy directly on Host OS
  --mode container         Deploy rootless container stack (Podman / Docker)
  --mode tailscale         Deploy container + Tailscale sidecar pod with HTTPS
  --mode uninstall         Remove containers and cleanup deployment

Options:
  --dir <path>             Target installation directory (default: ~/pihole)
  --password <password>    Pi-hole Admin Web UI password
  --password-stdin         Read Pi-hole password from standard input
  --domain <fqdn>          Domain for Let's Encrypt HTTPS (Standalone mode)
  --tailscale-key <key>    Tailscale Auth Key (tskey-auth-...) or OAuth Secret (tskey-client-...)
  --tailscale-tag <tag>    Tag for OAuth key (default: tag:pihole)
  --port <port>            Host port for Web UI in container mode (default: 8080)
  --timezone <tz>          Timezone string (e.g. Europe/Berlin, UTC)
  --purge-system           Rollback system DNS, sysctl configs, and Caddy on uninstall
  --healthcheck            Run diagnostics on existing installation
  --dry-run                Show deployment plan without executing commands
  -h, --help               Show this help message

Examples:
  # Interactive Wizard
  $0

  # Standalone with Let's Encrypt Caddy HTTPS
  $0 --mode standalone --domain "pihole.example.com" --password "MySecretPass123!"

  # Rootless Container Stack Deployment
  $0 --mode container --dir ~/pihole --password "MySecretPass123!"

  # Tailscale Sidecar Deployment
  $0 --mode tailscale --tailscale-key "tskey-auth-kXXXX" --password "MySecretPass123!"
EOF
}

parse_args() {
  ADMIN_PASSWORD="${PIHOLE_PASSWORD:-${ADMIN_PASSWORD}}"
  TAILSCALE_KEY="${TS_AUTHKEY:-${TAILSCALE_KEY:-${TAILSCALE_AUTHKEY:-}}}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        DEPLOY_MODE="$2"
        shift 2
        ;;
      --dir)
        TARGET_DIR="$2"
        TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
        shift 2
        ;;
      --password)
        ADMIN_PASSWORD="$2"
        shift 2
        ;;
      --password-stdin)
        IFS= read -r ADMIN_PASSWORD || [[ -n "${ADMIN_PASSWORD}" ]]
        shift
        ;;
      --domain)
        CUSTOM_DOMAIN="$2"
        shift 2
        ;;
      --tailscale-key)
        TAILSCALE_KEY="$2"
        shift 2
        ;;
      --tailscale-tag)
        TAILSCALE_TAG="$2"
        shift 2
        ;;
      --port)
        HTTP_PORT="$2"
        shift 2
        ;;
      --timezone)
        TIMEZONE="$2"
        shift 2
        ;;
      --purge-system)
        PURGE_SYSTEM="true"
        shift
        ;;
      --healthcheck)
        if run_healthcheck; then
          exit 0
        else
          exit 1
        fi
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        print_usage
        exit 1
        ;;
    esac
  done
}

# --- Main Entrypoint ---
main() {
  parse_args "$@"
  detect_environment

  if [[ -z "${DEPLOY_MODE}" ]]; then
    run_interactive_wizard
  fi

  case "${DEPLOY_MODE}" in
    standalone)
      deploy_standalone
      ;;
    container)
      deploy_container
      ;;
    tailscale)
      deploy_tailscale_sidecar
      ;;
    uninstall)
      run_uninstall
      ;;
    *)
      log_error "Unknown mode: '${DEPLOY_MODE}'. Use standalone, container, tailscale, or uninstall."
      exit 1
      ;;
  esac

  echo ""
  log_success "Deployment process completed successfully!"
}

main "$@"
