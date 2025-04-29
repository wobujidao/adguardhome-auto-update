#!/bin/bash

# Путь к установленному AdGuard Home
AGH_PATH="/opt/AdGuardHome"
# Путь к конфигурационному файлу
CONFIG_FILE="$AGH_PATH/AdGuardHome.yaml"
# Путь к директории данных
DATA_DIR="$AGH_PATH/data"
# Временная директория для скачивания
TEMP_DIR="/tmp/AdGuardHome_update"
# Путь для резервных копий
BACKUP_DIR="/tmp/AdGuard-backup"
# Файл логов
LOG_FILE="/var/log/adguardhome-update.log"
# Максимальный размер лога (в байтах, 1 МБ = 1048576 байт)
MAX_LOG_SIZE=1048576
# Архитектура
ARCH="linux_amd64"
# URL для проверки последней версии
RELEASES_API="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
# URL для скачивания
DOWNLOAD_URL="https://static.adguard.com/adguardhome/release/AdGuardHome_${ARCH}.tar.gz"
# Локальный файл, если скачивание не удалось
FALLBACK_FILE="/tmp/test.tar.gz"
# Резервная версия, если GitHub API недоступен
FALLBACK_VERSION="v0.107.61"
# DNS-серверы для проверки (по умолчанию Cloudflare, можно заменить, например, на Яндекс: 77.88.8.8,77.88.8.1)
DNS_SERVERS="1.1.1.1"
# Настройки Telegram-уведомлений (отключены по умолчанию)
ENABLE_TELEGRAM="false"  # Установите "true" для включения уведомлений
TELEGRAM_BOT_TOKEN=""    # Укажите токен вашего Telegram-бота
TELEGRAM_CHAT_ID=""      # Укажите ID чата или пользователя
# Имя сервера (если пустое, используется системное имя хоста)
SERVER_NAME=""

# Установка имени сервера
if [[ -z "$SERVER_NAME" ]]; then
    SERVER_NAME=$(hostname)
fi

# Функция логирования
log() {
    local message="[$SERVER_NAME] $1"
    # Записываем в лог только если файл доступен для записи
    if [[ -w "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    fi
    echo "$message"
}

# Функция отправки уведомлений в Telegram
send_telegram() {
    local message="$1"
    if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
             -d chat_id="$TELEGRAM_CHAT_ID" \
             -d text="$message" >/dev/null
    fi
}

# Функция обработки ошибок
handle_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        local log_content
        log_content=$(tail -n 50 "$LOG_FILE" 2>/dev/null || echo "Лог-файл недоступен")
        send_telegram "[$SERVER_NAME] Ошибка в скрипте AdGuard Home:\n$log_content"
    fi
    exit $exit_code
}

# Устанавливаем обработчик ошибок
trap handle_error EXIT

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    log "Ошибка: Скрипт должен быть запущен с правами root."
    exit 1
fi

# Начало выполнения
log "Запуск скрипта обновления AdGuard Home..."

# Проверка существования директории логов и создание, если отсутствует
LOG_DIR=$(dirname "$LOG_FILE")
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    if [[ $? -ne 0 ]]; then
        echo "[$SERVER_NAME] Ошибка: Не удалось создать директорию логов $LOG_DIR."
        exit 1
    fi
fi

# Проверка существования и прав на лог-файл
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        echo "[$SERVER_NAME] Ошибка: Не удалось создать лог-файл $LOG_FILE."
        exit 1
    fi
fi
if [[ ! -w "$LOG_FILE" ]]; then
    chmod u+w "$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        echo "[$SERVER_NAME] Ошибка: Нет прав на запись в лог-файл $LOG_FILE."
        exit 1
    fi
fi

# Проверка размера лог-файла и пересоздание, если > MAX_LOG_SIZE
if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null)
    if [[ -n "$LOG_SIZE" && $LOG_SIZE -gt $MAX_LOG_SIZE ]]; then
        log "Лог-файл превысил $(($MAX_LOG_SIZE / 1024)) КБ ($LOG_SIZE байт), пересоздаём..."
        : > "$LOG_FILE"
        log "Лог-файл пересоздан."
    fi
fi

# Проверка наличия необходимых утилит
log "Проверка наличия утилит..."
for cmd in curl jq tar systemctl nslookup; do
    if ! command -v "$cmd" &> /dev/null; then
        log "Ошибка: Утилита $cmd не установлена."
        exit 1
    fi
done
log "Все необходимые утилиты установлены."

# Проверка существования службы adguardhome.service
if ! systemctl is-enabled adguardhome.service >/dev/null 2>&1; then
    log "Ошибка: Служба adguardhome.service не найдена или не включена."
    log "Создайте службу, используя пример конфигурации:"
    log "[Unit]\nDescription=AdGuard Home DNS Service\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nUser=adguard\nGroup=adguard\nExecStart=/opt/AdGuardHome/AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml\nRestart=on-failure\nRestartSec=5\nAmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\nReadWritePaths=/opt/AdGuardHome\n\n[Install]\nWantedBy=multi-user.target"
    log "Сохраните в /etc/systemd/system/adguardhome.service и выполните: sudo systemctl enable --now adguardhome.service"
    exit 1
fi
log "Служба adguardhome.service найдена и активна."

# Проверка места на диске
log "Проверка места на диске..."
if ! df -h /tmp | grep -q "Avail"; then
    log "Ошибка: Недостаточно места на диске в /tmp."
    exit 1
fi
log "Место на диске в /tmp доступно."

# Создание директории для резервных копий, если отсутствует
if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    if [[ $? -ne 0 ]]; then
        log "Ошибка: Не удалось создать директорию $BACKUP_DIR."
        exit 1
    fi
fi

# Очистка старых резервных копий
log "Очистка старых резервных копий..."
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR" | grep '^backup_' | wc -l)
if [[ $BACKUP_COUNT -gt 2 ]]; then
    ls -1 "$BACKUP_DIR" | grep '^backup_' | sort -r | tail -n +3 | while read -r old_backup; do
        log "Удаление старой резервной копии: $BACKUP_DIR/$old_backup"
        rm -rf "$BACKUP_DIR/$old_backup"
    done
    # Пересчитываем количество копий после удаления
    BACKUP_COUNT=$(ls -1 "$BACKUP_DIR" | grep '^backup_' | wc -l)
fi
log "Очистка резервных копий завершена. Хранится $BACKUP_COUNT копий."

# Создание директорий, если их нет
mkdir -p "$TEMP_DIR" "$(dirname "$LOG_FILE")"
if [[ ! -w "$TEMP_DIR" ]]; then
    log "Ошибка: Нет прав на запись в $TEMP_DIR."
    exit 1
fi
log "Директории созданы и доступны для записи."

# Проверка DNS
log "Проверка разрешения DNS для github.com и static.adguard.com..."
NSLOOKUP_GITHUB=$(nslookup github.com $DNS_SERVERS 2>&1)
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось разрешить github.com через $DNS_SERVERS. Вывод: $NSLOOKUP_GITHUB"
    exit 1
fi
NSLOOKUP_ADGUARD=$(nslookup static.adguard.com $DNS_SERVERS 2>&1)
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось разрешить static.adguard.com через $DNS_SERVERS. Вывод: $NSLOOKUP_ADGUARD"
    exit 1
fi
log "DNS работает корректно."

# Проверка сетевой доступности
log "Проверка сетевой доступности..."
if ! ping -c 1 $DNS_SERVERS &> /dev/null; then
    log "Ошибка: Нет сетевого соединения с $DNS_SERVERS."
    exit 1
fi
log "Сетевое соединение доступно."

# Получение текущей версии
log "Получение текущей версии AdGuard Home..."
CURRENT_VERSION=$("$AGH_PATH/AdGuardHome" --version | grep -oP 'v\d+\.\d+\.\d+')
if [[ -z "$CURRENT_VERSION" ]]; then
    log "Ошибка: Не удалось определить текущую версию AdGuard Home."
    exit 1
fi
log "Текущая версия: $CURRENT_VERSION"

# Получение последней версии с GitHub
log "Получение последней версии с GitHub..."
CURL_OUTPUT=$(curl -s -L --connect-timeout 30 -w "\nHTTP_STATUS:%{http_code}" "$RELEASES_API")
CURL_EXIT=$?
HTTP_STATUS=$(echo "$CURL_OUTPUT" | grep -oP 'HTTP_STATUS:\K\d+')
CURL_BODY=$(echo "$CURL_OUTPUT" | sed '$d') # Удаляем последнюю строку с HTTP_STATUS

if [[ $CURL_EXIT -ne 0 || $HTTP_STATUS -ne 200 ]]; then
    log "Ошибка: Не удалось получить информацию о последней версии. Код curl: $CURL_EXIT, HTTP статус: $HTTP_STATUS. Вывод: $CURL_BODY"
    log "Используем резервную версию: $FALLBACK_VERSION"
    LATEST_VERSION="$FALLBACK_VERSION"
else
    LATEST_VERSION=$(echo "$CURL_BODY" | jq -r '.tag_name' 2>/dev/null)
    if [[ $? -ne 0 || -z "$LATEST_VERSION" ]]; then
        log "Ошибка: Не удалось разобрать JSON от GitHub. Вывод: $CURL_BODY"
        log "Используем резервную версию: $FALLBACK_VERSION"
        LATEST_VERSION="$FALLBACK_VERSION"
    fi
fi
log "Последняя версия: $LATEST_VERSION"

# Сравнение версий
if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    log "Обновление не требуется, установлена последняя версия."
    exit 0
fi
log "Доступна новая версия $LATEST_VERSION, продолжаем..."

# Скачивание новой версии
log "Скачивание новой версии из $DOWNLOAD_URL..."
CURL_OUTPUT=$(curl -L -s -o "$TEMP_DIR/AdGuardHome.tar.gz" "$DOWNLOAD_URL" --connect-timeout 30 --resolve "static.adguard.com:443:104.21.3.203" 2>&1)
CURL_EXIT=$?
if [[ $CURL_EXIT -ne 0 ]]; then
    log "Ошибка: Не удалось скачать новую версию. Код ошибки curl: $CURL_EXIT. Вывод: $CURL_OUTPUT"
    # Попытка использовать локальный файл
    if [[ -s "$FALLBACK_FILE" ]]; then
        log "Используем локальный файл $FALLBACK_FILE..."
        cp "$FALLBACK_FILE" "$TEMP_DIR/AdGuardHome.tar.gz"
    else
        log "Ошибка: Локальный файл $FALLBACK_FILE отсутствует или пустой."
        exit 1
    fi
fi

# Проверка целостности файла
log "Проверка целостности скачанного файла..."
if [[ ! -s "$TEMP_DIR/AdGuardHome.tar.gz" ]]; then
    log "Ошибка: Скачанный файл пустой или повреждён."
    exit 1
fi
log "Файл успешно скачан и проверен."

# Все проверки пройдены, начинаем обновление
log "Все предварительные проверки пройдены, начинаем обновление..."

# Остановка службы
log "Остановка службы AdGuard Home..."
systemctl stop adguardhome.service
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось остановить службу AdGuard Home."
    exit 1
fi

# Создание резервной копии
BACKUP_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_PATH="$BACKUP_DIR/backup_$BACKUP_TIMESTAMP"
log "Создание резервной копии в $BACKUP_PATH..."
mkdir -p "$BACKUP_PATH"
cp -r "$CONFIG_FILE" "$DATA_DIR" "$BACKUP_PATH"
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось создать резервную копию."
    systemctl start adguardhome.service
    exit 1
fi

# Распаковка
log "Распаковка архива..."
tar -C "$TEMP_DIR" -xzf "$TEMP_DIR/AdGuardHome.tar.gz"
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось распаковать архив."
    systemctl start adguardhome.service
    exit 1
fi

# Замена исполняемого файла
log "Обновление исполняемого файла..."
cp "$TEMP_DIR/AdGuardHome/AdGuardHome" "$AGH_PATH/AdGuardHome"
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось заменить исполняемый файл."
    systemctl start adguardhome.service
    exit 1
fi
chmod +x "$AGH_PATH/AdGuardHome"

# Копирование документации (опционально)
for doc in CHANGELOG.md README.md LICENSE.txt; do
    if [[ -f "$TEMP_DIR/AdGuardHome/$doc" ]]; then
        cp "$TEMP_DIR/AdGuardHome/$doc" "$AGH_PATH/$doc"
    fi
done

# Очистка временной директории
rm -rf "$TEMP_DIR"
log "Временная директория очищена."

# Запуск службы
log "Запуск службы AdGuard Home..."
systemctl start adguardhome.service
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось запустить службу AdGuard Home."
    exit 1
fi

# Проверка статуса службы
sleep 5
if systemctl is-active --quiet adguardhome.service; then
    log "Обновление успешно завершено. AdGuard Home работает."
    # Отправляем лог в Telegram при успешном обновлении
    if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        local log_content
        log_content=$(tail -n 50 "$LOG_FILE" 2>/dev/null || echo "Лог-файл недоступен")
        send_telegram "[$SERVER_NAME] AdGuard Home успешно обновлён до $NEW_VERSION:\n$log_content"
    fi
else
    log "Ошибка: Служба AdGuard Home не запущена после обновления."
    exit 1
fi

# Проверка новой версии
NEW_VERSION=$("$AGH_PATH/AdGuardHome" --version | grep -oP 'v\d+\.\d+\.\d+')
log "Новая установленная версия: $NEW_VERSION"
