# Proxmox Cloud-Init VM Template Creator

Automated scripts for creating Ubuntu, Debian, and AlmaLinux VM templates in Proxmox VE using Cloud-Init.

## Features

- Automatic cloud image download with parallel connections (aria2c)
- Pre-installation of useful packages (qemu-guest-agent, mc, htop, etc.)
- Multiple user creation with SSH key injection
- Passwordless sudo configuration
- Automatic storage detection (supports dir, LVM, LVMthin, ZFS)
- Optional static routes via cron
- Optional notifications via ntfy.sh

## Requirements

Install required packages on your Proxmox host:

```bash
apt update
apt install -y aria2 libguestfs-tools
```

## Quick Start

1. Clone the repository:
```bash
git clone https://github.com/youruser/proxmox-create-vm.git /opt/cloudinit
cd /opt/cloudinit
```

2. Create configuration:
```bash
cp .env.example .env
nano .env  # Edit with your settings
```

3. Add SSH public keys for users defined in USERS:
```bash
# For each user in USERS, create username.pub file
echo "ssh-rsa AAAA... user@host" > username.pub
```

4. Run the script:
```bash
# For Debian 12
./debian.sh

# For Ubuntu 24.04
./ubuntu.sh

# Or run manually with custom parameters
./proxmox-cloudinit.sh <image_name> <image_url> <vm_name> <vm_id>
```

## Configuration (.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `VMMEM` | 512 | VM memory in MB |
| `VMSETTINGS` | - | Additional VM settings (e.g., `--net0 virtio,bridge=vmbr0`) |
| `USERS` | - | Space-separated list of users to create |
| `CIUSER` | admin | Cloud-Init default user |
| `CIPASSWORD` | - | **Required.** Cloud-Init password |
| `ROUTES` | - | Semicolon-separated static routes |
| `NTFY` | - | ntfy.sh topic URL for notifications |

## Usage Examples

### Create Debian 12 template
```bash
./proxmox-cloudinit.sh \
    debian-12-generic-amd64.qcow2 \
    https://cdimage.debian.org/images/cloud/bookworm/latest \
    debian-12-template \
    9002
```

### Create Ubuntu 24.04 template
```bash
./proxmox-cloudinit.sh \
    noble-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/noble/current \
    ubuntu-2404-template \
    9001
```

### Create AlmaLinux 9 template
```bash
./proxmox-cloudinit.sh \
    AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 \
    https://repo.almalinux.org/almalinux/9/cloud/x86_64/images \
    almalinux-9-template \
    9003
```

## After Creating Template

1. Go to Proxmox Web UI
2. Right-click on the template VM
3. Select "Clone"
4. Choose "Full Clone" or "Linked Clone"
5. Configure Cloud-Init settings (IP, hostname, etc.)
6. Start the VM

## Static Routes

To configure persistent static routes, set the ROUTES variable:

```bash
ROUTES="192.168.2.0/24 via 192.168.20.5; 10.0.0.0/24 via 10.0.20.1"
```

Routes are applied via a cron job that runs every minute.

## Notifications

To receive notifications on completion, set up ntfy.sh:

```bash
NTFY="https://ntfy.sh/your-private-topic"
```

## Troubleshooting

### Storage not detected
The script automatically detects storage that supports VM images. If detection fails, ensure your storage has `content images` in `/etc/pve/storage.cfg`.

### virt-customize fails
Ensure libguestfs-tools is installed and the Proxmox host has enough memory for image manipulation.

### User has no SSH access
Ensure you have a `username.pub` file for each user defined in USERS.

## License

MIT
