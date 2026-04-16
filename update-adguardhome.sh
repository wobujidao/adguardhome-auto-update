#!/bin/bash

# Defaults (may be overridden by external config)
AGH_PATH="/opt/AdGuardHome"
TEMP_DIR="/tmp/adguardhome_update"
BACKUP_DIR="/opt/AdGuardHome/backup"
LOG_PATH="/var/log/adguardhome-update.log"
DNS_SERVERS="8.8.8.8"
SERVER_NAME=$(hostname)
SERVICE_NAME="adguardhome.service"

# Telegram defaults
ENABLE_TELEGRAM="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Rotation defaults
MAX_BACKUP_COUNT=7
MAX_LOG_SIZE=$((5 * 1024 * 1024))

START_TIME=$(date +%s)

# Internal
FORCE_TELEGRAM="false"
CONFIG_FILE_CLI=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK_BACKUP=""

# Help
print_help() {
    cat <<'EOF'
Usage: update-adguardhome.sh [options]

Options:
  --config <path>     Путь к внешнему config.conf
  --telegram          Принудительно отправить уведомление по завершении
  --help              Показать эту справку и выйти

Скрипт поддерживает внешний конфиг и ищет его по путям:
  1) /etc/adguardhome-updater/config.conf
  2) /usr/local/etc/adguardhome-updater/config.conf
  3) ./config.conf
  4) <директория_скрипта>/config.conf
EOF
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            print_help
            exit 0
            ;;
        --config)
            CONFIG_FILE_CLI="$2"; shift 2 || { echo "Ошибка: отсутствует путь после --config"; exit 2; }
            ;;
        --telegram)
            FORCE_TELEGRAM="true"; shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"; echo; print_help; exit 2
            ;;
    esac
done

# Resolve config file
CONFIG_FILE=""
if [[ -n "$CONFIG_FILE_CLI" ]]; then
    CONFIG_FILE="$CONFIG_FILE_CLI"
else
    for candidate in \
        "/etc/adguardhome-updater/config.conf" \
        "/usr/local/etc/adguardhome-updater/config.conf" \
        "./config.conf" \
        "$SCRIPT_DIR/config.conf"; do
        if [[ -f "$candidate" ]]; then
            CONFIG_FILE="$candidate"; break
        fi
    done
fi

# Source external config if present
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Prepare logging
CURRENT_LOG="$LOG_PATH"
LOG_DIR="$(dirname "$CURRENT_LOG")"
mkdir -p "$LOG_DIR" 2>/dev/null || true
touch "$CURRENT_LOG" 2>/dev/null || true

# Rotate log if too big
if [[ -f "$CURRENT_LOG" ]]; then
    CURRENT_SIZE=$(wc -c < "$CURRENT_LOG" 2>/dev/null || echo 0)
    if [[ "$CURRENT_SIZE" -gt "$MAX_LOG_SIZE" ]]; then
        ts="$(date +%Y%m%d_%H%M%S)"
        mv "$CURRENT_LOG" "${CURRENT_LOG}.${ts}" 2>/dev/null || true
        : > "$CURRENT_LOG"
        find "$LOG_DIR" -maxdepth 1 -type f -name "$(basename "$CURRENT_LOG").*" \
            -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR>5 {print $2}' | xargs -r rm -f
    fi
fi

# Logging function with systemd integration
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$CURRENT_LOG"
    logger -t adguardhome-update "$1"
}

# Status table logging
log_status() {
    local task="$1"
    local status="$2"
    printf "%-40s | %-10s\n" "$task" "$status" | tee -a "$CURRENT_LOG"
}

# Telegram API check
check_telegram_api() {
    curl -s --max-time 5 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | grep -q '"ok":true'
}

# Telegram notification function
send_telegram() {
    local message="$1"
    if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        if ! check_telegram_api; then
            log "Пропуск Telegram-уведомления: API недоступен"
            return 1
        fi
        local escaped_message
        escaped_message=$(echo "$message" | sed 's/[_*\[`]/\\&/g')
        local response
        response=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$escaped_message" \
            -d parse_mode="Markdown" 2>&1)
        if [[ $? -ne 0 || "$response" =~ "error_code" ]]; then
            log "Ошибка Telegram: $response"
            return 1
        fi
    fi
    return 0
}

# Version validation
validate_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Rollback: restore files from the latest backup archive
rollback() {
    local backup_file="$1"
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
        log "Откат невозможен: файл резервной копии не найден ($backup_file)"
        return 1
    fi
    log "Откат: восстановление из $backup_file ..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    if tar -xzf "$backup_file" -C "$AGH_PATH"; then
        log "Откат: файлы восстановлены."
    else
        log "Откат: ОШИБКА распаковки резервной копии!"
        return 1
    fi
    systemctl start "$SERVICE_NAME"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Откат: служба успешно запущена после восстановления."
        send_telegram "➀‏ AdGuard на $SERVER_NAME: обновление не удалось, выполнен откат к предыдущей версии"
        return 0
    else
        log "Откат: КРИТИЧЕСКАЯ ОШИБКА — служба не запустилась даже после восстановления!"
        send_telegram "🔴 AdGuard на $SERVER_NAME: критическая ошибка — служба не работает после отката!"
        return 1
    fi
}

# Cleanup on interrupt
cleanup_on_interrupt() {
    log "Прерывание, очистка..."
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Перезапуск службы..."
        systemctl start "$SERVICE_NAME"
    fi
    exit 130
}

# Error handler
handle_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then
        log "Ошибка выполнения скрипта (код: $exit_code)"
        send_telegram "❌ Ошибка обновления AdGuard на $SERVER_NAME"
    fi
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

# Set traps
trap cleanup_on_interrupt SIGINT SIGTERM
trap handle_error EXIT

# Check required utilities
log "Проверка утилит..."
for util in curl tar systemctl grep awk logger find sed sha256sum stat; do
    if ! command -v "$util" &>/dev/null; then
        log "Ошибка: Утилита $util не найдена."
        exit 1
    fi
done
log_status "Проверка утилит" "ОК"

# Check adguardhome.service
log "Проверка службы AdGuard Home..."
if ! systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
    log "Ошибка: Служба $SERVICE_NAME не найдена."
    exit 1
fi
log_status "Проверка службы" "ОК"

# Check configuration file
log "Проверка конфигурации..."
if [[ ! -f "$AGH_PATH/AdGuardHome.yaml" ]]; then
    log "Ошибка: Конфигурационный файл не найден."
    exit 1
fi
log_status "Проверка конфигурации" "ОК"

# Check DNS resolution
log "Проверка DNS..."
for domain in "github.com" "static.adguard.com"; do
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$domain" >/dev/null 2>&1 || { log "Ошибка: Не удалось разрешить $domain"; exit 1; }
    else
        curl -s --head --connect-timeout 5 "https://$domain" >/dev/null 2>&1 || { log "Ошибка: Не удалось подключиться к $domain"; exit 1; }
    fi
done
log_status "Проверка DNS" "ОК"

# Check disk space
log "Проверка места на диске..."
AVAILABLE_MB=$(df /tmp | awk 'NR==2 {print int($4/1024)}')
REQUIRED_MB=100
if [[ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]]; then
    log "Ошибка: Доступно ${AVAILABLE_MB}МБ, требуется ${REQUIRED_MB}МБ"
    exit 1
fi
log_status "Проверка диска" "ОК (${AVAILABLE_MB}МБ)"

# Check server connectivity
log "Проверка соединения с сервером..."
if ! curl -s --head --fail --max-time 10 "https://static.adguard.com" >/dev/null; then
    log "Ошибка: Сервер static.adguard.com недоступен."
    exit 1
fi
log_status "Проверка соединения" "ОК"

# Get current version
log "Проверка текущей версии..."
CURRENT_VERSION=$("$AGH_PATH/AdGuardHome" --version | grep -E -o 'v[0-9]+\.[0-9]+\.[0-9]+')
if ! validate_version "$CURRENT_VERSION"; then
    log "Ошибка: Некорректная версия: $CURRENT_VERSION"
    exit 1
fi
log "Текущая версия: $CURRENT_VERSION"
log_status "Проверка текущей версии" "ОК"

# Get latest version
log "Проверка последней версии..."
LATEST_VERSION=$(curl -s --max-time 10 "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" | grep -E -o 'v[0-9]+\.[0-9]+\.[0-9]+')
if ! validate_version "$LATEST_VERSION"; then
    log "Ошибка: Некорректная последняя версия: $LATEST_VERSION"
    exit 1
fi
log "Последняя версия: $LATEST_VERSION"

# Compare versions
if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    log "AdGuard Home уже на версии $LATEST_VERSION [ОК]"
    send_telegram "ℹ️ AdGuard на $SERVER_NAME уже на версии $LATEST_VERSION"
    exit 0
fi
log_status "Проверка обновления" "Требуется"

# Determine architecture
log "Определение архитектуры..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="linux_amd64" ;;
    aarch64|arm64) ARCH_SUFFIX="linux_arm64" ;;
    armv7l) ARCH_SUFFIX="linux_armv7" ;;
    *) log "Ошибка: Неподдерживаемая архитектура $ARCH"; exit 1 ;;
esac
log_status "Проверка архитектуры" "ОК ($ARCH)"

# Create temp directory
log "Создание временной директории..."
mkdir -p "$TEMP_DIR" || { log "Ошибка создания $TEMP_DIR"; exit 1; }
log_status "Создание директории" "ОК"

# Download latest version
ARCHIVE_NAME="AdGuardHome_${ARCH_SUFFIX}.tar.gz"
log "Скачивание версии $LATEST_VERSION..."
if ! curl -sL --max-time 60 "https://static.adguard.com/adguardhome/release/${ARCHIVE_NAME}" -o "$TEMP_DIR/${ARCHIVE_NAME}"; then
    log "Ошибка скачивания."
    rm -rf "$TEMP_DIR"
    exit 1
fi
log_status "Скачивание" "ОК"

# Check file integrity — size check
log "Проверка целостности (размер)..."
FILE_SIZE=$(wc -c < "$TEMP_DIR/${ARCHIVE_NAME}" 2>/dev/null || echo "0")
if [[ "$FILE_SIZE" -lt 10485760 ]]; then
    log "Ошибка: Файл слишком мал ($FILE_SIZE байт)"
    rm -rf "$TEMP_DIR"
    exit 1
fi
log_status "Проверка размера" "ОК (${FILE_SIZE} байт)"

# Check file integrity — SHA256 checksum verification
log "Проверка контрольной суммы SHA256..."
CHECKSUMS_URL="https://static.adguard.com/adguardhome/release/checksums.txt"
CHECKSUMS_FILE="$TEMP_DIR/checksums.txt"
CHECKSUM_VERIFIED="false"

if curl -sL --max-time 15 "$CHECKSUMS_URL" -o "$CHECKSUMS_FILE" 2>/dev/null && [[ -s "$CHECKSUMS_FILE" ]]; then
    EXPECTED_HASH=$(grep "${ARCHIVE_NAME}" "$CHECKSUMS_FILE" | awk '{print $1}')
    if [[ -n "$EXPECTED_HASH" ]]; then
        ACTUAL_HASH=$(sha256sum "$TEMP_DIR/${ARCHIVE_NAME}" | awk '{print $1}')
        if [[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]]; then
            log "SHA256 совпадает: $ACTUAL_HASH"
            CHECKSUM_VERIFIED="true"
            log_status "Проверка SHA256" "ОК"
        else
            log "Ошибка: SHA256 не совпадает!"
            log "  Ожидалось: $EXPECTED_HASH"
            log "  Получено:  $ACTUAL_HASH"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    else
        log "Предупреждение: запись для ${ARCHIVE_NAME} не найдена в checksums.txt, пропуск проверки SHA256"
        log_status "Проверка SHA256" "Пропущена"
    fi
else
    log "Предупреждение: не удалось скачать checksums.txt, пропуск проверки SHA256"
    log_status "Проверка SHA256" "Пропущена"
fi

# Save original file ownership and permissions before backup
log "Сохранение прав доступа текущего бинарного файла..."
ORIG_BINARY="$AGH_PATH/AdGuardHome"
if [[ -f "$ORIG_BINARY" ]]; then
    ORIG_OWNER=$(stat -c '%U' "$ORIG_BINARY" 2>/dev/null || echo "root")
    ORIG_GROUP=$(stat -c '%G' "$ORIG_BINARY" 2>/dev/null || echo "root")
    ORIG_PERMS=$(stat -c '%a' "$ORIG_BINARY" 2>/dev/null || echo "755")
    log "Текущие права: ${ORIG_OWNER}:${ORIG_GROUP} ${ORIG_PERMS}"
else
    ORIG_OWNER="root"
    ORIG_GROUP="root"
    ORIG_PERMS="755"
    log "Бинарный файл не найден, будут использованы права по умолчанию: ${ORIG_OWNER}:${ORIG_GROUP} ${ORIG_PERMS}"
fi
log_status "Сохранение прав доступа" "ОК"

# Create backup
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ROLLBACK_BACKUP="$BACKUP_DIR/AdGuardHome_backup_${BACKUP_TIMESTAMP}.tar.gz"
log "Создание резервной копии..."
mkdir -p "$BACKUP_DIR"
if ! tar -czf "$ROLLBACK_BACKUP" -C "$AGH_PATH" .; then
    log "Ошибка создания резервной копии."
    ROLLBACK_BACKUP=""
    rm -rf "$TEMP_DIR"
    exit 1
fi
log_status "Резервное копирование" "ОК"

# Clean old backups
log "Очистка старых резервных копий..."
if [[ "$MAX_BACKUP_COUNT" -gt 0 ]] 2>/dev/null; then
    find "$BACKUP_DIR" -maxdepth 1 -name 'AdGuardHome_backup_*.tar.gz' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | awk -v max="$MAX_BACKUP_COUNT" 'NR>max {print $2}' | xargs -r rm -f
fi
log_status "Очистка резервных копий" "ОК"

# Extract new version
log "Распаковка новой версии..."
if ! tar -xzf "$TEMP_DIR/${ARCHIVE_NAME}" -C "$TEMP_DIR"; then
    log "Ошибка распаковки."
    rm -rf "$TEMP_DIR"
    exit 1
fi
log_status "Распаковка" "ОК"

# Stop service
log "Остановка службы AdGuard Home..."
if ! systemctl stop "$SERVICE_NAME"; then
    log "Ошибка остановки службы."
    rm -rf "$TEMP_DIR"
    exit 1
fi
log_status "Остановка службы" "ОК"

# Update executable
log "Обновление исполняемого файла..."
if ! cp "$TEMP_DIR/AdGuardHome/AdGuardHome" "$AGH_PATH/AdGuardHome"; then
    log "Ошибка копирования нового бинарного файла."
    log "Попытка отката..."
    rollback "$ROLLBACK_BACKUP"
    rm -rf "$TEMP_DIR"
    exit 1
fi
chmod "$ORIG_PERMS" "$AGH_PATH/AdGuardHome"
chown "${ORIG_OWNER}:${ORIG_GROUP}" "$AGH_PATH/AdGuardHome"
log_status "Обновление файла" "ОК"

# Start service
log "Запуск службы AdGuard Home..."
systemctl start "$SERVICE_NAME"
sleep 2

# Verify service is running — rollback if not
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Ошибка: Служба не активна после обновления."
    log "Запуск автоматического отката..."
    rollback "$ROLLBACK_BACKUP"
    rm -rf "$TEMP_DIR"
    exit 1
fi
log_status "Запуск службы" "ОК"
log_status "Статус службы" "ОК"

# Check new version
log "Проверка новой версии..."
NEW_VERSION=$("$AGH_PATH/AdGuardHome" --version | grep -E -o 'v[0-9]+\.[0-9]+\.[0-9]+')
if ! validate_version "$NEW_VERSION"; then
    log "Ошибка: Некорректная новая версия: $NEW_VERSION"
    log "Запуск автоматического отката..."
    rollback "$ROLLBACK_BACKUP"
    rm -rf "$TEMP_DIR"
    exit 1
fi
log "Новая версия: $NEW_VERSION"
log_status "Проверка версии" "ОК"

# Send Telegram notification with duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
if [[ ("$ENABLE_TELEGRAM" == "true" || "$FORCE_TELEGRAM" == "true") && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    CHECKSUM_NOTE=""
    if [[ "$CHECKSUM_VERIFIED" == "true" ]]; then
        CHECKSUM_NOTE=" (SHA256 ✔)"
    fi
    send_telegram "✅ AdGuard на $SERVER_NAME обновлён до версии ${NEW_VERSION}${CHECKSUM_NOTE} за ${DURATION}с"
fi

# Cleanup
log "Очистка временных файлов..."
rm -rf "$TEMP_DIR"
log_status "Очистка" "ОК"

log "Обновление завершено за ${DURATION} секунд!"
exit 0
