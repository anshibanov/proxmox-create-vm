#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Notification settings (optional)
NTFY="${NTFY:-}"

# Execute the cloudinit script and capture the exit code
"${SCRIPT_DIR}/proxmox-cloudinit.sh" \
    noble-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/noble/current \
    ubuntu-2404-cloudinit-template \
    9001
EXIT_CODE=$?

# Send notification if NTFY is configured
if [ -n "$NTFY" ]; then
    if [ $EXIT_CODE -eq 0 ]; then
        STATUS="Finished ubuntu processing"
        TAG="heavy_check_mark"
    else
        STATUS="Ubuntu processing failed with exit code $EXIT_CODE"
        TAG="x"
    fi

    # Collect hypervisor details
    HV_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    HV_EXTERNAL_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "n/a")
    HV_LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "n/a")
    HV_WG0_IP=$(ip -4 addr show wg0 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")

    HV_INFO="Hypervisor: ${HV_HOSTNAME}
External IP: ${HV_EXTERNAL_IP}
Local IP: ${HV_LOCAL_IP}"
    [ -n "$HV_WG0_IP" ] && HV_INFO="${HV_INFO}
WireGuard IP: ${HV_WG0_IP}"

    curl -s -H "X-Tags: $TAG" \
         -d "${STATUS}

${HV_INFO}" \
         "$NTFY" || true
fi

exit $EXIT_CODE
