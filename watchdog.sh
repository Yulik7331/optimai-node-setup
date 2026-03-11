#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
# OptimAI Node Watchdog v6
# Запускается через cron каждые 2 минуты
# v6: fixed process detection (optimai_cli_core/node_cli_core),
#     auth fix via token copy from donor node (OAuth replaced email/password),
#     also kills optimai_cli_core on stop

LOCK_FILE="/var/lock/optimai_watchdog.lock"

# Предотвращаем параллельный запуск
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Watchdog already running, skip"; exit 0; }

CONTAINER_PREFIX="node"
LOG_FILE="/var/log/optimai_watchdog.log"
FAIL_DIR="/var/lib/optimai_watchdog"
MAX_LOG_SIZE=1048576  # 1MB
MAX_SOFT_FAILS=2

# Файлы для хранения токенов-доноров на хосте
AUTH_DONOR_DIR="/var/lib/optimai_watchdog/auth_donor"
mkdir -p "$AUTH_DONOR_DIR" "$FAIL_DIR"

# Ротация лога
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >> "$LOG_FILE"
}

get_fail_count() {
    local f="$FAIL_DIR/$1"
    if [ -f "$f" ]; then cat "$f"; else echo 0; fi
}

set_fail_count() {
    echo "$2" > "$FAIL_DIR/$1"
}

reset_fail_count() {
    rm -f "$FAIL_DIR/$1"
}

# Проверка: работает ли optimai worker внутри контейнера
# CLI запускает optimai_cli_core или node_cli_core как реальный процесс
is_node_running() {
    local container="$1"
    local count
    count=$(lxc exec "$container" </dev/null -- bash -c \
        "ps aux | grep -E 'optimai-cli node start|optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null)
    [ "$count" -gt 0 ]
}

# Найти контейнер-донор с рабочей авторизацией и сохранить его токены
find_auth_donor() {
    local containers
    containers=$(lxc list -c n --format csv 2>/dev/null | grep "^${CONTAINER_PREFIX}[0-9]")
    
    for donor in $containers; do
        if is_node_running "$donor"; then
            local auth_check
            auth_check=$(lxc exec "$donor" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
            if echo "$auth_check" | grep -qi "logged in"; then
                # Сохраняем токены донора на хост
                lxc file pull "$donor/root/.config/optimai-cli/auth.json" "$AUTH_DONOR_DIR/auth.json" 2>/dev/null
                lxc file pull "$donor/root/.config/optimai-cli/user.json" "$AUTH_DONOR_DIR/user.json" 2>/dev/null
                if [ -s "$AUTH_DONOR_DIR/auth.json" ]; then
                    log "AUTH_DONOR: $donor — токены сохранены"
                    return 0
                fi
            fi
        fi
    done
    return 1
}

# Восстановление авторизации через копирование токенов от донора
do_auth_fix() {
    local container="$1"
    
    # Проверяем, есть ли свежие токены донора
    if [ ! -s "$AUTH_DONOR_DIR/auth.json" ]; then
        if ! find_auth_donor; then
            log "AUTH_NO_DONOR: нет рабочих нод для копирования токенов"
            return 1
        fi
    fi
    
    # Копируем токены
    lxc file push "$AUTH_DONOR_DIR/auth.json" "$container/root/.config/optimai-cli/auth.json" 2>/dev/null
    lxc file push "$AUTH_DONOR_DIR/user.json" "$container/root/.config/optimai-cli/user.json" 2>/dev/null
    
    # Ставим правильные права
    lxc exec "$container" </dev/null -- bash -c \
        "chmod 600 /root/.config/optimai-cli/auth.json /root/.config/optimai-cli/user.json" 2>/dev/null
    
    # Проверяем
    local check
    check=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
    if echo "$check" | grep -qi "logged in"; then
        return 0
    fi
    
    # Если не помогло — токены протухли, ищем нового донора
    rm -f "$AUTH_DONOR_DIR/auth.json" "$AUTH_DONOR_DIR/user.json"
    if find_auth_donor; then
        lxc file push "$AUTH_DONOR_DIR/auth.json" "$container/root/.config/optimai-cli/auth.json" 2>/dev/null
        lxc file push "$AUTH_DONOR_DIR/user.json" "$container/root/.config/optimai-cli/user.json" 2>/dev/null
        lxc exec "$container" </dev/null -- bash -c \
            "chmod 600 /root/.config/optimai-cli/auth.json /root/.config/optimai-cli/user.json" 2>/dev/null
        check=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        if echo "$check" | grep -qi "logged in"; then
            return 0
        fi
    fi
    
    return 1
}

# Полная остановка ноды внутри контейнера (все 3 имени процесса)
stop_node() {
    local container="$1"
    lxc exec "$container" </dev/null -- bash -c \
        "pkill -9 -f 'optimai-cli' 2>/dev/null; pkill -9 -f 'optimai_cli_core' 2>/dev/null; pkill -9 -f 'node_cli_core' 2>/dev/null" 2>/dev/null
    sleep 2
}

# Запуск ноды внутри контейнера
start_node() {
    local container="$1"
    stop_node "$container"
    lxc exec "$container" </dev/null -- bash -c "
        mkdir -p /var/log/optimai
        CORE=/root/.optimai/optimai_cli_core
        [ -f /root/.optimai/node_cli_core ] && CORE=/root/.optimai/node_cli_core
        if [ ! -f \$CORE ]; then
            /usr/local/bin/optimai-cli node start &>/dev/null & sleep 5; pkill -f optimai-cli 2>/dev/null; sleep 1
        fi
        nohup \$CORE node start >> /var/log/optimai/node.log 2>&1 &
    " 2>/dev/null
    sleep 15
}

# Получаем ВСЕ контейнеры
ALL_CONTAINERS=$(lxc list -c n,s --format csv 2>/dev/null | grep "^${CONTAINER_PREFIX}[0-9]")

if [ -z "$ALL_CONTAINERS" ]; then
    log "WARNING: Нет контейнеров"
    exit 0
fi

TOTAL=0
RUNNING=0
RESTARTED=0
FAILED=0

# Сначала находим донора токенов (один раз за цикл)
find_auth_donor 2>/dev/null

# ВАЖНО: читаем через fd3, чтобы lxc exec не съедал stdin цикла
while IFS=, read -r -u3 container status; do
    TOTAL=$((TOTAL + 1))

    # Если контейнер LXD остановлен — поднимаем
    if [ "$status" != "RUNNING" ]; then
        log "LXC_STOPPED: $container — запускаю"
        lxc stop "$container" --force 2>/dev/null
        sleep 2
        lxc start "$container" 2>/dev/null
        sleep 10
        NEW_STATUS=$(lxc list -c n,s --format csv 2>/dev/null | grep "^${container}," | cut -d, -f2)
        if [ "$NEW_STATUS" != "RUNNING" ]; then
            FAILED=$((FAILED + 1))
            log "FAIL: $container — LXD не запустился"
            continue
        fi
        log "LXC_STARTED: $container"
        lxc exec "$container" </dev/null -- bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf" 2>/dev/null || true
        sleep 5
    fi

    # === 0. Проверяем авторизацию ===
    AUTH_STATUS=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
    if echo "$AUTH_STATUS" | grep -qi "not authenticated"; then
        log "AUTH_LOST: $container — восстанавливаю токен..."
        if do_auth_fix "$container"; then
            log "AUTH_RESTORED: $container"
        else
            log "AUTH_FAIL: $container — не удалось восстановить авторизацию"
            FAILED=$((FAILED + 1))
            continue
        fi
    fi

    # === 1. Проверяем ноду (по реальным процессам) ===
    if is_node_running "$container"; then
        # Проверяем Docker и crawl4ai только если нода работает
        DOCKER_OK=$(lxc exec "$container" </dev/null -- bash -c "docker info >/dev/null 2>&1 && echo ok" 2>/dev/null)
        CRAWL_STATUS=$(lxc exec "$container" </dev/null -- docker inspect --format '{{.State.Health.Status}}' optimai_crawl4ai_0_7_3 2>/dev/null)

        if [ "$DOCKER_OK" = "ok" ] && [ "$CRAWL_STATUS" != "unhealthy" ]; then
            RUNNING=$((RUNNING + 1))
            reset_fail_count "$container"
            continue
        fi

        # Docker или crawl4ai проблемы
        if [ "$DOCKER_OK" != "ok" ]; then
            log "DOCKER_DOWN: $container — restart docker"
            lxc exec "$container" </dev/null -- systemctl restart docker 2>/dev/null
            sleep 5
        fi
        if [ "$CRAWL_STATUS" = "unhealthy" ]; then
            log "CRAWL4AI_UNHEALTHY: $container — пересоздаю"
            lxc exec "$container" </dev/null -- bash -c \
                "docker stop optimai_crawl4ai_0_7_3 2>/dev/null; docker rm optimai_crawl4ai_0_7_3 2>/dev/null" 2>/dev/null
        fi
    fi

    # Нода не работает — нужен перезапуск
    FAILS=$(get_fail_count "$container")

    if [ "$FAILS" -ge "$MAX_SOFT_FAILS" ]; then
        log "FORCE_RESTART: $container — $FAILS неудач, lxc restart --force"
        lxc restart "$container" --force 2>/dev/null
        sleep 15

        # Re-auth после force restart
        AUTH_CHECK=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        if echo "$AUTH_CHECK" | grep -qi "not authenticated"; then
            log "AUTH_FIX_AFTER_FORCE: $container"
            do_auth_fix "$container"
            sleep 2
        fi

        start_node "$container"

        if is_node_running "$container"; then
            RESTARTED=$((RESTARTED + 1))
            reset_fail_count "$container"
            log "OK: $container — перезапущена после force restart"
        else
            FAILED=$((FAILED + 1))
            set_fail_count "$container" 0
            log "FAIL: $container — не запустилась после force restart"
        fi
        continue
    fi

    # Мягкий перезапуск
    log "RESTART: $container — Node not running (попытка $((FAILS + 1)))"

    # Restart docker if needed
    lxc exec "$container" </dev/null -- bash -c \
        "systemctl is-active docker >/dev/null 2>&1 || { systemctl restart docker; sleep 5; }" 2>/dev/null

    start_node "$container"

    if is_node_running "$container"; then
        RESTARTED=$((RESTARTED + 1))
        reset_fail_count "$container"
        log "OK: $container — перезапущена"
    else
        FAILED=$((FAILED + 1))
        set_fail_count "$container" $((FAILS + 1))
        log "FAIL: $container — не запустилась (сбой #$((FAILS + 1)))"
    fi
done 3<<< "$ALL_CONTAINERS"

# Логируем итог всегда
log "SUMMARY: Всего=$TOTAL, Работали=$RUNNING, Перезапущено=$RESTARTED, Ошибки=$FAILED"
