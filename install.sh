#!/bin/bash
#
# Установщик AdGuard Home Auto-Update
# Одна команда: curl -sSL https://raw.githubusercontent.com/wobujidao/adguardhome-auto-update/main/install.sh | sudo bash
#

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

REPO_RAW="https://raw.githubusercontent.com/wobujidao/adguardhome-auto-update/main"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/adguardhome-updater"
SCRIPT_NAME="update-adguardhome.sh"
CONFIG_EXAMPLE="config.conf.example"
CONFIG_FILE="config.conf"

# Логирование
log_info()    { echo -e "${GREEN}[✔]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error()   { echo -e "${RED}[✘]${NC} $1"; }
log_step()    { echo -e "${CYAN}[→]${NC} $1"; }

# Баннер
print_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   🛡️  AdGuard Home Auto-Update — Установщик    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Проверка root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от имени root (sudo)."
        echo "  Использование: curl -sSL ${REPO_RAW}/install.sh | sudo bash"
        exit 1
    fi
    log_info "Права root — ОК"
}

# Проверка зависимостей
check_dependencies() {
    local missing=()
    for cmd in curl tar systemctl grep awk sed; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Отсутствуют утилиты: ${missing[*]}"
        echo ""
        echo "  Установите их перед запуском:"
        echo "    sudo apt update && sudo apt install -y ${missing[*]}"
        echo "  или:"
        echo "    sudo yum install -y ${missing[*]}"
        exit 1
    fi
    log_info "Зависимости — ОК (curl, tar, systemctl, grep, awk, sed)"
}

# Проверка сети
check_network() {
    if ! curl -s --max-time 10 --head "https://raw.githubusercontent.com" >/dev/null 2>&1; then
        log_error "Нет доступа к GitHub. Проверьте подключение к интернету."
        exit 1
    fi
    log_info "Сеть — ОК"
}

# Создание директорий
create_directories() {
    log_step "Создание директорий..."

    mkdir -p "$INSTALL_DIR"
    log_info "Директория скрипта: $INSTALL_DIR"

    mkdir -p "$CONFIG_DIR"
    log_info "Директория конфигурации: $CONFIG_DIR"
}

# Скачивание файлов
download_files() {
    log_step "Скачивание скрипта обновления..."

    if ! curl -sSL --max-time 30 "${REPO_RAW}/${SCRIPT_NAME}" -o "${INSTALL_DIR}/${SCRIPT_NAME}"; then
        log_error "Ошибка скачивания ${SCRIPT_NAME}"
        exit 1
    fi
    log_info "Скрипт скачан: ${INSTALL_DIR}/${SCRIPT_NAME}"

    log_step "Скачивание примера конфигурации..."

    if ! curl -sSL --max-time 30 "${REPO_RAW}/${CONFIG_EXAMPLE}" -o "${CONFIG_DIR}/${CONFIG_EXAMPLE}"; then
        log_error "Ошибка скачивания ${CONFIG_EXAMPLE}"
        exit 1
    fi
    log_info "Пример конфигурации: ${CONFIG_DIR}/${CONFIG_EXAMPLE}"
}

# Установка прав
set_permissions() {
    log_step "Установка прав доступа..."

    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
    chown root:root "${INSTALL_DIR}/${SCRIPT_NAME}"
    log_info "Скрипт: 755, root:root"

    chmod 600 "${CONFIG_DIR}/${CONFIG_EXAMPLE}"
    chown root:root "${CONFIG_DIR}/${CONFIG_EXAMPLE}"
    log_info "Пример конфигурации: 600, root:root"
}

# Создание конфигурации из примера
create_config() {
    if [[ -f "${CONFIG_DIR}/${CONFIG_FILE}" ]]; then
        log_warn "Конфигурация ${CONFIG_DIR}/${CONFIG_FILE} уже существует, пропускаю."
    else
        log_step "Создание конфигурации из примера..."
        cp "${CONFIG_DIR}/${CONFIG_EXAMPLE}" "${CONFIG_DIR}/${CONFIG_FILE}"
        chmod 600 "${CONFIG_DIR}/${CONFIG_FILE}"
        chown root:root "${CONFIG_DIR}/${CONFIG_FILE}"
        log_info "Конфигурация создана: ${CONFIG_DIR}/${CONFIG_FILE}"
    fi
}

# Предложение настройки cron
setup_cron() {
    local cron_line="0 0 * * * ${INSTALL_DIR}/${SCRIPT_NAME} >> /var/log/adguardhome-update.log 2>&1"

    echo ""
    log_step "Настройка автоматического обновления (cron)..."

    # Проверяем, есть ли уже задача в crontab
    if crontab -l 2>/dev/null | grep -qF "${SCRIPT_NAME}"; then
        log_warn "Задача cron для ${SCRIPT_NAME} уже существует."
        return 0
    fi

    # При pipe-установке stdin не интерактивный — проверяем
    if [[ -t 0 ]]; then
        echo ""
        echo -e "  Добавить ежедневный запуск обновления в 00:00? ${CYAN}[y/N]${NC}: "
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
            log_info "Задача cron добавлена: ежедневно в 00:00"
        else
            log_warn "Cron не настроен. Вы можете добавить вручную:"
            echo "    sudo crontab -e"
            echo "    ${cron_line}"
        fi
    else
        # Неинтерактивный режим (pipe) — добавляем автоматически
        (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
        log_info "Задача cron добавлена: ежедневно в 00:00"
    fi
}

# Финальные инструкции
print_instructions() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   ✅ Установка завершена!                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}Следующие шаги:${NC}"
    echo ""
    echo -e "  1. ${CYAN}Отредактируйте конфигурацию:${NC}"
    echo "       sudo nano ${CONFIG_DIR}/${CONFIG_FILE}"
    echo ""
    echo -e "  2. ${CYAN}Укажите путь к AdGuard Home:${NC}"
    echo '       AGH_PATH="/opt/AdGuardHome"'
    echo ""
    echo -e "  3. ${CYAN}(Опционально) Настройте Telegram:${NC}"
    echo '       ENABLE_TELEGRAM="true"'
    echo '       TELEGRAM_BOT_TOKEN="ваш_токен"'
    echo '       TELEGRAM_CHAT_ID="ваш_chat_id"'
    echo ""
    echo -e "  4. ${CYAN}Запустите вручную для проверки:${NC}"
    echo "       sudo ${INSTALL_DIR}/${SCRIPT_NAME}"
    echo ""
    echo -e "  5. ${CYAN}Или с уведомлением в Telegram:${NC}"
    echo "       sudo ${INSTALL_DIR}/${SCRIPT_NAME} --telegram"
    echo ""
    echo -e "  ${YELLOW}Справка:${NC}"
    echo "       ${INSTALL_DIR}/${SCRIPT_NAME} --help"
    echo ""
    echo -e "  ${YELLOW}Логи:${NC}"
    echo "       cat /var/log/adguardhome-update.log"
    echo ""
    echo -e "  ${YELLOW}Удаление:${NC}"
    echo "       sudo rm -f ${INSTALL_DIR}/${SCRIPT_NAME}"
    echo "       sudo rm -rf ${CONFIG_DIR}"
    echo "       sudo crontab -l | grep -v '${SCRIPT_NAME}' | sudo crontab -"
    echo ""
}

# Основной поток
main() {
    print_banner
    check_root
    check_dependencies
    check_network
    create_directories
    download_files
    set_permissions
    create_config
    setup_cron
    print_instructions
}

main "$@"
