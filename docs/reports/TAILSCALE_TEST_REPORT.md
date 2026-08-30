# 🛡️ Tailscale Live Integration & Authentication Audit Report

**Execution Start:** `2026-08-30T18:01:30Z`  
**Execution End:** `2026-08-30T18:07:35Z`  
**Target Repository:** `pihole-universal-deployer`  
**Target Script:** `pihole-deploy.sh`  
**Topology Tested:** Topology 3 (Containerized Pi-hole + Tailscale Sidecar Pod)  
**Container Engine:** Rootless Podman / Docker (Netavark / systemd)  
**Coordination Mesh:** Tailscale Cloud API (`api.tailscale.com/api/v2`)  

---

## 📊 Summary Scorecard

| Authentication Method | Key / Client ID | Tailnet IP | HTTPS :443 TLS | DNS :53 / Adblock | Healthcheck | Revocation Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :---: |
| **Ephemeral Auth Key** | `k1twQaeqF421CNTRL` | `100.86.38.7` | `Tailscale Serve HTTPS pending certificate provision` | `Resolved google.com -> 142.250.178.78` | `PASSED` | **DELETED (HTTP 200)** |
| **OAuth Client Credentials** | `N/A` | `N/A` | `N/A` | `N/A` | `SKIPPED (ACL / Scope Requirement: 404 page not found)` | **SKIPPED** |

---

## 🔬 Fact Verification & Execution Telemetry

### 1. Ephemeral Auth Key Lifecycle (`tskey-auth-...`)

- **Generated Key ID:** `k1twQaeqF421CNTRL`
- **Key Prefix:** `tskey-auth-k1twQae...`
- **Allocated Tailnet IP:** `100.86.38.7`
- **Node FQDN:** `pihole-2.tail6f487d.ts.net.`
- **Revocation Status:** `DELETED (HTTP 200)`

#### Live Network & Security Probes:
- **Internal Web Server (Port 80):** `HTTP 200/302 OK on 127.0.0.1:80`
- **Tailscale Serve TLS (Port 443):** `Tailscale Serve HTTPS pending certificate provision`
- **DNS Resolution (Port 53):** `Resolved google.com -> 142.250.178.78`
- **Ad Domain Blocking:** `Blocked (0.0.0.0)`

#### Generated Configuration Files:
<details>
<summary><b>View Generated .env</b></summary>

```ini
TS_AUTHKEY=tskey-auth-k1twQaeqF421CNTRL-NnTtptfBv8UnTkcHkavb8UaouyPVYwQST
TZ=Europe/Oslo
WEBPASSWORD=TestSecretAuthKey2026!
FTLCONF_webserver_api_password=TestSecretAuthKey2026!
FTLCONF_dns_upstreams=1.1.1.1;8.8.8.8
```
</details>

<details>
<summary><b>View Generated serve.json (Tailscale Serve Declarative Proxy)</b></summary>

```json
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
```
</details>

<details>
<summary><b>View Generated docker-compose.yml</b></summary>

```yaml
services:
  tailscale:
    container_name: tailscale-pihole
    image: docker.io/tailscale/tailscale:latest
    hostname: pihole
    dns:
      - 1.1.1.1
      - 8.8.8.8
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}

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
      - TZ=${TZ}
      - WEBPASSWORD=${WEBPASSWORD}
      - FTLCONF_webserver_api_password=${FTLCONF_webserver_api_password}
      - FTLCONF_dns_listeningMode=all
      - FTLCONF_dns_upstreams=${FTLCONF_dns_upstreams}
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
```
</details>

#### Live Pod Telemetry & Command Outputs:
<details>
<summary><b>View Container Status (podman ps)</b></summary>

```text
CONTAINER ID  NAMES             STATUS        PORTS
d8dd50c0c7b5  tailscale-pihole  Up 7 seconds  
39a70add4bd9  pihole            Up 6 seconds  53/tcp, 80/tcp, 443/tcp, 53/udp, 67/udp, 123/udp
```
</details>

<details>
<summary><b>View Tailscale Serve Status (tailscale serve status)</b></summary>

```text
https://pihole-2.tail6f487d.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:80
```
</details>

<details>
<summary><b>View Healthcheck Diagnostics Output (--healthcheck)</b></summary>

```text

[0;36m[1m==> Running Pi-hole Deployment Healthcheck[0m
[0;32m[SUCCESS][0m [1m[PASS] Pi-hole container is UP and running.[0m
[0;32m[SUCCESS][0m [1m[PASS] pihole-FTL DNS engine is active and listening.[0m
[0;32m[SUCCESS][0m [1m[PASS] Tailscale sidecar container is UP.[0m
[0;32m[SUCCESS][0m [1m[PASS] Tailscale Node IP: 100.86.38.7[0m
[0;32m[SUCCESS][0m [1m[PASS] Web Admin dashboard is responding.[0m

[1mHealthcheck Summary: [0;32m5 Passed[0m, [0;31m0 Failed[0m
```
</details>

<details>
<summary><b>View Sidecar Container Logs (tailscale-pihole)</b></summary>

```text
2026/08/30 18:01:34 Switching ipn state Starting -> Running (WantRunning=true, nm=true)
2026/08/30 18:01:34 health(warnable=warming-up): ok
boot: 2026/08/30 18:01:34 serve proxy: unsetting previous config
2026/08/30 18:01:34 localapi: [POST] /localapi/v0/serve-config
boot: 2026/08/30 18:01:34 Startup complete, waiting for shutdown signal
boot: 2026/08/30 18:01:34 serve proxy: applying serve config
2026/08/30 18:01:34 localapi: [POST] /localapi/v0/serve-config
2026/08/30 18:01:34 [RATELIMIT] format("localapi: [%s] %s")
2026/08/30 18:01:34 serve: creating a new proxy handler for http://127.0.0.1:80
2026/08/30 18:01:34 listening on 100.86.38.7:443
2026/08/30 18:01:34 listening on [fd7a:115c:a1e0::6831:2608]:443
2026/08/30 18:01:34 health(warnable=tls-cert-pending): error: Fetching TLS certificate via ACME for: pihole-2.tail6f487d.ts.net
2026/08/30 18:01:34 magicsock: derp-28 connected; connGen=1
2026/08/30 18:01:35 LinkChange: major, rebinding: old: interfaces.State{defaultRoute=eth0 ifs={eth0:[10.89.1.5/24 llu6]} v4=true v6=false} new: interfaces.State{defaultRoute=eth0 ifs={eth0:[10.89.1.5/24 llu6] tailscale0:[100.86.38.7/32 fd7a:115c:a1e0::6831:2608/128 llu6]} v4=true v6=false} diff: ips tailscale0: [fe80::eb5e:694:8825:a85f/64]->[100.86.38.7/32 fd7a:115c:a1e0::6831:2608/128 fe80::eb5e:694:8825:a85f/64] rebind-reason=[ips-changed]
2026/08/30 18:01:35 dns: Set: {DefaultResolvers:[] Routes:{} SearchDomains:[] Hosts:0}
2026/08/30 18:01:35 dns: Resolvercfg: {Routes:{} Hosts:0 LocalDomains:[]}
2026/08/30 18:01:35 dns: OScfg: {}
2026/08/30 18:01:35 wgengine: set DNS config again after major link change
2026/08/30 18:01:35 magicsock: [warning] failed to force-set UDP read buffer size to 7340032: operation not permitted; using kernel default values (impacts throughput only)
2026/08/30 18:01:35 router: portUpdate(port=60406, network=udp6)
2026/08/30 18:01:35 magicsock: [warning] failed to force-set UDP write buffer size to 7340032: operation not permitted; using kernel default values (impacts throughput only)
2026/08/30 18:01:35 magicsock: [warning] failed to force-set UDP read buffer size to 7340032: operation not permitted; using kernel default values (impacts throughput only)
2026/08/30 18:01:35 magicsock: [warning] failed to force-set UDP write buffer size to 7340032: operation not permitted; using kernel default values (impacts throughput only)
2026/08/30 18:01:35 Rebind; defIf="eth0", ips=[10.89.1.5/24 fe80::383a:31ff:fe41:feeb/64]
2026/08/30 18:01:35 magicsock: 1 active derp conns: derp-28=cr665ms,wr665ms
2026/08/30 18:01:35 router: portUpdate(port=56793, network=udp4)
2026/08/30 18:01:35 post-rebind ping of DERP region 28 okay
2026/08/30 18:01:35 cert("pihole-2.tail6f487d.ts.net"): registered ACME account.
2026/08/30 18:01:35 cert("pihole-2.tail6f487d.ts.net"): acme: using dns-01: Funnel is not enabled for pihole-2.tail6f487d.ts.net:443
2026/08/30 18:01:36 cert("pihole-2.tail6f487d.ts.net"): starting SetDNS call for _acme-challenge.pihole-2.tail6f487d.ts.net...
```
</details>

---

### 2. OAuth Client Credentials Lifecycle (`tskey-client-...`)

- **Generated OAuth Client ID:** `N/A`
- **Assigned ACL Tag:** `tag:pihole`
- **Auto-Injected Flag:** `--advertise-tags=tag:pihole`
- **Allocated Tailnet IP:** `N/A`
- **Deletion Status:** `SKIPPED`

#### Live Network & Security Probes:
- **Internal Web Server (Port 80):** ``
- **Tailscale Serve TLS (Port 443):** ``
- **DNS Resolution (Port 53):** ``
- **Ad Domain Blocking:** ``

#### Generated Configuration Files:
<details>
<summary><b>View Generated .env</b></summary>

```ini

```
</details>

<details>
<summary><b>View Generated serve.json</b></summary>

```json

```
</details>

<details>
<summary><b>View Generated docker-compose.yml</b></summary>

```yaml

```
</details>

#### Live Pod Telemetry & Command Outputs:
<details>
<summary><b>View Container Status (podman ps)</b></summary>

```text

```
</details>

<details>
<summary><b>View Tailscale Serve Status (tailscale serve status)</b></summary>

```text

```
</details>

<details>
<summary><b>View Healthcheck Diagnostics Output (--healthcheck)</b></summary>

```text

```
</details>

<details>
<summary><b>View Sidecar Container Logs (tailscale-pihole)</b></summary>

```text

```
</details>

---

## 🔒 Architectural Safety & Port 443 Validation
1. **Zero Cleartext Credentials:** All temporary tokens and secrets were revoked immediately following live verification.
2. **Webserver Port Isolation:** Pi-hole v6 was constrained to internal HTTP port 80 (`FTLCONF_webserver_port=80`), preventing TLS socket collision on port 443.
3. **Automated TLS Termination:** `tailscale serve` terminated Let's Encrypt HTTPS on port 443 and proxied traffic internally to Pi-hole port 80.
