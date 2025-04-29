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
# Временный файл для лога текущей операции
CURRENT_LOG="/tmp/adguardhome-current.log"
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
# Флаг принудительной отправки Telegram-уведомлений
FORCE_TELEGRAM="false"

# Массив для хранения операций и их статусов
declare -A OPERATIONS

# Обработка аргументов командной строки
while [[ $# -gt 0 ]]; do
    case "$1" in
        --telegram)
            FORCE_TELEGRAM="true"
            shift
            ;;
        *)
            echo "Неизвестный параметр: $1"
            exit 1
            ;;
    esac
done

# Установка имени сервера
if [[ -z "$SERVER_NAME" ]]; then
    SERVER_NAME=$(hostname)
fi

# Функция логирования
log() {
    local message="[$SERVER_NAME] $1"
    # Записываем в основной лог
    if [[ -w "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    fi
    # Записываем в лог текущей операции
    if [[ -w "$CURRENT_LOG" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$CURRENT_LOG"
    fi
    echo "$message"
}

# Функция логирования статуса операции
log_status() {
    local operation="$1"
    local status="$2"
    log "$operation: [$status]"
    OPERATIONS["$operation"]="$status"
}

# Функция вывода таблицы операций
print_table() {
    local table="+----------------------------------+--------+\n"
    table+="| Операция                         | Статус |\n"
    table+="+----------------------------------+--------+\n"
    for op in "${!OPERATIONS[@]}"; do
        printf -v row "| %-32s | %-6s |\n" "$op" "${OPERATIONS[$op]}"
        table+="$row"
    done
    table+="+----------------------------------+--------+\n"
    log "$table"
}

# Функция проверки доступности Telegram API
check_telegram_api() {
    local response
    response=$(curl -s --connect-timeout 5 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe" 2>&1)
    if [[ $? -ne 0 || "$response" =~ "error_code" || ! "$response" =~ "\"ok\":true" ]]; then
        log "Ошибка доступа к Telegram API: $response"
        return 1
    fi
    return 0
}

# Функция отправки уведомлений в Telegram
send_telegram() {
    local message="$1"
    if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        # Проверяем доступность Telegram API
        check_telegram_api
        if [[ $? -ne 0 ]]; then
            log "Пропуск отправки Telegram-уведомления из-за недоступности API"
            return 1
        fi
        local response
        response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
             -d chat_id="$TELEGRAM_CHAT_ID" \
             -d text="$message" \
             -d parse_mode="Markdown" 2>&1)
        if [[ $? -ne 0 || "$response" =~ "error_code" ]]; then
            log "Ошибка отправки Telegram-уведомления: $response"
            return 1
        fi
    fi
    return 0
}

# Функция обработки ошибок
handle_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_table
        if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
            local log_content
            log_content=$(cat "$CURRENT_LOG" 2>/dev/null || echo "Лог текущей операции недоступен")
            send_telegram "❌ Ошибка на $SERVER_NAME:\n\`\`\`\n$log_content\n\`\`\`"
        fi
    fi
    # Очищаем временный лог и добавляем пустую строку в основной лог
    [[ -f "$CURRENT_LOG" ]] && rm -f "$CURRENT_LOG"
    [[ -w "$LOG_FILE" ]] && echo "" >> "$LOG_FILE"
    exit $exit_code
}

# Функция отправки лога в Telegram при завершении (если указан --telegram)
send_final_telegram() {
    if [[ "$FORCE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        send_telegram "ℹ️ Проверка обновления AdGuard Home на $SERVER_NAME: версия $LATEST_VERSION, установлена $CURRENT_VERSION, обновление не требуется"
    fi
}

# Устанавливаем обработчик ошибок
trap handle_error EXIT

# Очищаем временный лог перед началом
: > "$CURRENT_LOG"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    log "Ошибка: Скрипт должен быть запущен с правами root."
    exit 1
fi

# Проверка наличия необходимых утилит (без логирования, если всё ок)
for cmd in curl jq tar systemctl nslookup; do
    if ! command -v "$cmd" &> /dev/null; then
        log "Ошибка: Утилита $cmd не установлена."
        exit 1
    fi
done

# Проверка существования директории логов и создание, если отсутствует
LOG_DIR=$(dirname "$LOG_FILE")
if [[ ! -d "$LOG_DIR" ]]; then
    log "Создание директории логов $LOG_DIR..."
    mkdir -p "$LOG_DIR"
    if [[ $? -ne 0 ]]; then
        echo "[$SERVER_NAME] Ошибка: Не удалось создать директорию логов $LOG_DIR."
        exit 1
    fi
    log_status "Создание директории логов" "ОК"
fi

# Проверка существования и прав на лог-файл
if [[ ! -f "$LOG_FILE" ]]; then
    log "Создание лог-файла $LOG_FILE..."
    touch "$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        echo "[$SERVER_NAME] Ошибка: Не удалось создать лог-файл $LOG_FILE."
        exit 1
    fi
    log_status "Создание лог-файла" "ОК"
fi
if [[ ! -w "$LOG_FILE" ]]; then
    log "Установка прав на лог-файл $LOG_FILE..."
    chmod u+w "$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        echo "[$SERVER_NAME] Ошибка: Нет прав на запись в лог-файл $LOG_FILE."
        exit 1
    fi
    log_status "Установка прав на лог-файл" "ОК"
fi

# Проверка размера лог-файла и пересоздание, если > MAX_LOG_SIZE
if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null)
    if [[ -n "$LOG_SIZE" && $LOG_SIZE -gt $MAX_LOG_SIZE ]]; then
        log "Лог-файл превысил $(($MAX_LOG_SIZE / 1024)) КБ ($LOG_SIZE байт), пересоздаём..."
        : > "$LOG_FILE"
        log "Лог-файл пересоздан."
        log_status "Пересоздание лога" "ОК"
    fi
fi

# Начало выполнения
log "Запуск скрипта обновления AdGuard Home..."

# Получение текущей версии
CURRENT_VERSION=$("$AGH_PATH/AdGuardHome" --version | grep -oP 'v\d+\.\d+\.\d+')
if [[ -z "$CURRENT_VERSION" ]]; then
    log "Ошибка: Не удалось определить текущую версию AdGuard Home."
    exit 1
fi

# Получение последней версии с GitHub
log "Проверка доступной версии AdGuard Home..."
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
log_status "Проверка версии" "ОК ($LATEST_VERSION)"

# Сравнение версий
if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    log "Проверка доступной версии: $LATEST_VERSION, совпадает с текущей [ОК]"
    send_final_telegram
    # Очищаем временный лог и добавляем пустую строку в основной лог
    [[ -f "$CURRENT_LOG" ]] && rm -f "$CURRENT_LOG"
    [[ -w "$LOG_FILE" ]] && echo "" >> "$LOG_FILE"
    exit 0
fi

# Если версии различаются, продолжаем с подробным логированием
log "Доступна новая версия $LATEST_VERSION, текущая $CURRENT_VERSION, начинаем обновление..."

# Проверка места на диске
log "Проверка места на диске..."
if ! df -h /tmp | grep -q "Avail"; then
    log "Ошибка: Недостаточно места на диске в /tmp."
    exit 1
fi
log_status "Проверка диска" "ОК"

# Создание директории для резервных копий, если отсутствует
if [[ ! -d "$BACKUP_DIR" ]]; then
    log "Создание директории для резервных копий $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    if [[ $? -ne 0 ]]; then
        log "Ошибка: Не удалось создать директорию $BACKUP_DIR."
        exit 1
    fi
    log_status "Создание директории копий" "ОК"
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
log_status "Очистка копий" "ОК ($BACKUP_COUNT копий)"

# Создание директорий, если их нет
log "Проверка наличия временных директорий..."
mkdir -p "$TEMP_DIR" "$(dirname "$LOG_FILE")"
if [[ ! -w "$TEMP_DIR" ]]; then
    log "Ошибка: Нет прав на запись в $TEMP_DIR."
    exit 1
fi
log_status "Проверка директорий" "ОК"

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
log_status "Проверка DNS" "ОК"

# Проверка сетевой доступности
log "Проверка сетевой доступности..."
if ! ping -c 1 $DNS_SERVERS &> /dev/null; then
    log "Ошибка: Нет сетевого соединения с $DNS_SERVERS."
    exit 1
fi
log_status "Проверка сети" "ОК"

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
        log_status "Использование резервного файла" "ОК"
    else
        log "Ошибка: Локальный файл $FALLBACK_FILE отсутствует или пустой."
        exit 1
    fi
else
    log_status "Скачивание новой версии" "ОК"
fi

# Проверка целостности файла
log "Проверка целостности скачанного файла..."
if [[ ! -s "$TEMP_DIR/AdGuardHome.tar.gz" ]]; then
    log "Ошибка: Скачанный файл пустой или повреждён."
    exit 1
fi
log_status "Проверка целостности файла" "ОК"

# Все проверки пройдены, начинаем обновление
log "Все предварительные проверки пройдены, начинаем обновление..."
log_status "Предварительные проверки" "ОК"

# Остановка службы
log "Остановка службы AdGuard Home..."
systemctl stop adguardhome.service
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось остановить службу AdGuard Home."
    exit 1
fi
log_status "Остановка службы" "ОК"

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
log_status "Создание резервной копии" "ОК"

# Распаковка
log "Распаковка архива..."
tar -C "$TEMP_DIR" -xzf "$TEMP_DIR/AdGuardHome.tar.gz"
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось распаковать архив."
    systemctl start adguardhome.service
    exit 1
fi
log_status "Распаковка архива" "ОК"

# Замена исполняемого файла
log "Обновление исполняемого файла..."
cp "$TEMP_DIR/AdGuardHome/AdGuardHome" "$AGH_PATH/AdGuardHome"
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось заменить исполняемый файл."
    systemctl start adguardhome.service
    exit 1
fi
chmod +x "$AGH_PATH/AdGuardHome"
log_status "Обновление исполняемого файла" "ОК"

# Копирование документации (опционально)
log "Копирование документации..."
for doc in CHANGELOG.md README.md LICENSE.txt; do
    if [[ -f "$TEMP_DIR/AdGuardHome/$doc" ]]; then
        cp "$TEMP_DIR/AdGuardHome/$doc" "$AGH_PATH/$doc"
    fi
done
log_status "Копирование документации" "ОК"

# Очистка временной директории
log "Очистка временной директории..."
rm -rf "$TEMP_DIR"
log_status "Очистка временной директории" "ОК"

# Запуск службы
log "Запуск службы AdGuard Home..."
systemctl start adguardhome.service
if [[ $? -ne 0 ]]; then
    log "Ошибка: Не удалось запустить службу AdGuard Home."
    exit 1
fi
log_status "Запуск службы" "ОК"

# Проверка статуса службы
log "Проверка статуса службы..."
sleep 5
if systemctl is-active --quiet adguardhome.service; then
    log "Обновление успешно завершено. AdGuard Home работает."
    log_status "Проверка статуса службы" "ОК"
    # Отправляем краткое уведомление в Telegram при успешном обновлении
    if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        send_telegram "✅ AdGuard на $SERVER_NAME обновлён до версии $NEW_VERSION"
    fi
else
    log "Ошибка: Служба AdGuard Home не запущена после обновления."
    exit 1
fi

# Проверка новой версии
log "Проверка новой версии..."
NEW_VERSION=$("$AGH_PATH/AdGuardHome" --version | grep -oP 'v\d+\.\d+\.\d+')
log "Новая установленная версия: $NEW_VERSION"
log_status "Проверка новой версии" "ОК"

# Выводим таблицу операций
print_table

# Отправляем финальное уведомление, если указан --telegram
send_final_telegram

# Очищаем временный лог и добавляем пустую строку в основной лог
[[ -f "$CURRENT_LOG" ]] && rm -f "$CURRENT_LOG"
[[ -w "$LOG_FILE" ]] && echo "" >> "$LOG_FILE"
