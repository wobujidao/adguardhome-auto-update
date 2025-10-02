# 🚀 Инструкция по установке AdGuard Home Auto-Update v2.0

## Что нового в версии 2.0

✨ **Основные изменения:**

- 📁 **Внешний конфигурационный файл** — все настройки вынесены из скрипта
- 🔒 **Безопасность** — токены и пароли не хранятся в коде
- ⚙️ **Гибкая настройка** — поддержка нескольких путей поиска конфига
- 🆕 **Новые опции** — `--config`, `--help`, `--telegram`
- 🔧 **Улучшенная обработка ошибок** — лучшая диагностика и логирование

## Быстрая установка

### 1. Скачайте файлы

```bash
# Создайте директорию для конфигурации
sudo mkdir -p /usr/local/bin

# Скачайте скрипт
sudo wget -O /usr/local/bin/update-adguardhome.sh \
  https://raw.githubusercontent.com/wobujidao/adguardhome-auto-update/main/update-adguardhome.sh

# Скачайте пример конфигурации
sudo wget -O /usr/local/bin/config.conf.example \
  https://raw.githubusercontent.com/wobujidao/adguardhome-auto-update/main/config.conf.example
```

### 2. Настройте права доступа

```bash
# Сделайте скрипт исполняемым
sudo chmod +x /usr/local/bin/update-adguardhome.sh

# Установите права на конфигурацию
sudo chmod 600 /usr/local/bin/config.conf*
sudo chown root:root /usr/local/bin/config.conf*
```

### 3. Создайте конфигурационный файл

```bash
# Скопируйте пример конфигурации
sudo cp /usr/local/bin/config.conf.example /usr/local/bin/config.conf

# Установите безопасные права доступа
sudo chmod 600 /usr/local/bin/config.conf
sudo chown root:root /usr/local/bin/config.conf
```

### 4. Настройте конфигурацию

```bash
# Отредактируйте конфигурационный файл
sudo nano /usr/local/bin/config.conf
```

**Минимальные настройки для работы:**

- Убедитесь, что `AGH_PATH` указывает на правильную директорию AdGuard Home (`/opt/AdGuardHome`)
- При необходимости измените `ARCH` (для ARM-серверов)
- Настройте `DNS_SERVERS` если нужно

**Для Telegram-уведомлений:**

```bash
ENABLE_TELEGRAM="true"
TELEGRAM_BOT_TOKEN="ваш_токен_от_BotFather"
TELEGRAM_CHAT_ID="ваш_chat_id"
SERVER_NAME="имя_вашего_сервера"
```

## Расположения конфигурационного файла

Скрипт ищет конфигурационный файл в следующем порядке:

1. `/etc/adguardhome-updater/config.conf` ← **рекомендуется**
2. `/usr/local/etc/adguardhome-updater/config.conf`
3. `./config.conf` (в текущей директории)
4. `config.conf` (рядом со скриптом)

## Использование

### Базовые команды

```bash
# Проверка и обновление (если нужно)
sudo /usr/local/bin/update-adguardhome.sh

# Принудительное Telegram-уведомление
sudo /usr/local/bin/update-adguardhome.sh --telegram

# Использование другого конфиг-файла
sudo /usr/local/bin/update-adguardhome.sh --config /path/to/your/config.conf

# Показать справку
/usr/local/bin/update-adguardhome.sh --help
```

### Настройка автоматических обновлений

```bash
# Откройте crontab
sudo crontab -e

# Добавьте строку для ежедневного запуска в 12:00
0 12 * * * /usr/local/bin/update-adguardhome.sh

# Или с Telegram-уведомлениями
0 12 * * * /usr/local/bin/update-adguardhome.sh --telegram
```

## Настройка Telegram-уведомлений

### 1. Создайте Telegram-бота

1. Найдите [@BotFather](https://t.me/BotFather) в Telegram
2. Отправьте `/start`, затем `/newbot`
3. Следуйте инструкциям и получите токен бота
4. Скопируйте токен (например: `123456789:ABCDEF1234567890abcdef1234567890ABC`)

### 2. Получите Chat ID

**Для личного чата:**

1. Напишите сообщение вашему боту
2. Найдите [@getidsbot](https://t.me/getidsbot) и отправьте `/start`
3. Скопируйте ваш User ID

**Для группы/канала:**

1. Добавьте бота в группу/канала как администратора
2. Используйте ID группы/канала (начинается с `-`)

### 3. Настройте конфигурацию

Отредактируйте `/usr/local/bin/config.conf`:

```bash
ENABLE_TELEGRAM="true"
TELEGRAM_BOT_TOKEN="123456789:ABCDEF1234567890abcdef1234567890ABC"
TELEGRAM_CHAT_ID="123456789"  # или "-1001234567890" для группы
SERVER_NAME="мой-сервер"
```

### 4. Протестируйте уведомления

```bash
# Тест с принудительным уведомлением
sudo /usr/local/bin/update-adguardhome.sh --telegram
```

## Примеры конфигураций

### Стандартный сервер с Telegram

```bash
AGH_PATH="/opt/AdGuardHome"
BACKUP_DIR="/opt/AdGuardHome/backup"
LOG_PATH="/var/log/adguardhome-update.log"
SERVICE_NAME="adguardhome.service"

ENABLE_TELEGRAM="true"
TELEGRAM_BOT_TOKEN="ваш_токен"
TELEGRAM_CHAT_ID="ваш_chat_id"
SERVER_NAME="production-server"

DNS_SERVERS="1.1.1.1 1.0.0.1"
MAX_BACKUP_COUNT=7
MAX_LOG_SIZE=5242880
```

### ARM-сервер (Raspberry Pi)

```bash
AGH_PATH="/home/pi/AdGuardHome"
BACKUP_DIR="/home/pi/AdGuardHome/backup"
LOG_PATH="/var/log/adguardhome-update.log"
SERVICE_NAME="adguardhome.service"

DNS_SERVERS="77.88.8.8 77.88.8.1"
MAX_BACKUP_COUNT=7
MAX_LOG_SIZE=5242880
```

### Сервер без Telegram

```bash
ENABLE_TELEGRAM="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
MAX_BACKUP_COUNT=5
MAX_LOG_SIZE=5242880
```

## Устранение неполадок

### Конфигурационный файл не найден

```text
ОШИБКА: Конфигурационный файл не найден!
```

**Решение:**

1. Убедитесь, что файл существует: `ls -la /usr/local/bin/config.conf`
2. Проверьте права доступа: `sudo chmod 600 /usr/local/bin/config.conf`
3. Используйте `--config` для указания пути: `--config /path/to/config.conf`

### Отсутствуют обязательные параметры

```text
ОШИБКА: В конфигурационном файле отсутствуют обязательные параметры:
AGH_PATH
```

**Решение:**

1. Скопируйте пример: `sudo cp config.conf.example config.conf`
2. Отредактируйте конфигурацию: `sudo nano /usr/local/bin/config.conf`

### Проблемы с Telegram

**Решение:**

1. Проверьте токен бота: `curl -s "https://api.telegram.org/bot<TOKEN>/getMe"`
2. Убедитесь, что бот добавлен в чат/группу
3. Проверьте Chat ID
4. Используйте `--telegram` для тестирования

### Проблемы с правами доступа

**Решение:**

```bash
# Восстановите права
sudo chown root:root /usr/local/bin/config.conf
sudo chmod 600 /usr/local/bin/config.conf
sudo chown root:root /usr/local/bin/update-adguardhome.sh
sudo chmod +x /usr/local/bin/update-adguardhome.sh
```

## Безопасность

🔒 **Важные моменты безопасности:**

1. **Права доступа к конфигурации:**

   ```bash
   chmod 600 /usr/local/bin/config.conf
   chown root:root /usr/local/bin/config.conf
   ```

2. **Не добавляйте конфиг в Git:**
   Добавьте в `.gitignore`:

   ```text
   config.conf
   *.conf
   ```

3. **Токены Telegram:**
   - Никогда не публикуйте токены в открытых репозиториях
   - Регулярно обновляйте токены боботов
   - Используйте отдельных ботов для разных серверов

4. **Резервные копии:**
   - Регулярно проверяйте содержимое директории резервных копий
   - Рассмотрите шифрование резервных копий для чувствительных данных

---

## Поддержка

Если у вас возникли проблемы:

1. Проверьте логи: `sudo tail -n 200 /var/log/adguardhome-update.log`
2. Запустите с отладкой: `bash -x /usr/local/bin/update-adguardhome.sh`
3. Создайте Issue на GitHub: [GitHub Issues](https://github.com/wobujidao/adguardhome-auto-update/issues)

---

**Готово!** Теперь у вас есть безопасная и гибкая система автообновления AdGuard Home с внешним конфигурационным файлом. 🎉
