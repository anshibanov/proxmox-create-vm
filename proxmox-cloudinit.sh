#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#
# Скрипт для создания шаблона Ubuntu/Debian/AlmaLinux Cloud-Init VM в Proxmox

###############################################################################
# Общие настройки
set -euox pipefail

###############################################################################
# 1. Чтение .env

if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
else
    echo "Error: .env file not found!" >&2
    exit 1
fi

# Преобразуем USERS и KEYS в массивы
IFS=' ' read -r -a USERS_ARRAY <<< "${USERS:-}"
IFS=' ' read -r -a KEYS_ARRAY <<< "${KEYS:-}"

###############################################################################
# 2. Функция для определения подходящего storage

detect_storage() {
    local storage_name=""
    local storage_type=""
    
    echo "Detecting suitable storage for VM images..." >&2
    
    # Получаем список storage, которые поддерживают content type 'images'
    while IFS= read -r line; do
        # Пропускаем строки с ошибками и заголовок
        if [[ "$line" =~ ^(Name|storage) ]] || [[ -z "$line" ]]; then
            continue
        fi
        
        # Парсим первое слово (имя storage) и второе (тип)
        storage_name=$(echo "$line" | awk '{print $1}')
        storage_type=$(echo "$line" | awk '{print $2}')
        storage_status=$(echo "$line" | awk '{print $3}')
        
        # Проверяем, что storage активен
        if [[ "$storage_status" == "active" ]]; then
            echo "Found suitable storage: $storage_name (type: $storage_type)" >&2
            echo "$storage_name:$storage_type"
            return 0
        fi
    done < <(pvesm status -content images 2>/dev/null | tail -n +2)
    
    # Если ничего не найдено, пробуем без фильтра и ищем вручную
    echo "Warning: No active storage found via pvesm status." >&2
    echo "Attempting to parse /etc/pve/storage.cfg..." >&2
    
    # Парсим storage.cfg напрямую
    local current_storage=""
    local has_images=0
    
    while IFS= read -r line; do
        # Начало нового storage
        if [[ "$line" =~ ^(dir|lvmthin|lvm|zfspool|nfs|cifs|rbd|cephfs|btrfs|iscsi):\ (.+)$ ]]; then
            # Если предыдущий storage поддерживал images, возвращаем его
            if [[ $has_images -eq 1 ]] && [[ -n "$current_storage" ]]; then
                echo "$current_storage:$storage_type"
                return 0
            fi
            
            storage_type="${BASH_REMATCH[1]}"
            current_storage="${BASH_REMATCH[2]}"
            has_images=0
        fi
        
        # Проверяем content
        if [[ "$line" =~ content.*images ]]; then
            has_images=1
        fi
    done < /etc/pve/storage.cfg
    
    # Проверяем последний storage
    if [[ $has_images -eq 1 ]] && [[ -n "$current_storage" ]]; then
        echo "$current_storage:$storage_type"
        return 0
    fi
    
    echo "Error: No suitable storage found for VM images!" >&2
    exit 1
}

###############################################################################
# 3. Проверка наличия необходимых инструментов

for cmd in aria2c virt-customize qm; do
  command -v "$cmd" >/dev/null 2>&1 || { 
    echo "Error: '$cmd' not found, install it before running this script." >&2
    exit 1
  }
done

###############################################################################
# 4. Парсим аргументы

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <image_name> <image_url> <vm_name> <vm_id>" >&2
    exit 1
fi

IMAGENAME=$1
IMAGEURL=$2
VMNAME=$3
VMID=$4

BASENAME="${IMAGENAME%.*}"
CURRENT_DATE=$(date +"%Y%m%d-%H%M%S")
TEMPIMAGE="${IMAGENAME}.new"

###############################################################################
# 5. Определяем подходящий storage

STORAGE_INFO=$(detect_storage)
STORAGE=$(echo "$STORAGE_INFO" | cut -d: -f1)
STORAGE_TYPE=$(echo "$STORAGE_INFO" | cut -d: -f2)

echo "Using storage: $STORAGE (type: $STORAGE_TYPE)" >&2

###############################################################################
# 6. Загрузка образа

aria2c --allow-overwrite=true \
       --auto-file-renaming=false \
       --summary-interval=360 \
       -x 6 \
       -o "${TEMPIMAGE}" \
       "${IMAGEURL}/${IMAGENAME}"

###############################################################################
# 7. Дополнительные настройки на основе дистрибутива

imagelower=$(echo "$IMAGENAME" | tr '[:upper:]' '[:lower:]')

# Дефолт для Ubuntu/Debian
PACKAGES="qemu-guest-agent,mc,cron,avahi-daemon,htop"
SUDOGROUP="sudo"

if [[ "$imagelower" == *"ubuntu"* || "$imagelower" == *"debian"* || "$IMAGEURL" == *"ubuntu"* ]]; then
  PACKAGES="qemu-guest-agent,mc,cron,avahi-daemon,htop"
  SUDOGROUP="sudo"
fi

if [[ "$imagelower" == *"alma"* || "$imagelower" == *"red"* ]]; then
  PACKAGES="qemu-guest-agent,mc,avahi-tools"
  SUDOGROUP="wheel"
  VMMEM=1024
  CIUSER="almalinux"
fi

###############################################################################
# 8. Кастомизация образа через virt-customize

virt-customize -a "${TEMPIMAGE}" --install "${PACKAGES}"
virt-customize -a "${TEMPIMAGE}" --run-command 'systemctl enable qemu-guest-agent'

###############################################################################
# 9. Создание пользователей и вставка SSH-ключей

for USER in "${USERS_ARRAY[@]}"; do
    virt-customize -a "${TEMPIMAGE}" \
        --run-command "useradd -m -d /home/${USER} -s /bin/bash -G ${SUDOGROUP} ${USER}"

    virt-customize -a "${TEMPIMAGE}" \
        --run-command "mkdir -p /home/${USER}/.ssh"

    if [ -f "${USER}.pub" ]; then
        virt-customize -a "${TEMPIMAGE}" --ssh-inject "${USER}:file:${USER}.pub"
    fi

    virt-customize -a "${TEMPIMAGE}" \
        --run-command "chown -R ${USER}:${USER} /home/${USER}"
done

###############################################################################
# 10. Настройка sudo без пароля

echo "%${SUDOGROUP} ALL=(ALL) NOPASSWD:ALL" > /tmp/sudoers-nopasswd
virt-customize -a "${TEMPIMAGE}" \
    --copy-in /tmp/sudoers-nopasswd:/etc/sudoers.d/

###############################################################################
# 11. Отключаем парольную аутентификацию в SSH

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/g" /etc/ssh/sshd_config'

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/g" /etc/ssh/sshd_config'

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin no/g" /etc/ssh/sshd_config'

###############################################################################
# 12. Настройка постоянных маршрутов через cron-задачу

if [ -n "${ROUTES:-}" ]; then
    echo "Configuring static routes via cron job" >&2

    cat << 'EOF' > /tmp/ensure_routes.sh
#!/bin/bash
declare -a ROUTES=(
EOF

    for route in "${ROUTES[@]}"; do
        echo "\"$route\"" >> /tmp/ensure_routes.sh
    done

    cat << 'EOF' >> /tmp/ensure_routes.sh
)

for route in "${ROUTES[@]}"; do
  if ! ip route show | grep -q "$route"; then
    ip route add $route
  fi
done
EOF

    chmod +x /tmp/ensure_routes.sh
    virt-customize -a "${TEMPIMAGE}" --copy-in /tmp/ensure_routes.sh:/usr/local/bin/
    virt-customize -a "${TEMPIMAGE}" \
      --run-command 'chown root:root /usr/local/bin/ensure_routes.sh && chmod 755 /usr/local/bin/ensure_routes.sh'

    echo "* * * * * root /usr/local/bin/ensure_routes.sh" > /tmp/cronjob
    virt-customize -a "${TEMPIMAGE}" --copy-in /tmp/cronjob:/etc/cron.d/
    virt-customize -a "${TEMPIMAGE}" \
      --run-command 'chown root:root /etc/cron.d/cronjob && chmod 644 /etc/cron.d/cronjob'
fi

###############################################################################
# 13. Удаляем machine-id

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'truncate -s 0 /etc/machine-id'

###############################################################################
# 14. Удаляем старую VM в Proxmox (если была)

qm destroy "${VMID}" --destroy-unreferenced-disks 1 --purge 1 || true

###############################################################################
# 15. Создаём новую VM и импортируем диск

qm create "${VMID}" --name "${VMNAME}" --memory "${VMMEM}" ${VMSETTINGS}
qm set   "${VMID}" --description "Template date: ${CURRENT_DATE}"
qm set   "${VMID}" --cpu host

# Импортируем диск в указанный datastore
qm importdisk "${VMID}" "${TEMPIMAGE}" "${STORAGE}"

# Привязываем диск к SCSI
# Формат зависит от типа storage
case "$STORAGE_TYPE" in
    dir)
        # Для Directory storage: storage:VMID/vm-VMID-disk-0.raw
        qm set "${VMID}" \
            --scsihw virtio-scsi-pci \
            --scsi0 "${STORAGE}:${VMID}/vm-${VMID}-disk-0.raw"
        ;;
    lvmthin|lvm)
        # Для LVM/LVMthin storage: storage:vm-VMID-disk-0
        qm set "${VMID}" \
            --scsihw virtio-scsi-pci \
            --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
        ;;
    zfspool)
        # Для ZFS storage: storage:vm-VMID-disk-0
        qm set "${VMID}" \
            --scsihw virtio-scsi-pci \
            --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
        ;;
    *)
        # Универсальный вариант - пытаемся определить автоматически
        echo "Unknown storage type: $STORAGE_TYPE. Attempting automatic detection..." >&2
        qm set "${VMID}" \
            --scsihw virtio-scsi-pci \
            --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
        ;;
esac

qm set "${VMID}" --ide2 "${STORAGE}:cloudinit"
qm set "${VMID}" --boot c --bootdisk scsi0

# Cloud-Init опции
qm set "${VMID}" --ciuser="${CIUSER}" --cipassword="${CIPASSWORD}"
qm set "${VMID}" --ipconfig0 ip=dhcp
qm set "${VMID}" --agent 1
qm set "${VMID}" --serial0 socket --vga std

# Обновляем cloudinit
qm cloudinit update "${VMID}"

###############################################################################
# 16. Преобразуем VM в шаблон

qm template "${VMID}"

###############################################################################
# 17. Удаляем старый образ и переименовываем временный

rm -f "${IMAGENAME}"
mv "${TEMPIMAGE}" "${IMAGENAME}"

###############################################################################
# 18. Логируем время последнего запуска

echo "Last run: ${CURRENT_DATE}" > "${BASENAME}-last-run.txt"

###############################################################################
# 19. Финальное сообщение

echo "==========================================" >&2
echo "TEMPLATE CREATED SUCCESSFULLY!" >&2
echo "==========================================" >&2
echo "VM Name:    ${VMNAME}" >&2
echo "VM ID:      ${VMID}" >&2
echo "Storage:    ${STORAGE} (${STORAGE_TYPE})" >&2
echo "Date:       ${CURRENT_DATE}" >&2
echo "==========================================" >&2
echo "Now create a clone of this VM in the Proxmox Webinterface (or via CLI)." >&2
