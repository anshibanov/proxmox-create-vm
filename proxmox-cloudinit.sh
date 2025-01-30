#!/bin/bash
#
# Скрипт для создания шаблона Ubuntu/Debian/AlmaLinux Cloud-Init VM в Proxmox
# Использует данные из .env, а также требует 4 аргумента:
#   1) <image_name> - имя файла образа (например, ubuntu-20.04.img)
#   2) <image_url>  - URL каталога, где лежит образ (например, https://cloud-images.ubuntu.com/focal/current)
#   3) <vm_name>    - имя для создаваемой VM (например, ubuntu-20.04-template)
#   4) <vm_id>      - ID для Proxmox (например, 9001)
#
# Пример запуска:
#   ./create_vm_template.sh ubuntu-20.04.img https://cloud-images.ubuntu.com/focal/current ubuntu-20.04-template 9001

###############################################################################
# Общие настройки
# Выходим из скрипта, если какая-либо команда вернула ошибку (set -e),
# при обращении к неинициализированной переменной (set -u),
# и если ошибка в конвейере (set -o pipefail) -x для отладки

set -euox pipefail  # -e, -u, -o pipefail и 

###############################################################################
# 1. Чтение .env и преобразование некоторых переменных

if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
else
    echo "Error: .env file not found!"
    exit 1
fi

# Преобразуем USERS и KEYS в массивы (если нужно)
IFS=' ' read -r -a USERS_ARRAY <<< "${USERS:-}"
IFS=' ' read -r -a KEYS_ARRAY <<< "${KEYS:-}"

###############################################################################
# 2. Проверка наличия необходимых инструментов

for cmd in aria2c virt-customize qm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' not found, install it before running this script."; exit 1; }
done

###############################################################################
# 3. Парсим аргументы

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <image_name> <image_url> <vm_name> <vm_id>"
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
# 4. Загрузка образа (image) во временный файл

aria2c --allow-overwrite=true \
       --auto-file-renaming=false \
       --summary-interval=360 \
       -x 6 \
       -o "${TEMPIMAGE}" \
       "${IMAGEURL}/${IMAGENAME}"

###############################################################################
# 5. Дополнительные настройки на основе дистрибутива

imagelower=$(echo "$IMAGENAME" | tr '[:upper:]' '[:lower:]')

# Дефолт для Ubuntu/Debian
PACKAGES="qemu-guest-agent,mc,cron,avahi-daemon,htop"
SUDOGROUP="sudo"

# Если в имени образа (или URL) встречается ubuntu/debian
if [[ "$imagelower" == *"ubuntu"* || "$imagelower" == *"debian"* || "$IMAGEURL" == *"ubuntu"* ]]; then
  PACKAGES="qemu-guest-agent,mc,cron,avahi-daemon,htop"
  SUDOGROUP="sudo"
fi

# Если в имени образа есть alma/red (AlmaLinux, Red Hat и т.п.)
if [[ "$imagelower" == *"alma"* || "$imagelower" == *"red"* ]]; then
  PACKAGES="qemu-guest-agent,mc,avahi-tools"
  SUDOGROUP="wheel"
  VMMEM=1024
  CIUSER="almalinux"
fi

###############################################################################
# 6. Кастомизация образа через virt-customize

# Устанавливаем пакеты
virt-customize -a "${TEMPIMAGE}" --install "${PACKAGES}"

# Включаем qemu-guest-agent
virt-customize -a "${TEMPIMAGE}" --run-command 'systemctl enable qemu-guest-agent'

###############################################################################
# 7. Скрипт для регистрации в Consul и cron

cat > /tmp/register_service.sh << 'EOF'
#!/bin/bash
LOCAL_IP=$(hostname -I | awk '{print $1}')
XHOSTNAME=$(hostname)
curl -H "Content-Type: application/json" -X PUT -d "{\"ID\": \"$XHOSTNAME\",\"Name\": \"$XHOSTNAME\", \"Address\": \"$LOCAL_IP\"}" http://consul.lan:8500/v1/agent/service/register
EOF

chmod +x /tmp/register_service.sh

virt-customize -a "${TEMPIMAGE}" --copy-in /tmp/register_service.sh:/usr/local/bin/

echo "* * * * * root /usr/local/bin/register_service.sh" > /tmp/cronjob
virt-customize -a "${TEMPIMAGE}" --copy-in /tmp/cronjob:/etc/cron.d/

###############################################################################
# 8. Создание пользователей и вставка SSH-ключей

for USER in "${USERS_ARRAY[@]}"; do
    virt-customize -a "${TEMPIMAGE}" \
        --run-command "useradd -m -d /home/${USER} -s /bin/bash -G ${SUDOGROUP} ${USER}"

    virt-customize -a "${TEMPIMAGE}" \
        --run-command "mkdir -p /home/${USER}/.ssh"

    if [ -f "${USER}.pub" ]; then
        virt-customize -a "${TEMPIMAGE}" --ssh-inject "${USER}:file:${USER}.pub"
    fi

    # Если нужно несколько ключей (из массива KEYS_ARRAY), можно раскомментировать:
    # for KEY in "${KEYS_ARRAY[@]}"; do
    #   if [ -f "${KEY}" ]; then
    #     virt-customize -a "${TEMPIMAGE}" --ssh-inject "${USER}:file:${KEY}"
    #   fi
    # done

    virt-customize -a "${TEMPIMAGE}" \
        --run-command "chown -R ${USER}:${USER} /home/${USER}"
done

###############################################################################
# 9. Настройка sudo без пароля

echo "%${SUDOGROUP} ALL=(ALL) NOPASSWD:ALL" > /tmp/sudoers-nopasswd
virt-customize -a "${TEMPIMAGE}" \
    --copy-in /tmp/sudoers-nopasswd:/etc/sudoers.d/

###############################################################################
# 10. Отключаем парольную аутентификацию в SSH

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/g" /etc/ssh/sshd_config'

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/g" /etc/ssh/sshd_config'

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin no/g" /etc/ssh/sshd_config'

###############################################################################
# 11. Конфигурация постоянных маршрутов через systemd-networkd

if [[ -n "${ROUTES:-}" ]]; then
  echo "Добавляем постоянные маршруты из .env через systemd-networkd..."

  # 11.1. Определяем имя сетевого интерфейса
  INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
  if [[ -z "$INTERFACE" ]]; then
      echo "Error: Не удалось определить сетевой интерфейс."
      exit 1
  fi

  # 11.2. Создаем drop-in конфигурацию маршрутов
  ROUTES_FILE="/etc/systemd/network/10-static-routes.network"
  cat > /tmp/10-static-routes.network <<EOF
[Match]
Name=$INTERFACE

[Network]
EOF

  # Парсим маршруты из переменной ROUTES
  while IFS= read -r route; do
      DEST=$(echo "$route" | awk '{print $3}')
      GATEWAY=$(echo "$route" | awk '{print $6}')
      echo "[Route]" >> /tmp/10-static-routes.network
      echo "Destination=${DEST}" >> /tmp/10-static-routes.network
      echo "Gateway=${GATEWAY}" >> /tmp/10-static-routes.network
      echo "" >> /tmp/10-static-routes.network
  done <<< "$ROUTES"

  # Копируем конфиг-файл в образ
  virt-customize -a "${TEMPIMAGE}" \
      --copy-in /tmp/10-static-routes.network:/etc/systemd/network/

  # Перезапускаем systemd-networkd
  virt-customize -a "${TEMPIMAGE}" \
      --run-command 'systemctl enable systemd-networkd && systemctl restart systemd-networkd'
else
  echo "Переменная ROUTES не задана, пропускаем настройку постоянных маршрутов."
fi


###############################################################################
# 12. Удаляем machine-id (рекомендуется для Cloud-Init шаблонов)

virt-customize -a "${TEMPIMAGE}" \
    --run-command 'truncate -s 0 /etc/machine-id'

###############################################################################
# 13. Удаляем/чистим старую VM в Proxmox (если была)

qm destroy "${VMID}" --destroy-unreferenced-disks 1 --purge 1 || true

###############################################################################
# 14. Создаём новую VM и импортируем диск

qm create "${VMID}" --name "${VMNAME}" --memory "${VMMEM}" ${VMSETTINGS}
qm set   "${VMID}" --description "Template date: ${CURRENT_DATE}"
qm set   "${VMID}" --cpu host

qm importdisk "${VMID}" "${TEMPIMAGE}" "${STORAGE}"

# Привязываем диск к SCSI
qm set "${VMID}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

qm set "${VMID}" --ide2 "${STORAGE}:cloudinit"
qm set "${VMID}" --boot c --bootdisk scsi0

# Cloud-Init опции (пользователь, пароль, DHCP и т.д.)
qm set "${VMID}" --ciuser="${CIUSER}" --cipassword="${CIPASSWORD}"
qm set "${VMID}" --ipconfig0 ip=dhcp
qm set "${VMID}" --agent 1
qm set "${VMID}" --serial0 socket --vga std

# Обновляем cloudinit
qm cloudinit update "${VMID}"

###############################################################################
# 15. Преобразуем VM в шаблон

qm template "${VMID}"

###############################################################################
# 16. Удаляем старый образ и переименовываем временный

rm -f "${IMAGENAME}"
mv "${TEMPIMAGE}" "${IMAGENAME}"

###############################################################################
# 17. Логируем время последнего запуска

echo "Last run: ${CURRENT_DATE}" > "${BASENAME}-last-run.txt"

###############################################################################
# 18. Финальное сообщение

echo "TEMPLATE ${VMNAME} (ID ${VMID}) successfully created!"
echo "Now create a clone of this VM in the Proxmox Webinterface (or via CLI)."
