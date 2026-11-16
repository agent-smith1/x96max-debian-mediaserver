#!/bin/bash
# setup-server.sh — автоматическая настройка сервера на Debian (Amlogic TV-box)
# Запускать от root: sudo bash setup-server.sh

set -euo pipefail

# ============ НАСТРОЙКИ (измените под себя) ============
HDD_UUID="${HDD_UUID:-}"                 # UUID раздела HDD (обязательно!)
HDD_MOUNT="/mnt/hdd"                     # точка монтирования
SMB_USER="${SMB_USER:-pi}"               # пользователь Samba (должен существовать в системе)
SMB_PASS="${SMB_PASS:-tvbox123}"         # пароль Samba
COMPOSE_DIR="${COMPOSE_DIR:-/root}"      # каталог с docker-compose.yml
SLSKD_USER="${SLSKD_USER:-}"             # логин Soulseek
SLSKD_PASS="${SLSKD_PASS:-}"             # пароль Soulseek
# =====================================================

if [[ -z "$HDD_UUID" ]]; then
    echo "ОШИБКА: задайте HDD_UUID (например: HDD_UUID=abcd-1234 sudo bash $0)"
    echo "UUID можно узнать командой: blkid"
    exit 1
fi

echo "=== [1/6] Монтирование HDD по UUID ==="
mkdir -p "$HDD_MOUNT"
if ! grep -q "$HDD_UUID" /etc/fstab; then
    echo "UUID=$HDD_UUID  $HDD_MOUNT  ext4  defaults  0  2" >> /etc/fstab
    echo "Добавлено в /etc/fstab"
else
    echo "Запись для UUID уже есть в /etc/fstab, пропускаем"
fi
mount -a

echo "=== [2/6] Установка Samba ==="
apt update
apt install -y samba

if ! id "$SMB_USER" &>/dev/null; then
    useradd -M -s /usr/sbin/nologin "$SMB_USER"
    echo "Создан системный пользователь $SMB_USER"
fi
(echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -a "$SMB_USER"

if ! grep -q '^\[HDD\]' /etc/samba/smb.conf; then
    cat >> /etc/samba/smb.conf <<EOF

[HDD]
   comment = 500GB Hard Drive
   path = $HDD_MOUNT
   read only = no
   guest ok = no
   valid users = $SMB_USER
EOF
    echo "Добавлен ресурс [HDD] в smb.conf"
fi

systemctl restart smbd
systemctl enable smbd

echo "=== [3/6] Установка Docker ==="
apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "=== [4/6] Создание docker-compose.yml ==="
mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_DIR/docker-compose.yml" <<YAML
version: "2.4"
services:
  gonic:
    image: sentriz/gonic:latest
    container_name: gonic
    environment:
      - GONIC_SCAN_INTERVAL=30
      - GONIC_SCAN_WATCHER_ENABLED=true
      - TZ=Europe/Moscow
    ports:
      - 4747:80
    volumes:
      - ./data:/data
      - $HDD_MOUNT/MUSIC:/music:ro
      - $HDD_MOUNT/gonic/cache:/cache
      - $HDD_MOUNT/gonic/podcasts:/podcasts
      - $HDD_MOUNT/gonic/playlists:/playlists
    group_add:
      - audio
    devices:
      - /dev/snd:/dev/snd
    restart: unless-stopped

  slskd:
    image: slskd/slskd:latest
    container_name: slskd
    restart: always
    ports:
      - 5030:5030
      - 5031:5031
      - 50300:50300
    environment:
      - SLSKD_REMOTE_CONFIGURATION=true
      - SLSKD_SLSK_USERNAME=$SLSKD_USER
      - SLSKD_SLSK_PASSWORD=$SLSKD_PASS
      - SLSKD_DOWNLOADS_DIR=/downloads
      - SLSKD_INCOMPLETE_DIR=/incomplete
    volumes:
      - $HDD_MOUNT/slskd-data:/app
      - $HDD_MOUNT/MUSIC/downloaded:/downloads
      - $HDD_MOUNT/slskd-data/incomplete:/incomplete

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: always
    ports:
      - 8096:8096
    volumes:
      - $HDD_MOUNT/jellyfin-config:/config
      - $HDD_MOUNT/jellyfin-cache:/cache
      - $HDD_MOUNT/movies:/movies:ro
    # devices:
    #   - /dev/dri:/dev/dri
YAML
echo "Создан $COMPOSE_DIR/docker-compose.yml"

echo "=== [5/6] Запуск сервисов ==="
cd "$COMPOSE_DIR"
docker compose up -d

echo "=== [6/6] Автозапуск через systemd ==="
cat > /etc/systemd/system/docker-compose-app.service <<UNIT
[Unit]
Description=Docker Compose Application Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$COMPOSE_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable docker-compose-app.service
systemctl start docker-compose-app.service

echo ""
echo "=== ГОТОВО ==="
echo "Samba:   smb://<IP-сервера>:445  (пользователь: $SMB_USER)"
echo "gonic:   http://<IP-сервера>:4747"
echo "slskd:   http://<IP-сервера>:5030"
echo "jellyfin: http://<IP-сервера>:8096"
