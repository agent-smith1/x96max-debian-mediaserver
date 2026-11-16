# Гайд: Debian Linux на TV-приставке X96 Max Plus + домашний сервер

> Превращаем Amlogic-приставку в минималистичный сервер на Debian: SMB-шаринг HDD, Docker и медиасервисы (gonic, slskd, jellyfin).

**Источник образа:** https://github.com/devmfc/debian-on-amlogic

---

## 📋 Содержание

- [Часть 1. Подготовка носителя и загрузка в Linux](#часть-1-подготовка-носителя-и-загрузка-в-linux)
- [Часть 2. Подключение жёсткого диска](#часть-2-подключение-жёсткого-диска)
- [Часть 3. Samba — сетевой доступ к диску](#часть-3-samba--сетевой-доступ-к-диску)
- [Часть 4. Docker-сервисы](#часть-4-docker-сервисы)
- [Итоговая карта сервисов](#-итоговая-карта-сервисов)

---

## Часть 1. Подготовка носителя и загрузка в Linux

### Шаг 1. Скачиваем образ и пишем на USB/SD

1. Идём на страницу проекта: https://github.com/devmfc/debian-on-amlogic
2. Качаем образ Debian/Ubuntu для Amlogic.
3. Записываем образ на USB-флешку или SD-карту через **BalenaEtcher** (или Win32DiskImager / dd).

### Шаг 2. Правим `boot.config`

1. Открываем первый FAT-раздел накопителя.
2. В файле **`boot.config`** раскомментируем строку **`box=x96maxplus2`** (убираем `#` в начале строки).
3. Сохраняем файл.

> Строка `x96maxplus2` соответствует ревизии *X96 Max Plus 2* (S905X3, 1000M ethernet) из списка поддерживаемых устройств.

### Загружаемся в Linux

Вставляем накопитель в приставку, зажимаем кнопку reset/update (обычно спрятана в AV-порту), включаем питание и держим кнопку ~7 секунд.

**Альтернатива для рутованного Android:**

```bash
adb connect <box-ip>
adb shell
su root
reboot update
```

### Первый вход и базовая настройка

1. Подключаемся по SSH или через консоль (при первом запуске генерация ключей может занять пару минут).
2. Логинимся под дефолтными данными дистрибутива.
3. Меняем пароль по умолчанию, обновляем систему и настраиваем автозагрузку с USB/SD (если нужно):

```bash
passwd
apt update && apt upgrade -y
# Опционально: запись мультибута, чтобы не зажимать reset при каждой перезагрузке
./aml-multiboot-setup.sh
```

---

## Часть 2. Подключение жёсткого диска

### Шаг 1. Ищем диск и его UUID

Подключаем внешний HDD/SSD к USB-порту приставки и определяем его идентификатор:

```bash
lsblk -f
```

Копируем `UUID` и тип файловой системы (`TYPE`, например `ext4` или `ntfs`) нужного раздела.

### Шаг 2. Настраиваем автомонтирование в `/etc/fstab`

Создаём точку монтирования и добавляем диск в автозагрузку:

```bash
mkdir -p /mnt/hdd
nano /etc/fstab
```

Дописываем в конец файла строку (подставив свой `UUID` и тип ФС):

```text
UUID=ВАШ-UUID-ДИСКА  /mnt/hdd  ext4  defaults,nofail,noatime  0  2
```

> [!NOTE]
> Параметр `nofail` обязателен — без него система не загрузится, если диск будет отключён.

Применяем настройки и проверяем монтирование:

```bash
mount -a
df -h /mnt/hdd
```

Создаём базовую структуру папок для медиа и данных:

```bash
mkdir -p /mnt/hdd/{media/music,media/movies,media/shows,downloads,docker}
```

---

## Часть 3. Samba — сетевой доступ к диску

### Шаг 1. Ставим Samba

```bash
apt install -y samba
```

### Шаг 2. Настраиваем шару

Открываем конфигурационный файл:

```bash
nano /etc/samba/smb.conf
```

Добавляем в самый низ файла секцию для общего доступа к диску:

```ini
[HDD]
   path = /mnt/hdd
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0664
   directory mask = 0775
```

### Шаг 3. Задаём пароль и перезапускаем

Задаём пароль для доступа по SMB и перезапускаем службу:

```bash
smbpasswd -a <имя пользователя>
systemctl restart smbd
```

Теперь диск доступен в локальной сети по адресу `\\<IP-приставки>\HDD` (Windows) или `smb://<IP-приставки>/HDD` (macOS/Linux).

---

## Часть 4. Docker-сервисы

### Шаг 1. Ставим Docker и Docker Compose

```bash
curl -fsSL https://docker.com | sh
```

### Шаг 2. Создаём `docker-compose.yml`

Вставляем конфигурацию для **gonic** (музыкальный Subsonic-сервер), **slskd** (клиент Soulseek) и **jellyfin** (медиасервер):

```yaml
services:
  gonic:
    image: sentriz/gonic:latest
    container_name: gonic
    restart: unless-stopped
    environment:
      - TZ=Europe/Moscow
    ports:
      - "4747:80"
    volumes:
      - ./gonic/data:/data
      - /mnt/hdd/media/music:/music:ro
      - ./gonic/podcasts:/podcasts
      - ./gonic/playlists:/playlists

  slskd:
    image: slskd/slskd:latest
    container_name: slskd
    restart: unless-stopped
    environment:
      - SLSKD_REMOTE_CONFIGURATION=true
    ports:
      - "5030:5030"
      - "5031:5031"
      - "50300:50300"
    volumes:
      - ./slskd:/app
      - /mnt/hdd/downloads:/downloads
      - /mnt/hdd/media/music:/music:ro

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      - TZ=Europe/Moscow
    ports:
      - "8096:8096"
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - /mnt/hdd/media:/media:ro
```

### Шаг 3. Запускаем контейнеры

```bash
docker compose up -d
```

---

## 🗺️ Итоговая карта сервисов

| Сервис | Назначение | Порт | Адрес доступа |
| :--- | :--- | :--- | :--- |
| **SSH** | Управление сервером | `22` | `ssh root@<IP-приставки>` |
| **Samba (SMB)** | Сетевой доступ к HDD | `445` | `\\<IP-приставки>\HDD` |
| **Gonic** | Музыкальный стриминг (Subsonic API) | `4747` | `http://<IP-приставки>:4747` |
| **slskd** | Веб-клиент Soulseek для загрузки музыки | `5030` | `http://<IP-приставки>:5030` |
| **Jellyfin** | Медиасервер (фильмы, сериалы, музыка) | `8096` | `http://<IP-приставки>:8096` |

---
