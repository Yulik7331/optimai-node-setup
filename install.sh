#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════╗
# ║  OptimAI Full Installer v2.0                                     ║
# ║  LXD + Docker + OptimAI ноды + Watchdog v6 (OAuth token copy)   ║
# ║  Запуск: bash optimai_install_v2.sh                              ║
# ╚═══════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ╔═══════════════════════════════════════════════════════════════════╗
# ║  КОНФИГУРАЦИЯ — заполни перед запуском для автоматического режима ║
# ║  Если оставить пустым — скрипт спросит интерактивно              ║
# ╚═══════════════════════════════════════════════════════════════════╝

# Количество нод (LXD контейнеров) для создания
NODE_COUNT=""          # например: 30

# Размер SWAP в GB (пусто = спросит, 0 = пропустить)
SWAP_SIZE_GB=""        # например: 64

# ===================== СИСТЕМНЫЕ ПУТИ =====================
CONTAINER_PREFIX="node"
WATCHDOG_FILE="/root/optimai_watchdog.sh"
OOM_PROTECT_FILE="/root/optimai_oom_protect.sh"
LOG_FILE="/var/log/optimai_install.log"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ===================== УТИЛИТЫ =====================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

info()    { echo -e "${CYAN}[INFO]${NC} $1"; log "INFO: $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; log "OK: $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }

banner() {
    echo ""
    echo -e "${PURPLE}══════════════════════════════════════════${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${PURPLE}══════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Запусти скрипт от root: sudo bash $0"
        exit 1
    fi
}

check_virtualization() {
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    case "$virt" in
        openvz|lxc|lxc-libvirt)
            error "Виртуализация $virt НЕ поддерживает LXD (нестинг контейнеров)."
            error "Нужен KVM, VMware, bare metal или Hyper-V."
            exit 1
            ;;
        *)
            info "Виртуализация: $virt — OK"
            ;;
    esac
}

detect_default_iface() {
    local iface
    # Исключаем VPN/tunnel интерфейсы, берём физический
    iface=$(ip route | grep "^default" | grep -v "tun\|wg\|tailscale" | awk '{print $5}' | head -1)
    [ -z "$iface" ] && iface=$(ip route | grep "^default" | awk '{print $5}' | head -1)
    echo "$iface"
}

wait_container_ready() {
    local name="$1"
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if lxc exec "$name" -- bash -c "echo ready" &>/dev/null; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# ===================== ЭТАП 1: СИСТЕМА =====================

install_system_deps() {
    banner "ЭТАП 1/7: Обновление системы"

    check_virtualization

    info "ОС: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    info "CPU: $(nproc) cores | RAM: $(free -h | awk '/Mem:/{print $2}') | Disk: $(df -h / | tail -1 | awk '{print $4}') free"

    info "Обновление пакетов..."
    apt-get update -qq
    apt-get upgrade -y -qq

    info "Установка зависимостей..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snapd curl ca-certificates gnupg iptables-persistent

    # Модули ядра для Docker overlay2 в LXD
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    cat > /etc/modules-load.d/lxd-docker.conf <<EOF
overlay
br_netfilter
EOF

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    success "Система подготовлена"
}

# ===================== ЭТАП 2: SWAP =====================

setup_swap() {
    banner "ЭТАП 2/7: Настройка SWAP"

    if [ "${SWAP_SIZE_GB:-}" = "0" ]; then
        info "SWAP пропущен (SWAP_SIZE_GB=0)"
        return
    fi

    local current_swap
    current_swap=$(swapon --show --noheadings 2>/dev/null | wc -l)

    if [ "$current_swap" -gt 0 ]; then
        info "SWAP уже настроен:"
        swapon --show
        free -h | grep Swap
        if [ -z "${SWAP_SIZE_GB:-}" ]; then
            echo ""
            read -p "Пересоздать SWAP? [y/N]: " recreate
            if [[ ! "$recreate" =~ ^[Yy]$ ]]; then
                success "SWAP оставлен без изменений"
                return
            fi
        else
            info "Пересоздаю SWAP (SWAP_SIZE_GB=$SWAP_SIZE_GB)..."
        fi
        local old_swap
        old_swap=$(swapon --show --noheadings | awk '{print $1}' | head -1)
        swapoff "$old_swap" 2>/dev/null || true
        rm -f "$old_swap"
        sed -i "\|$old_swap|d" /etc/fstab
    fi

    local ram_gb
    ram_gb=$(free -g | awk '/Mem:/{print $2}')
    local recommended=$((ram_gb < 16 ? ram_gb * 2 : ram_gb))
    [ "$recommended" -gt 128 ] && recommended=64

    local swap_size="${SWAP_SIZE_GB:-}"
    if [ -z "$swap_size" ]; then
        read -p "Размер SWAP в GB (рекомендуется ${recommended}GB для ${ram_gb}GB RAM) [${recommended}]: " swap_size
        swap_size=${swap_size:-$recommended}
    fi

    if ! [[ "$swap_size" =~ ^[0-9]+$ ]] || [ "$swap_size" -lt 1 ] || [ "$swap_size" -gt 256 ]; then
        error "Неверный размер: $swap_size"
        return 1
    fi

    info "Создаю SWAP ${swap_size}GB..."
    dd if=/dev/zero of=/swapfile bs=1G count="$swap_size" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

    success "SWAP ${swap_size}GB создан"
    free -h | grep Swap
}

# ===================== ЭТАП 3: LXD =====================

install_lxd() {
    banner "ЭТАП 3/7: Установка LXD и создание контейнеров"

    if ! command -v lxc &>/dev/null; then
        info "Установка LXD..."
        snap install lxd --channel=5.21/stable
        sleep 5
        lxd init --auto
        success "LXD установлен"
    else
        success "LXD уже установлен"
    fi

    if ! lxc network show lxdbr0 &>/dev/null; then
        info "Создание сети..."
        lxc network create lxdbr0 ipv4.nat=true ipv6.address=none
    fi

    if ! lxc storage show default &>/dev/null; then
        info "Создание хранилища..."
        lxc storage create default dir
    fi

    lxc profile device remove default eth0 2>/dev/null || true
    lxc profile device add default eth0 nic name=eth0 network=lxdbr0 2>/dev/null || true
    lxc profile device remove default root 2>/dev/null || true
    lxc profile device add default root disk path=/ pool=default 2>/dev/null || true

    # --- Фикс сети: iptables FORWARD + NAT для LXD ---
    local lxd_subnet
    lxd_subnet=$(lxc network show lxdbr0 2>/dev/null | grep "ipv4.address" | awk '{print $2}' | sed 's|\.[0-9]*/|.0/|')
    local default_iface
    default_iface=$(detect_default_iface)

    if [ -n "$lxd_subnet" ] && [ -n "$default_iface" ]; then
        info "Настройка iptables: LXD ($lxd_subnet) -> $default_iface"
        # FORWARD: разрешить трафик LXD <-> интернет
        iptables -C FORWARD -i lxdbr0 -o "$default_iface" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD 1 -i lxdbr0 -o "$default_iface" -j ACCEPT
        iptables -C FORWARD -i "$default_iface" -o lxdbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD 2 -i "$default_iface" -o lxdbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        # NAT: маскарадинг
        iptables -t nat -C POSTROUTING -s "$lxd_subnet" -o "$default_iface" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING 1 -s "$lxd_subnet" -o "$default_iface" -j MASQUERADE
        # Сохраняем правила (переживут ребут)
        netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        success "iptables настроен и сохранён"
    else
        warn "Не удалось определить подсеть LXD или интерфейс. Настрой iptables вручную."
    fi

    local existing=0 max_existing=0
    existing=$(lxc list -c n --format csv 2>/dev/null | grep -cE "^${CONTAINER_PREFIX}[0-9]+" || true)
    if [ "$existing" -gt 0 ]; then
        max_existing=$(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
        info "Существует контейнеров: $existing (последний: ${CONTAINER_PREFIX}${max_existing})"
    fi

    local total="${NODE_COUNT:-}"
    if [ -z "$total" ]; then
        read -p "Сколько ВСЕГО нод нужно? [текущих: $existing]: " total
    else
        info "NODE_COUNT=$total (из конфигурации)"
    fi
    if ! [[ "$total" =~ ^[0-9]+$ ]] || [ "$total" -le "$existing" ]; then
        success "Новые контейнеры не нужны"
        return
    fi

    local created=0
    for i in $(seq $((max_existing + 1)) "$total"); do
        local name="${CONTAINER_PREFIX}${i}"
        info "Создаю $name..."

        lxc launch ubuntu:22.04 "$name" || { error "Не удалось создать $name"; continue; }

        lxc config set "$name" security.privileged true
        lxc config set "$name" security.nesting true
        lxc config set "$name" linux.kernel_modules overlay,br_netfilter,ip_tables,iptable_nat,xt_conntrack
        lxc config set "$name" raw.lxc "lxc.apparmor.profile=unconfined
lxc.mount.auto=proc:rw sys:rw cgroup:rw
lxc.cgroup.devices.allow=a
lxc.cap.drop="
        lxc config set "$name" limits.processes 2500

        lxc restart "$name"
        wait_container_ready "$name" || { error "$name не стартовал"; continue; }

        # Fix DNS inside container (persistent — survives restart)
        lxc exec "$name" -- bash -c "
            mkdir -p /etc/systemd/resolved.conf.d
            cat > /etc/systemd/resolved.conf.d/dns.conf <<DNSEOF
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4
DNSEOF
            systemctl restart systemd-resolved 2>/dev/null || true
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
            echo 'nameserver 8.8.8.8' > /etc/resolv.conf 2>/dev/null || true
        " 2>/dev/null || true

        created=$((created + 1))
        success "$name создан"
    done

    success "Создано контейнеров: $created"
}

# ===================== ЭТАП 4: DOCKER =====================

setup_docker() {
    banner "ЭТАП 4/7: Установка Docker в контейнерах"

    local containers
    containers=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sort -V)
    [ -z "$containers" ] && { error "Нет контейнеров"; return 1; }

    local total=0 skipped=0 installed=0 failed=0
    for container in $containers; do
        total=$((total + 1))

        local driver
        driver=$(lxc exec "$container" -- bash -c "docker info --format '{{.Driver}}' 2>/dev/null" 2>/dev/null || echo "none")
        if [ "$driver" = "overlay2" ]; then
            skipped=$((skipped + 1))
            echo -e "  ${GREEN}✓${NC} $container — Docker overlay2 OK"
            continue
        fi

        info "$container — устанавливаю Docker..."
        lxc exec "$container" -- bash <<'DOCKERSCRIPT'
set -e
systemctl stop docker 2>/dev/null || true
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
rm -rf /var/lib/docker /etc/docker

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
JSON

systemctl daemon-reload
systemctl enable docker
systemctl restart docker
sleep 5

DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null)
[ "$DRIVER" = "overlay2" ] || { echo "FAIL: driver=$DRIVER"; exit 1; }

# Предзагрузка crawl4ai
IMAGE="unclecode/crawl4ai:0.7.3"
for attempt in 1 2 3; do
    if docker pull "$IMAGE" 2>/dev/null; then
        break
    fi
    [ "$attempt" -lt 3 ] && sleep 10
done
DOCKERSCRIPT

        if [ $? -eq 0 ]; then
            installed=$((installed + 1))
            success "$container — Docker установлен"
        else
            failed=$((failed + 1))
            error "$container — ошибка установки Docker"
        fi
        sleep 1
    done

    echo ""
    info "Итого: $total | Уже было: $skipped | Установлено: $installed | Ошибок: $failed"
}

# ===================== ЭТАП 5: OPTIMAI CLI + AUTH =====================

install_optimai_cli() {
    banner "ЭТАП 5/7: Установка OptimAI CLI и авторизация"

    local containers
    containers=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sort -V)
    [ -z "$containers" ] && { error "Нет контейнеров"; return 1; }

    # --- Шаг 1: Установка CLI во все контейнеры ---
    info "Установка CLI..."
    local installed=0
    for container in $containers; do
        echo -ne "  $container: "
        if lxc exec "$container" -- test -f /usr/local/bin/optimai-cli 2>/dev/null; then
            echo -e "${GREEN}CLI есть${NC}"
            continue
        fi
        echo -ne "установка... "
        lxc exec "$container" -- bash -c "
            curl -sL https://optimai.network/download/cli-node/linux -o /tmp/optimai-cli && \
            chmod +x /tmp/optimai-cli && \
            mv /tmp/optimai-cli /usr/local/bin/optimai-cli
        " 2>/dev/null || { echo -e "${RED}FAIL${NC}"; continue; }
        installed=$((installed + 1))
        echo -e "${GREEN}OK${NC}"
    done
    [ "$installed" -gt 0 ] && success "CLI установлен в $installed контейнерах"

    # --- Шаг 2: Авторизация через браузер (1 нода) ---
    echo ""
    info "Авторизация OptimAI (OAuth через браузер)"
    echo ""
    echo -e "  ${YELLOW}CLI v0.1.47+ использует OAuth — нужно залогиниться через браузер.${NC}"
    echo -e "  ${YELLOW}Логин нужен ТОЛЬКО в одну ноду — токен будет скопирован в остальные.${NC}"
    echo ""

    # Ищем уже авторизованную ноду
    local donor=""
    for container in $containers; do
        local auth_st
        auth_st=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        if echo "$auth_st" | grep -qi "logged in"; then
            donor="$container"
            success "Найдена авторизованная нода: $donor"
            break
        fi
    done

    if [ -z "$donor" ]; then
        # Выбираем первую ноду для логина
        donor=$(echo "$containers" | head -1)
        info "Запускаю логин в $donor..."
        echo ""
        echo -e "  ${BOLD}Порядок действий:${NC}"
        echo -e "  1. Сейчас появится URL — скопируй и открой в браузере"
        echo -e "  2. Залогинься или зарегистрируйся на сайте OptimAI"
        echo -e "  3. Появится страница ${CYAN}Complete CLI sign-in${NC} с кодом"
        echo -e "  4. Нажми ${CYAN}Copy code${NC} (или ${CYAN}Copy callback URL${NC})"
        echo -e "  5. Вернись в терминал и вставь код/URL когда CLI попросит"
        echo ""
        echo -e "  ${CYAN}Запускаю интерактивный логин...${NC}"
        echo ""

        # Запускаем логин ИНТЕРАКТИВНО (stdin подключен для вставки redirect URL)
        lxc exec "$donor" -- optimai-cli auth login

        # Проверяем
        local auth_check
        auth_check=$(lxc exec "$donor" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        if echo "$auth_check" | grep -qi "logged in"; then
            success "Авторизация $donor — OK"
        else
            error "Авторизация не удалась. Попробуй вручную: lxc exec $donor -- optimai-cli auth login"
            return 1
        fi
    fi

    # --- Шаг 3: Копируем токен от донора во все остальные ноды ---
    info "Копирование токена из $donor во все ноды..."
    mkdir -p /var/lib/optimai_watchdog/auth_donor

    lxc file pull "$donor/root/.config/optimai-cli/auth.json" /var/lib/optimai_watchdog/auth_donor/auth.json 2>/dev/null
    lxc file pull "$donor/root/.config/optimai-cli/user.json" /var/lib/optimai_watchdog/auth_donor/user.json 2>/dev/null

    if [ ! -s /var/lib/optimai_watchdog/auth_donor/auth.json ]; then
        error "Не удалось получить токен от $donor"
        return 1
    fi

    local authed=0 auth_failed=0
    for container in $containers; do
        if [ "$container" = "$donor" ]; then
            authed=$((authed+1))
            printf "  %-12s %b\n" "$container" "${GREEN}донор${NC}"
            continue
        fi

        lxc exec "$container" </dev/null -- bash -c "mkdir -p /root/.config/optimai-cli" &>/dev/null
        lxc file push /var/lib/optimai_watchdog/auth_donor/auth.json "$container/root/.config/optimai-cli/auth.json" &>/dev/null
        lxc file push /var/lib/optimai_watchdog/auth_donor/user.json "$container/root/.config/optimai-cli/user.json" &>/dev/null
        lxc exec "$container" </dev/null -- bash -c \
            "chmod 600 /root/.config/optimai-cli/auth.json /root/.config/optimai-cli/user.json" &>/dev/null

        local check
        check=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        if echo "$check" | grep -qi "logged in"; then
            printf "  %-12s %b\n" "$container" "${GREEN}OK${NC}"
            authed=$((authed + 1))
        else
            printf "  %-12s %b\n" "$container" "${RED}FAIL${NC}"
            auth_failed=$((auth_failed + 1))
        fi
    done

    echo ""
    info "Авторизовано: $authed | Ошибок: $auth_failed"
}

# ===================== ЭТАП 6: ЗАПУСК НОД =====================

start_all_nodes() {
    banner "ЭТАП 6/7: Запуск нод"

    local containers
    containers=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sort -V)
    [ -z "$containers" ] && { error "Нет контейнеров"; return 1; }

    local started=0 already=0 failed=0
    for container in $containers; do
        # Проверяем по реальным процессам (optimai_cli_core / node_cli_core)
        local running
        running=$(lxc exec "$container" </dev/null -- bash -c \
            "ps aux | grep -E 'optimai-cli node start|optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null)
        if [ "${running:-0}" -gt 0 ]; then
            printf "  %-12s %b\n" "$container" "${GREEN}уже работает${NC}"
            already=$((already + 1))
            continue
        fi

        lxc exec "$container" </dev/null -- bash -c "
            pkill -9 -f 'optimai-cli' 2>/dev/null || true
            pkill -9 -f 'optimai_cli_core' 2>/dev/null || true
            pkill -9 -f 'node_cli_core' 2>/dev/null || true
            sleep 2
            mkdir -p /var/log/optimai
            CORE=/root/.optimai/optimai_cli_core
            [ -f /root/.optimai/node_cli_core ] && CORE=/root/.optimai/node_cli_core
            if [ ! -f \$CORE ]; then
                /usr/local/bin/optimai-cli node start &>/dev/null &
                sleep 5
                pkill -f optimai-cli 2>/dev/null || true
                sleep 1
            fi
            nohup \$CORE node start >> /var/log/optimai/node.log 2>&1 &
        " &>/dev/null || true

        sleep 15

        running=$(lxc exec "$container" </dev/null -- bash -c \
            "ps aux | grep -E 'optimai-cli node start|optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null || echo 0)
        if [ "${running:-0}" -gt 0 ]; then
            printf "  %-12s %b\n" "$container" "${GREEN}запущен${NC}"
            started=$((started + 1))
        else
            printf "  %-12s %b\n" "$container" "${RED}FAIL${NC}"
            failed=$((failed + 1))
        fi
    done

    echo ""
    info "Запущено: $started | Уже работали: $already | Ошибок: $failed"
}

# ===================== ЭТАП 7: WATCHDOG v6 + CRON =====================

install_watchdog() {
    banner "ЭТАП 7/7: Установка Watchdog v6 и OOM-защиты"

    info "Установка watchdog v6..."

    cat > "$WATCHDOG_FILE" <<'WATCHDOG'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
# OptimAI Node Watchdog v6
# Cron: каждые 5 минут
# v6: process detection by optimai_cli_core/node_cli_core,
#     auth fix via token copy from donor (OAuth, not email/password)

LOCK_FILE="/var/lock/optimai_watchdog.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Watchdog already running, skip"; exit 0; }

CONTAINER_PREFIX="node"
LOG_FILE="/var/log/optimai_watchdog.log"
FAIL_DIR="/var/lib/optimai_watchdog"
MAX_LOG_SIZE=1048576
MAX_SOFT_FAILS=2
AUTH_DONOR_DIR="/var/lib/optimai_watchdog/auth_donor"

mkdir -p "$AUTH_DONOR_DIR" "$FAIL_DIR"

[ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ] && mv "$LOG_FILE" "${LOG_FILE}.old"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
get_fail_count() { local f="$FAIL_DIR/$1"; [ -f "$f" ] && cat "$f" || echo 0; }
set_fail_count() { echo "$2" > "$FAIL_DIR/$1"; }
reset_fail_count() { rm -f "$FAIL_DIR/$1"; }

is_node_running() {
    local container="$1"
    local count
    count=$(lxc exec "$container" </dev/null -- bash -c \
        "ps aux | grep -E 'optimai-cli node start|optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null)
    [ "$count" -gt 0 ]
}

find_auth_donor() {
    local containers
    containers=$(lxc list -c n --format csv 2>/dev/null | grep "^${CONTAINER_PREFIX}[0-9]")
    for donor in $containers; do
        if is_node_running "$donor"; then
            local auth_check
            auth_check=$(lxc exec "$donor" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
            if echo "$auth_check" | grep -qi "logged in"; then
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

do_auth_fix() {
    local container="$1"
    if [ ! -s "$AUTH_DONOR_DIR/auth.json" ]; then
        find_auth_donor || { log "AUTH_NO_DONOR: нет рабочих нод"; return 1; }
    fi
    lxc exec "$container" </dev/null -- bash -c "mkdir -p /root/.config/optimai-cli" 2>/dev/null
    lxc file push "$AUTH_DONOR_DIR/auth.json" "$container/root/.config/optimai-cli/auth.json" 2>/dev/null
    lxc file push "$AUTH_DONOR_DIR/user.json" "$container/root/.config/optimai-cli/user.json" 2>/dev/null
    lxc exec "$container" </dev/null -- bash -c \
        "chmod 600 /root/.config/optimai-cli/auth.json /root/.config/optimai-cli/user.json" 2>/dev/null
    local check
    check=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
    if echo "$check" | grep -qi "logged in"; then return 0; fi
    # Токены протухли — ищем нового донора
    rm -f "$AUTH_DONOR_DIR/auth.json" "$AUTH_DONOR_DIR/user.json"
    if find_auth_donor; then
        lxc file push "$AUTH_DONOR_DIR/auth.json" "$container/root/.config/optimai-cli/auth.json" 2>/dev/null
        lxc file push "$AUTH_DONOR_DIR/user.json" "$container/root/.config/optimai-cli/user.json" 2>/dev/null
        lxc exec "$container" </dev/null -- bash -c \
            "chmod 600 /root/.config/optimai-cli/auth.json /root/.config/optimai-cli/user.json" 2>/dev/null
        check=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        echo "$check" | grep -qi "logged in" && return 0
    fi
    return 1
}

stop_node() {
    local container="$1"
    lxc exec "$container" </dev/null -- bash -c \
        "pkill -9 -f 'optimai-cli' 2>/dev/null; pkill -9 -f 'optimai_cli_core' 2>/dev/null; pkill -9 -f 'node_cli_core' 2>/dev/null" 2>/dev/null
    sleep 2
}

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

ALL_CONTAINERS=$(lxc list -c n,s --format csv 2>/dev/null | grep "^${CONTAINER_PREFIX}[0-9]")
[ -z "$ALL_CONTAINERS" ] && exit 0

TOTAL=0; RUNNING=0; RESTARTED=0; FAILED=0
find_auth_donor 2>/dev/null

while IFS=, read -r -u3 container status; do
    TOTAL=$((TOTAL + 1))

    if [ "$status" != "RUNNING" ]; then
        log "LXC_STOPPED: $container — запускаю"
        lxc stop "$container" --force 2>/dev/null; sleep 2
        lxc start "$container" 2>/dev/null; sleep 10
        NEW_STATUS=$(lxc list -c n,s --format csv 2>/dev/null | grep "^${container}," | cut -d, -f2)
        if [ "$NEW_STATUS" != "RUNNING" ]; then
            FAILED=$((FAILED + 1)); log "FAIL: $container — LXD не запустился"; continue
        fi
        log "LXC_STARTED: $container"
        # Fix DNS after container restart
        lxc exec "$container" </dev/null -- bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf" 2>/dev/null || true
        sleep 5
    fi

    AUTH_STATUS=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
    if echo "$AUTH_STATUS" | grep -qi "not authenticated"; then
        log "AUTH_LOST: $container — восстанавливаю токен..."
        if do_auth_fix "$container"; then
            log "AUTH_RESTORED: $container"
        else
            log "AUTH_FAIL: $container"; FAILED=$((FAILED + 1)); continue
        fi
    fi

    if is_node_running "$container"; then
        DOCKER_OK=$(lxc exec "$container" </dev/null -- bash -c "docker info >/dev/null 2>&1 && echo ok" 2>/dev/null)
        CRAWL_STATUS=$(lxc exec "$container" </dev/null -- docker inspect --format '{{.State.Health.Status}}' optimai_crawl4ai_0_7_3 2>/dev/null)
        if [ "$DOCKER_OK" = "ok" ] && [ "$CRAWL_STATUS" != "unhealthy" ]; then
            RUNNING=$((RUNNING + 1)); reset_fail_count "$container"; continue
        fi
        [ "$DOCKER_OK" != "ok" ] && { log "DOCKER_DOWN: $container"; lxc exec "$container" </dev/null -- systemctl restart docker 2>/dev/null; sleep 5; }
        [ "$CRAWL_STATUS" = "unhealthy" ] && { log "CRAWL4AI_UNHEALTHY: $container — пересоздаю"; lxc exec "$container" </dev/null -- bash -c "docker stop optimai_crawl4ai_0_7_3 2>/dev/null; docker rm optimai_crawl4ai_0_7_3 2>/dev/null" 2>/dev/null; }
    fi

    FAILS=$(get_fail_count "$container")

    if [ "$FAILS" -ge "$MAX_SOFT_FAILS" ]; then
        log "FORCE_RESTART: $container — $FAILS неудач, lxc restart --force"
        lxc restart "$container" --force 2>/dev/null; sleep 15
        AUTH_CHECK=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null)
        echo "$AUTH_CHECK" | grep -qi "not authenticated" && { log "AUTH_FIX_AFTER_FORCE: $container"; do_auth_fix "$container"; sleep 2; }
        start_node "$container"
        if is_node_running "$container"; then
            RESTARTED=$((RESTARTED + 1)); reset_fail_count "$container"; log "OK: $container — перезапущена после force restart"
        else
            FAILED=$((FAILED + 1)); set_fail_count "$container" 0; log "FAIL: $container — не запустилась после force restart"
        fi
        continue
    fi

    log "RESTART: $container — Node not running (попытка $((FAILS + 1)))"
    lxc exec "$container" </dev/null -- bash -c "systemctl is-active docker >/dev/null 2>&1 || { systemctl restart docker; sleep 5; }" 2>/dev/null
    start_node "$container"
    if is_node_running "$container"; then
        RESTARTED=$((RESTARTED + 1)); reset_fail_count "$container"; log "OK: $container — перезапущена"
    else
        FAILED=$((FAILED + 1)); set_fail_count "$container" $((FAILS + 1)); log "FAIL: $container — не запустилась (сбой #$((FAILS + 1)))"
    fi
done 3<<< "$ALL_CONTAINERS"

log "SUMMARY: Всего=$TOTAL, Работали=$RUNNING, Перезапущено=$RESTARTED, Ошибки=$FAILED"
WATCHDOG
    chmod +x "$WATCHDOG_FILE"
    success "Watchdog v6 установлен: $WATCHDOG_FILE"

    # OOM Protect
    info "Установка OOM-защиты..."
    cat > "$OOM_PROTECT_FILE" <<'OOMSCRIPT'
#!/bin/bash
sleep 30
for pid in $(pgrep -f "snap.lxd") $(pgrep -x containerd); do
    [ -f "/proc/$pid/oom_score_adj" ] && echo -500 > "/proc/$pid/oom_score_adj" 2>/dev/null
done
echo "[$(date)] OOM protection applied" >> /var/log/optimai_watchdog.log
OOMSCRIPT
    chmod +x "$OOM_PROTECT_FILE"
    success "OOM-защита установлена: $OOM_PROTECT_FILE"

    # Cron
    info "Настройка cron..."
    local cron_tmp
    cron_tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v "optimai_watchdog\|optimai_oom_protect" > "$cron_tmp" || true
    echo "*/5 * * * * $WATCHDOG_FILE" >> "$cron_tmp"
    echo "@reboot $OOM_PROTECT_FILE" >> "$cron_tmp"
    crontab "$cron_tmp"
    rm -f "$cron_tmp"
    success "Cron настроен: watchdog каждые 5 мин + OOM при загрузке"

    bash "$OOM_PROTECT_FILE" &
}

# ===================== ФИНАЛЬНАЯ ПРОВЕРКА =====================

final_check() {
    banner "ФИНАЛЬНАЯ ПРОВЕРКА"

    local containers
    containers=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sort -V)
    [ -z "$containers" ] && { error "Нет контейнеров"; return; }

    local total=0 running=0 down=0
    echo -e "  ${BOLD}Контейнер    Worker         Auth           Docker${NC}"
    echo "  ─────────────────────────────────────────────────────"

    for container in $containers; do
        total=$((total + 1))

        local worker_count auth_st docker_st
        worker_count=$(lxc exec "$container" </dev/null -- bash -c \
            "ps aux | grep -E 'optimai-cli node start|optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null)
        auth_st=$(lxc exec "$container" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null | head -1)
        docker_st=$(lxc exec "$container" </dev/null -- bash -c "docker info --format '{{.Driver}}' 2>/dev/null" 2>/dev/null || echo "none")

        local worker_icon auth_icon docker_icon
        if [ "$worker_count" -gt 0 ]; then
            worker_icon="${GREEN}running${NC}"
            running=$((running + 1))
        else
            worker_icon="${RED}stopped${NC}"
            down=$((down + 1))
        fi

        echo "$auth_st" | grep -qi "logged in" && auth_icon="${GREEN}OK${NC}" || auth_icon="${RED}NO${NC}"
        [ "$docker_st" = "overlay2" ] && docker_icon="${GREEN}overlay2${NC}" || docker_icon="${RED}$docker_st${NC}"

        printf "  %-12s %-22b %-22b %-20b\n" "$container" "$worker_icon" "$auth_icon" "$docker_icon"
    done

    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo -e "  ${BOLD}Итого: $total нод | ${GREEN}$running работают${NC} | ${RED}$down остановлены${NC}"
    echo ""
    echo -e "  Watchdog: $([ -f "$WATCHDOG_FILE" ] && echo -e "${GREEN}v6 установлен${NC}" || echo -e "${RED}нет${NC}")"
    echo -e "  Cron:     $(crontab -l 2>/dev/null | grep -q watchdog && echo -e "${GREEN}настроен${NC}" || echo -e "${RED}нет${NC}")"
    echo -e "  Uptime:   $(uptime -p)"
    echo -e "  Load:     $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
    echo -e "  RAM:      $(free -h | awk '/Mem:/{printf "%s used / %s total", $3, $2}')"
    echo ""
}

# ===================== ЛОГИ =====================

show_node_logs() {
    banner "ЛОГИ НОДЫ"

    local containers
    containers=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sort -V)
    [ -z "$containers" ] && { error "Нет контейнеров"; return; }

    echo -e "  ${BOLD}Доступные ноды:${NC}"
    local i=1
    local nodes=()
    for c in $containers; do
        local status
        status=$(lxc exec "$c" </dev/null -- bash -c \
            "ps aux | grep -E 'optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null || echo 0)
        if [ "${status:-0}" -gt 0 ]; then
            printf "  %2d) %-12s %b\n" "$i" "$c" "${GREEN}running${NC}"
        else
            printf "  %2d) %-12s %b\n" "$i" "$c" "${RED}stopped${NC}"
        fi
        nodes+=("$c")
        i=$((i + 1))
    done
    echo ""
    read -p "  Выбери ноду [1-${#nodes[@]}] или 0 для выхода: " node_choice

    [ "$node_choice" = "0" ] && return
    if ! [[ "$node_choice" =~ ^[0-9]+$ ]] || [ "$node_choice" -lt 1 ] || [ "$node_choice" -gt "${#nodes[@]}" ]; then
        warn "Неверный выбор"
        return
    fi

    local selected="${nodes[$((node_choice - 1))]}"
    echo ""
    echo -e "  ${BOLD}Логи $selected:${NC}"
    echo "  ─────────────────────────────────────────"
    echo ""
    echo -e "  ${CYAN}1)${NC} Лог ноды (задания, ошибки)"
    echo -e "  ${CYAN}2)${NC} Лог ноды — live (Ctrl+C для выхода)"
    echo -e "  ${CYAN}3)${NC} Docker контейнеры"
    echo -e "  ${CYAN}4)${NC} Auth статус"
    echo -e "  ${CYAN}5)${NC} Системные процессы"
    echo ""
    read -p "  Что показать? [1-5]: " log_choice

    case $log_choice in
        1)
            echo ""
            echo -e "  ${CYAN}=== Последние 50 строк лога ===${NC}"
            lxc exec "$selected" </dev/null -- tail -50 /var/log/optimai/node.log 2>/dev/null || echo "  Лог пуст или не найден"
            ;;
        2)
            echo ""
            echo -e "  ${CYAN}=== Live лог (Ctrl+C для выхода) ===${NC}"
            lxc exec "$selected" </dev/null -- tail -f /var/log/optimai/node.log 2>/dev/null || echo "  Лог не найден"
            ;;
        3)
            echo ""
            echo -e "  ${CYAN}=== Docker контейнеры ===${NC}"
            lxc exec "$selected" </dev/null -- docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
            ;;
        4)
            echo ""
            echo -e "  ${CYAN}=== Auth статус ===${NC}"
            lxc exec "$selected" </dev/null -- bash -c "optimai-cli auth status 2>&1" 2>/dev/null
            ;;
        5)
            echo ""
            echo -e "  ${CYAN}=== Процессы OptimAI ===${NC}"
            lxc exec "$selected" </dev/null -- bash -c "ps aux | grep -E 'optimai|node_cli|crawl4ai|docker' | grep -v grep" 2>/dev/null
            ;;
        *)
            warn "Неверный выбор"
            ;;
    esac
}

show_watchdog_log() {
    banner "ЛОГ WATCHDOG"
    echo -e "  ${CYAN}=== Последние 50 строк ===${NC}"
    echo ""
    tail -50 /var/log/optimai_watchdog.log 2>/dev/null || echo "  Лог не найден"
    echo ""
    echo "  ─────────────────────────────────────────"
    echo -e "  Файл: /var/log/optimai_watchdog.log"
    echo -e "  Cron: $(crontab -l 2>/dev/null | grep watchdog || echo 'не настроен')"
}

# ===================== УДАЛЕНИЕ НОД =====================

delete_nodes() {
    banner "УДАЛЕНИЕ НОД"

    local containers
    containers=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sort -V)
    [ -z "$containers" ] && { error "Нет контейнеров"; return; }

    echo -e "  ${BOLD}Доступные ноды:${NC}"
    local i=1
    local nodes=()
    for c in $containers; do
        local status
        status=$(lxc exec "$c" </dev/null -- bash -c \
            "ps aux | grep -E 'optimai_cli_core|node_cli_core' | grep -v grep | wc -l" 2>/dev/null || echo 0)
        if [ "${status:-0}" -gt 0 ]; then
            printf "  %2d) %-12s %b\n" "$i" "$c" "${GREEN}running${NC}"
        else
            printf "  %2d) %-12s %b\n" "$i" "$c" "${RED}stopped${NC}"
        fi
        nodes+=("$c")
        i=$((i + 1))
    done

    echo ""
    echo -e "  ${YELLOW}Можно указать несколько через пробел или диапазон: 1 3 5  или  2-5  или  all${NC}"
    read -p "  Какие ноды удалить? " del_input

    [ -z "$del_input" ] && return

    # Парсим выбор
    local to_delete=()
    if [ "$del_input" = "all" ]; then
        to_delete=("${nodes[@]}")
    else
        for part in $del_input; do
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                for n in $(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"); do
                    [ "$n" -ge 1 ] && [ "$n" -le "${#nodes[@]}" ] && to_delete+=("${nodes[$((n-1))]}")
                done
            elif [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "${#nodes[@]}" ]; then
                to_delete+=("${nodes[$((part-1))]}")
            fi
        done
    fi

    [ ${#to_delete[@]} -eq 0 ] && { warn "Ничего не выбрано"; return; }

    echo ""
    echo -e "  ${RED}Будут удалены:${NC}"
    for c in "${to_delete[@]}"; do
        echo -e "    - $c"
    done
    echo ""
    read -p "  Точно удалить? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { info "Отменено"; return; }

    echo ""
    local deleted=0 failed=0
    for container in "${to_delete[@]}"; do
        printf "  %-12s " "$container"

        # Останавливаем worker
        lxc exec "$container" </dev/null -- bash -c \
            "pkill -9 -f optimai_cli_core 2>/dev/null; pkill -9 -f node_cli_core 2>/dev/null; pkill -9 -f optimai-cli 2>/dev/null" &>/dev/null || true

        # Удаляем контейнер
        lxc stop "$container" --force &>/dev/null || true
        if lxc delete "$container" --force &>/dev/null; then
            printf "%b\n" "${GREEN}удалён${NC}"
            deleted=$((deleted + 1))
        else
            printf "%b\n" "${RED}ошибка${NC}"
            failed=$((failed + 1))
        fi
    done

    echo ""
    info "Удалено: $deleted | Ошибок: $failed"

    # Чистим fail-файлы watchdog
    for container in "${to_delete[@]}"; do
        rm -f "$FAIL_DIR/$container" 2>/dev/null || true
        rm -f "/var/lib/optimai_watchdog/$container" 2>/dev/null || true
    done
}

# ===================== ГЛАВНОЕ МЕНЮ =====================

main_menu() {
    while true; do
        clear
        echo -e "${PURPLE}╔═══════════════════════════════════════════════════╗${NC}"
        echo -e "${PURPLE}║${NC}  ${BOLD}OptimAI Full Installer v2.0${NC}                      ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  ${CYAN}Watchdog v6 | OAuth token copy | Auto-heal${NC}      ${PURPLE}║${NC}"
        echo -e "${PURPLE}╠═══════════════════════════════════════════════════╣${NC}"
        echo -e "${PURPLE}║${NC}                                                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  ${CYAN}ПОЛНАЯ УСТАНОВКА${NC}                                 ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   1) Установить всё автоматически                 ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}                                                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  ${CYAN}ПОЭТАПНО${NC}                                         ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   2) Обновление системы                           ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   3) Настройка SWAP                               ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   4) Установка LXD + контейнеры                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   5) Установка Docker в контейнерах               ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   6) OptimAI CLI + авторизация (OAuth)            ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   7) Запуск всех нод                              ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   8) Установка Watchdog v6 + Cron                 ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}                                                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  ${CYAN}СЕРВИС${NC}                                            ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   9) Проверка статуса всех нод                    ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  10) Логи ноды                                    ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  11) Лог watchdog                                 ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}  12) Удалить ноды                                 ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}   0) Выход                                        ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC}                                                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}╚═══════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "  Выбери пункт [0-12]: " choice

        case $choice in
            1)
                install_system_deps
                setup_swap
                install_lxd
                setup_docker
                install_optimai_cli
                start_all_nodes
                install_watchdog
                final_check
                read -p "Нажми Enter..."
                ;;
            2) install_system_deps; read -p "Нажми Enter..." ;;
            3) setup_swap; read -p "Нажми Enter..." ;;
            4) install_lxd; read -p "Нажми Enter..." ;;
            5) setup_docker; read -p "Нажми Enter..." ;;
            6) install_optimai_cli; read -p "Нажми Enter..." ;;
            7) start_all_nodes; read -p "Нажми Enter..." ;;
            8) install_watchdog; read -p "Нажми Enter..." ;;
            9) final_check; read -p "Нажми Enter..." ;;
            10) show_node_logs; read -p "Нажми Enter..." ;;
            11) show_watchdog_log; read -p "Нажми Enter..." ;;
            12) delete_nodes; read -p "Нажми Enter..." ;;
            0) echo "Выход..."; exit 0 ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

# ===================== ENTRY POINT =====================
check_root
main_menu
