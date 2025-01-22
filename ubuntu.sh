#!/bin/bash

export NTFY="ntfy.sh/orange-proxmox-templates"

# Execute the cloudinit script and capture the exit code
/opt/cloudinit/proxmox-cloudinit.sh noble-server-cloudimg-amd64.img https://cloud-images.ubuntu.com/noble/current ubuntu-2404-cloudinit-template 9001
EXIT_CODE=$?

# Send the exit code using ntfy
if [ $EXIT_CODE -eq 0 ]; then
    STATUS="Finished ubuntu processing"
    TAG="heavy_check_mark"
else
    STATUS="Ubuntu processing failed with exit code $EXIT_CODE"
    TAG="x"
fi

curl -H "X-Tags: $TAG" \
     -d "$STATUS" \
     $NTFY
