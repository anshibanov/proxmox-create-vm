#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#
# Скрипт для создания шаблона Ubuntu/Debian/AlmaLinux Cloud-Init VM в Proxmox

###############################################################################
# Общие настройки
set -euox pipefail

# Создаём временную директорию для безопасной работы с временными файлами
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

###############################################################################
# 1. Чтение .env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
elif [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
else
    echo "Error: .env file not found!" >&2
    exit 1
fi

# Преобразуем USERS в массив
IFS=' ' read -r -a USERS_ARRAY <<< "${USERS:-}"

# Значения по умолчанию для критических переменных
VMMEM="${VMMEM:-512}"
CIUSER="${CIUSER:-admin}"
CIPASSWORD="${CIPASSWORD:-}"
VMSETTINGS="${VMSETTINGS:-}"

# Проверка обязательных переменных
if [ -z "$CIPASSWORD" ]; then
    echo "Error: CIPASSWORD must be set in .env" >&2
    exit 1
fi

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
# 4. Парсим и валидируем аргументы

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <image_name> <image_url> <vm_name> <vm_id>" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  image_name  - Name of the cloud image file (e.g., debian-12-generic-amd64.qcow2)" >&2
    echo "  image_url   - Base URL to download the image from" >&2
    echo "  vm_name     - Name for the VM template" >&2
    echo "  vm_id       - Numeric VM ID (must be >= 100)" >&2
    exit 1
fi

IMAGENAME=$1
IMAGEURL=$2
VMNAME=$3
VMID=$4

# Валидация VMID
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    echo "Error: VMID must be a positive integer, got: $VMID" >&2
    exit 1
fi

if [ "$VMID" -lt 100 ]; then
    echo "Error: VMID must be >= 100 (Proxmox reserves 0-99), got: $VMID" >&2
    exit 1
fi

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

# Дефолтные значения (Ubuntu/Debian)
PACKAGES="qemu-guest-agent,mc,cron,avahi-daemon,htop"
SUDOGROUP="sudo"

# Специфичные настройки для AlmaLinux/RHEL
if [[ "$imagelower" == *"alma"* || "$imagelower" == *"red"* ]]; then
    PACKAGES="qemu-guest-agent,mc,avahi-tools"
    SUDOGROUP="wheel"
fi

###############################################################################
# 8. Подготовка команд для virt-customize

VIRT_COMMANDS=()

# Установка пакетов
VIRT_COMMANDS+=("--install" "${PACKAGES}")

# Включение qemu-guest-agent
VIRT_COMMANDS+=("--run-command" "systemctl enable qemu-guest-agent")

###############################################################################
# 9. Создание пользователей и вставка SSH-ключей

for USER in "${USERS_ARRAY[@]}"; do
    # Создание пользователя
    VIRT_COMMANDS+=("--run-command" "useradd -m -d /home/${USER} -s /bin/bash -G ${SUDOGROUP} ${USER} || true")

    # Создание директории .ssh
    VIRT_COMMANDS+=("--run-command" "mkdir -p /home/${USER}/.ssh")

    # Проверяем наличие публичного ключа
    if [ -f "${SCRIPT_DIR}/${USER}.pub" ]; then
        VIRT_COMMANDS+=("--ssh-inject" "${USER}:file:${SCRIPT_DIR}/${USER}.pub")
    elif [ -f "${USER}.pub" ]; then
        VIRT_COMMANDS+=("--ssh-inject" "${USER}:file:${USER}.pub")
    else
        echo "Warning: SSH key file '${USER}.pub' not found, user '${USER}' will have no SSH access" >&2
    fi

    # Установка правильных прав
    VIRT_COMMANDS+=("--run-command" "chown -R ${USER}:${USER} /home/${USER}")
done

###############################################################################
# 10. Настройка sudo без пароля

SUDOERS_FILE="${TMPDIR}/sudoers-nopasswd"
echo "%${SUDOGROUP} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

VIRT_COMMANDS+=("--copy-in" "${SUDOERS_FILE}:/etc/sudoers.d/")
VIRT_COMMANDS+=("--run-command" "chmod 440 /etc/sudoers.d/sudoers-nopasswd")

###############################################################################
# 11. Отключаем парольную аутентификацию в SSH

VIRT_COMMANDS+=("--run-command" 'sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/g" /etc/ssh/sshd_config')
VIRT_COMMANDS+=("--run-command" 'sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/g" /etc/ssh/sshd_config')
VIRT_COMMANDS+=("--run-command" 'sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin no/g" /etc/ssh/sshd_config')

###############################################################################
# 12. Настройка постоянных маршрутов через cron-задачу

if [ -n "${ROUTES:-}" ]; then
    echo "Configuring static routes via cron job" >&2

    ROUTES_SCRIPT="${TMPDIR}/ensure_routes.sh"
    cat << 'EOF' > "$ROUTES_SCRIPT"
#!/bin/bash
declare -a ROUTES=(
EOF

    # Обработка ROUTES как строки с разделителем или массива
    if declare -p ROUTES 2>/dev/null | grep -q 'declare -a'; then
        # ROUTES это массив
        for route in "${ROUTES[@]}"; do
            echo "\"$route\"" >> "$ROUTES_SCRIPT"
        done
    else
        # ROUTES это строка - разбиваем по точке с запятой
        IFS=';' read -r -a ROUTES_TMP <<< "$ROUTES"
        for route in "${ROUTES_TMP[@]}"; do
            route=$(echo "$route" | xargs)  # trim whitespace
            [ -n "$route" ] && echo "\"$route\"" >> "$ROUTES_SCRIPT"
        done
    fi

    cat << 'EOF' >> "$ROUTES_SCRIPT"
)

for route in "${ROUTES[@]}"; do
  if ! ip route show | grep -q "$route"; then
    ip route add $route
  fi
done
EOF

    chmod +x "$ROUTES_SCRIPT"

    VIRT_COMMANDS+=("--copy-in" "${ROUTES_SCRIPT}:/usr/local/bin/")
    VIRT_COMMANDS+=("--run-command" "chown root:root /usr/local/bin/ensure_routes.sh && chmod 755 /usr/local/bin/ensure_routes.sh")

    CRON_FILE="${TMPDIR}/ensure-routes"
    echo "* * * * * root /usr/local/bin/ensure_routes.sh" > "$CRON_FILE"

    VIRT_COMMANDS+=("--copy-in" "${CRON_FILE}:/etc/cron.d/")
    VIRT_COMMANDS+=("--run-command" "chown root:root /etc/cron.d/ensure-routes && chmod 644 /etc/cron.d/ensure-routes")
fi

###############################################################################
# 13. Очищаем machine-id и SSH host keys для уникальности клонов

VIRT_COMMANDS+=("--run-command" "truncate -s 0 /etc/machine-id")
VIRT_COMMANDS+=("--run-command" "rm -f /var/lib/dbus/machine-id")
VIRT_COMMANDS+=("--run-command" "rm -f /etc/ssh/ssh_host_*")

###############################################################################
# 14. Выполняем все команды virt-customize за один раз (оптимизация)

echo "Customizing image with ${#VIRT_COMMANDS[@]} operations..." >&2
virt-customize -a "${TEMPIMAGE}" "${VIRT_COMMANDS[@]}"

###############################################################################
# 15. Удаляем старую VM в Proxmox (если была)

qm destroy "${VMID}" --destroy-unreferenced-disks 1 --purge 1 || true

###############################################################################
# 16. Создаём новую VM и импортируем диск

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
# 17. Преобразуем VM в шаблон

qm template "${VMID}"

###############################################################################
# 18. Удаляем старый образ и переименовываем временный

rm -f "${IMAGENAME}"
mv "${TEMPIMAGE}" "${IMAGENAME}"

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
