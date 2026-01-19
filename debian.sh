#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Notification settings (optional)
NTFY="${NTFY:-}"

# Execute the cloudinit script and capture the exit code
"${SCRIPT_DIR}/proxmox-cloudinit.sh" \
    debian-12-generic-amd64.qcow2 \
    https://cdimage.debian.org/images/cloud/bookworm/latest \
    debian-bookworm-template \
    9002
EXIT_CODE=$?

# Send notification if NTFY is configured
if [ -n "$NTFY" ]; then
    if [ $EXIT_CODE -eq 0 ]; then
        STATUS="Finished debian processing"
        TAG="heavy_check_mark"
    else
        STATUS="Debian processing failed with exit code $EXIT_CODE"
        TAG="x"
    fi

    curl -s -H "X-Tags: $TAG" \
         -d "$STATUS" \
         "$NTFY" || true
fi

exit $EXIT_CODE
