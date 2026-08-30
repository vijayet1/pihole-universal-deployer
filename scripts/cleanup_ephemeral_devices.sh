#!/usr/bin/env bash
# ==============================================================================
# Tailscale Ephemeral / Test Device Cleanup Utility
# ------------------------------------------------------------------------------
# Scans your Tailnet for test/ephemeral Pi-hole nodes and purges them via REST API.
# ==============================================================================
set -euo pipefail

TS_API_KEY="${TS_API_KEY:-}"

if [[ -z "${TS_API_KEY}" ]]; then
  if [[ -n "${1:-}" ]]; then
    TS_API_KEY="$1"
  else
    echo "================================================================================"
    echo "  Tailscale Ephemeral Device Cleanup Utility"
    echo "================================================================================"
    read -r -p "Enter your Tailscale API Key (tskey-api-...): " TS_API_KEY
  fi
fi

if [[ -z "${TS_API_KEY}" ]]; then
  echo "Error: Tailscale API Key is required."
  exit 1
fi

echo "==> Fetching devices from Tailscale API..."
DEVICES_JSON=$(curl -s -H "Authorization: Bearer ${TS_API_KEY}" "https://api.tailscale.com/api/v2/tailnet/-/devices")

if ! echo "${DEVICES_JSON}" | jq -e '.devices' >/dev/null 2>&1; then
  echo "❌ Failed to query Tailscale devices. Response: ${DEVICES_JSON}"
  exit 1
fi

# Filter for pihole test devices
PIHOLE_DEVICES=$(echo "${DEVICES_JSON}" | jq -c '.devices[] | select(.hostname == "pihole" or (.name | test("pihole")) or ((.tags // []) | index("tag:pihole")))')

if [[ -z "${PIHOLE_DEVICES}" ]]; then
  echo "  [✓] No lingering Pi-hole ephemeral devices found on your tailnet."
  exit 0
fi

echo ""
echo "Found the following Pi-hole test nodes to purge:"
echo "--------------------------------------------------------------------------------"
printf "%-22s %-20s %-16s %-10s\n" "DEVICE ID" "NAME" "TAILNET IP" "LAST SEEN"
echo "--------------------------------------------------------------------------------"

DEVICE_IDS=()
while IFS= read -r dev; do
  [[ -z "${dev}" ]] && continue
  dev_id=$(echo "${dev}" | jq -r '.id')
  dev_name=$(echo "${dev}" | jq -r '.name')
  dev_ip=$(echo "${dev}" | jq -r '.addresses[0] // "N/A"')
  dev_seen=$(echo "${dev}" | jq -r '.lastSeen // "N/A"' | cut -c 1-19)
  printf "%-22s %-20s %-16s %-10s\n" "${dev_id}" "${dev_name}" "${dev_ip}" "${dev_seen}"
  DEVICE_IDS+=("${dev_id}")
done <<< "${PIHOLE_DEVICES}"

echo "--------------------------------------------------------------------------------"
echo ""

read -r -p "Purge all ${#DEVICE_IDS[@]} devices from Tailscale? [Y/n]: " choice
case "${choice:-y}" in
  [yY][eE][sS]|[yY]|"")
    for id in "${DEVICE_IDS[@]}"; do
      echo -n "Deleting device ${id}... "
      del_resp=$(curl -s -w "%{http_code}" -X DELETE "https://api.tailscale.com/api/v2/device/${id}" \
        -H "Authorization: Bearer ${TS_API_KEY}" -o /dev/null)
      if [[ "${del_resp}" == "200" || "${del_resp}" == "204" ]]; then
        echo "[DELETED]"
      else
        echo "[FAILED: HTTP ${del_resp}]"
      fi
    done
    echo ""
    echo "🎉 Cleanup complete! All test nodes purged from your tailnet."
    ;;
  *)
    echo "Cleanup cancelled."
    ;;
esac
