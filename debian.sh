#!/bin/bash

export NTFY="ntfy.sh/orange-proxmox-templates"

# Execute the cloudinit script and capture the exit code
./proxmox-cloudinit.sh debian-12-generic-amd64.qcow2 https://cdimage.debian.org/images/cloud/bookworm/latest debian-bookworm-template 9002
EXIT_CODE=$?

# Send the exit code using ntfy
if [ $EXIT_CODE -eq 0 ]; then
    STATUS="Finished debian processing"
    TAG="heavy_check_mark"
else
    STATUS="Debian processing failed with exit code $EXIT_CODE"
    TAG="x"
fi

curl -H "X-Tags: $TAG" \
     -d "$STATUS" \
     $NTFY
