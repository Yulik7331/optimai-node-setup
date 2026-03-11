# OptimAI Node Setup

Автоматический установщик и watchdog для запуска OptimAI нод в LXD контейнерах.

## Установка (одна команда)

```bash
curl -sL https://raw.githubusercontent.com/Yulik7331/optimai-node-setup/main/install.sh -o install.sh && chmod +x install.sh && bash install.sh
```

## Что внутри

| Файл | Описание |
|------|----------|
| `install.sh` | Полный установщик v2.0 — от чистого сервера до работающих нод |
| `watchdog.sh` | Watchdog v6 — мониторинг, авто-перезапуск, восстановление авторизации |

## Требования

- Ubuntu 22.04+ (чистый сервер)
- Root доступ
- Минимум 4GB RAM на каждую ноду (рекомендуется 64GB+ для 30 нод)
- Браузер для OAuth авторизации (один раз)

## Быстрый старт

```bash
# 1. Клонируем
git clone git@github.com:Yulik7331/optimai-node-setup.git
cd optimai-node-setup

# 2. Запускаем установщик
bash install.sh
```

Выбираем **пункт 1** для полной автоматической установки, или запускаем этапы по отдельности.

## Этапы установки

| # | Этап | Что делает |
|---|------|-----------|
| 1 | Система | Обновление пакетов, установка snapd, curl, модули ядра |
| 2 | SWAP | Создание swap-файла (рекомендуется = размеру RAM) |
| 3 | LXD | Установка LXD, создание контейнеров Ubuntu 22.04 |
| 4 | Docker | Установка Docker (overlay2) + загрузка образа crawl4ai в каждый контейнер |
| 5 | OptimAI CLI | Установка CLI + OAuth авторизация (логин через браузер в 1 ноду, токен копируется в остальные) |
| 6 | Запуск нод | Запуск `optimai-cli node start` во всех контейнерах |
| 7 | Watchdog | Установка watchdog v6 + OOM-защита + cron (каждые 5 мин) |

## OAuth авторизация

CLI v0.1.47+ использует OAuth через браузер (не email/password).

При установке (этап 5):
1. Скрипт покажет URL — скопируй и открой в браузере
2. Залогинься или зарегистрируйся на сайте OptimAI
3. После логина появится страница **"Complete CLI sign-in"** с кодом
4. Нажми **"Copy code"** (или **"Copy callback URL"**)
5. Вернись в терминал и вставь код/URL когда CLI попросит `Paste the redirected URL (or just the code parameter):`
6. Токен автоматически скопируется во все остальные ноды

> Токены НЕ привязаны к `device_id` — можно безопасно копировать между нодами.

## Watchdog v6

Автоматически следит за всеми нодами и восстанавливает их при сбоях.

**Что проверяет:**
- LXD контейнер запущен
- Авторизация активна (токен не протух)
- Worker процесс работает (`optimai_cli_core` / `node_cli_core`)
- Docker и crawl4ai контейнер здоровы

**Что делает при проблемах:**
- Перезапускает упавший LXD контейнер
- Копирует свежий токен от работающей ноды-донора
- Перезапускает worker процесс
- После 2 неудач — делает `lxc restart --force`
- Пересоздаёт unhealthy crawl4ai контейнер

**Логи:**
```bash
# Последние записи watchdog
tail -50 /var/log/optimai_watchdog.log

# Счётчики сбоев
ls /var/lib/optimai_watchdog/

# Кешированные токены донора
ls /var/lib/optimai_watchdog/auth_donor/
```

## Проверка статуса

```bash
# Через меню установщика (пункт 9)
bash install.sh

# Или вручную — сколько нод работает
for c in $(lxc list -c n --format csv); do
  pid=$(lxc exec "$c" </dev/null -- bash -c \
    "ps aux | grep -E 'optimai-cli node start|optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null)
  [ "$pid" -gt 0 ] && echo "$c: OK" || echo "$c: DOWN"
done
```

## Структура на сервере

```
/root/
├── optimai_watchdog.sh          # Watchdog v6 (cron каждые 5 мин)
├── optimai_oom_protect.sh       # OOM-защита (cron @reboot)
├── optimai-node-setup/          # Этот репозиторий
│   ├── install.sh
│   ├── watchdog.sh
│   └── README.md
├── /var/log/
│   └── optimai_watchdog.log     # Лог watchdog
└── /var/lib/optimai_watchdog/
    ├── auth_donor/              # Кеш токенов донора
    │   ├── auth.json
    │   └── user.json
    └── node*/                   # Счётчики сбоев нод
```

## Ресурсы (примерные, 30 нод)

| Компонент | RAM | CPU |
|-----------|-----|-----|
| 30 LXD нод (idle) | ~15 GB | ~360% |
| 30 LXD нод (под нагрузкой) | ~25-30 GB | ~800%+ |
| Рекомендуемый минимум | 64 GB | 16 cores |
