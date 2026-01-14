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

    curl -s -H "X-Tags: $TAG" \
         -d "$STATUS" \
         "$NTFY" || true
fi

exit $EXIT_CODE
