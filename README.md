# 🛠️ Скрипт автоматического обновления AdGuard Home

Этот Bash-скрипт автоматизирует обновление [AdGuard Home](https://adguard.com/ru/adguard-home-overview.html) на Linux-серверах. Он проверяет наличие новой версии, скачивает её, создаёт резервные копии конфигурации и данных, а также управляет старыми копиями, сохраняя только две последние. Скрипт включает тщательные проверки всех условий, что делает его надёжным для использования в рабочих окружениях, а компактное логирование упрощает диагностику.

---

## Установка

### 🚀 Быстрая установка (одна команда)

```bash
curl -sSL https://raw.githubusercontent.com/wobujidao/adguardhome-auto-update/main/install.sh | sudo bash
```

Установщик автоматически:
- Проверит права root и наличие зависимостей
- Скачает скрипт обновления и пример конфигурации
- Установит правильные права доступа
- Создаст конфигурационный файл из примера
- Настроит ежедневное обновление через cron (в 00:00)

### 🔧 Ручная установка

1. **Скачайте скрипт**:
   Склонируйте репозиторий или скачайте `update-adguardhome.sh`:
   ```bash
   git clone https://github.com/wobujidao/adguardhome-auto-update.git
   cd adguardhome-auto-update
   ```

2. **Переместите в системную директорию**:
   Скопируйте скрипт в `/usr/local/bin`:
   ```bash
   sudo cp update-adguardhome.sh /usr/local/bin/update-adguardhome.sh
   ```

3. **Сделайте исполняемым**:
   Установите права на выполнение:
   ```bash
   sudo chmod +x /usr/local/bin/update-adguardhome.sh
   ```

---

Полная документация доступна в [Репозитории](https://github.com/wobujidao/adguardhome-auto-update) и в файле [installation_guide.md](installation_guide.md).

## Лицензия

📜 Проект распространяется под лицензией MIT. Подробности см. в файле [LICENSE](LICENSE).
