#!/usr/bin/env bash
# Docker Compose node deployment for a fresh Ubuntu 24.04 x86_64 VPS.
# Official runtime image is locked by digest; known release binaries are mounted read-only.
# Pinned release: 3x-ui 3.7.0 with bundled Xray 26.7.28.
# Revision 2026-10-03: REALITY form request, inbound display name and port guidance.

set +x
set +a
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ulimit -c 0

readonly SCRIPT_VERSION="1.0.0-docker-rc1"
readonly XUI_VERSION="3.7.0"
readonly XRAY_VERSION="26.7.28"
readonly XUI_ARCHIVE_URL="https://github.com/MHSanaei/3x-ui/releases/download/v3.7.0/x-ui-linux-amd64.tar.gz"
readonly XUI_ARCHIVE_SHA256="0f8dd7baef3458f6591574e24814f322cf7f5e1e27f0a594683745e50be84ec5"
readonly XUI_BINARY_SHA256="4738190332c5480ec96fd72e10a21157ee4bcf91c240a9b4b061d14f15092298"
readonly XRAY_BINARY_SHA256="64d46afb80adea1bf97a0d467e83f4a9ac1ebd0995891e84bca3f1a1d1affb1d"
readonly REALITY_TARGET="www.google.com:443"
readonly REALITY_SNI="www.google.com"
readonly INBOUND_TAG="in-443-tcp"
readonly TEST_TRAFFIC_BYTES="5368709120"
readonly TEST_LIFETIME_MS="14400000"
readonly TEST_IP_LIMIT="3"

# GitHub edition: personal settings are requested interactively and stored only
# in the root-owned local state. No deployment credentials belong in this file.

readonly RUNTIME_REPOSITORY="ghcr.io/mhsanaei/3x-ui"
readonly RUNTIME_TAG="3.7.0"
readonly CONTAINER_NAME="xui-node-docker"
readonly COMPOSE_PROJECT="xui-node-docker"
if [[ "${XUI_NODE_DOCKER_LIBRARY_MODE:-0}" == 1 ]]; then
    readonly STACK_DIR="${XUI_DOCKER_TEST_STACK:?test stack required}"
    readonly STATE_DIR="${XUI_DEPLOY_STATE_DIR:?test state required}"
    readonly XUI_DIR="${XUI_DEPLOY_XUI_DIR:?test release required}"
else
    readonly STACK_DIR="/opt/xui-node-docker"
    readonly STATE_DIR="/var/lib/xui-node-docker"
    readonly XUI_DIR="$STACK_DIR/release"
fi
readonly STATE_FILE="$STATE_DIR/config.json"
readonly OWNER_FILE="$STATE_DIR/managed-by-xui-node-docker"
readonly LOCK_FILE="/run/lock/xui-node-docker.lock"
readonly LOG_DIR="/var/log/xui-node-docker"
readonly DB_DIR="$STACK_DIR/db"
readonly DB_FILE="$DB_DIR/x-ui.db"
readonly RESULT_FILE="$DB_DIR/deploy-result.env"
readonly IMAGE_LOCK_FILE="$STACK_DIR/image-lock.json"
readonly COMPOSE_FILE="$STACK_DIR/compose.yaml"
readonly XUI_BIN="$XUI_DIR/x-ui"
readonly XRAY_BIN="$XUI_DIR/bin/xray-linux-amd64"
readonly XRAY_CONFIG="$STACK_DIR/xray/config.json"
readonly BOOTSTRAP_TOKEN_FILE="$STATE_DIR/bootstrap-admin-token"
readonly BOOTSTRAP_NAME_FILE="$STATE_DIR/bootstrap-admin-name"
readonly NODE_TOKEN_FILE="$STATE_DIR/node-sync-token"
IMAGE_LOCK_INPUT=""

declare -a TEMP_PATHS=()
MAIN_API_TOKEN=""
export -n MAIN_API_TOKEN LOCAL_API_TOKEN NODE_API_TOKEN 2>/dev/null || true

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_RESET=""
fi

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

register_temp() {
    TEMP_PATHS+=("$1")
}

secure_remove_file() {
    local target="${1:-}"
    [[ -n "$target" && -f "$target" ]] || return 0
    case "$target" in
        /run/xui-node-docker.*|/var/tmp/xui-node-docker.*|"${STATE_DIR}"/*)
            if command -v shred >/dev/null 2>&1; then
                shred -u -- "$target" 2>/dev/null || rm -f -- "$target"
            else
                rm -f -- "$target"
            fi
            ;;
        *)
            warn "Отказ удаления неожиданного пути: $target"
            return 1
            ;;
    esac
}

cleanup() {
    local path
    MAIN_API_TOKEN=""
    unset MAIN_API_TOKEN LOCAL_API_TOKEN NODE_API_TOKEN 2>/dev/null || true
    for path in "${TEMP_PATHS[@]:-}"; do
        if [[ -f "$path" ]]; then
            case "$path" in
                /run/xui-node-docker.*|/var/tmp/xui-node-docker.*) rm -f -- "$path" ;;
            esac
        elif [[ -d "$path" ]]; then
            case "$path" in
                /var/tmp/xui-node-docker.*) rm -rf -- "$path" ;;
            esac
        fi
    done
}

trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
    cat <<'EOF'
Использование:
  sudo ./xui-node-docker.sh                         установить / продолжить
  sudo ./xui-node-docker.sh --use-image-lock FILE   установить с общим digest
  sudo ./xui-node-docker.sh --status                состояние без секретов
  sudo ./xui-node-docker.sh --diagnose              диагностический отчёт
  sudo ./xui-node-docker.sh --validate              проверить контейнер и Xray
  sudo ./xui-node-docker.sh --image-lock            вывести общий JSON без секретов
  ./xui-node-docker.sh --help
Только чистая Ubuntu 24.04 x86_64. Это отдельный Docker RC, без миграции
существующих systemd/Docker-установок и без автоматического обновления 3x-ui/Xray.
EOF
}

mark_done() {
    install -m 0600 /dev/null "${STATE_DIR}/$1.done"
}

is_done() {
    [[ -f "${STATE_DIR}/$1.done" ]]
}

cfg_get() {
    jq -er "$1" "$STATE_FILE"
}

cfg_set_string() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp "${STATE_DIR}/config.json.tmp.XXXXXX")
    jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$STATE_FILE" > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

cfg_set_number() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp "${STATE_DIR}/config.json.tmp.XXXXXX")
    jq --arg key "$key" --argjson value "$value" '.[$key] = $value' "$STATE_FILE" > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

collect_diagnostics() {
    local reason="${1:-manual request}" stamp raw report
    install -d -m 0700 "$LOG_DIR"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    raw=$(mktemp "/run/xui-node-docker.diag.XXXXXX")
    register_temp "$raw"
    report="${LOG_DIR}/diagnostics-${stamp}.txt"

    {
        printf '3x-ui node deployment diagnostics\n'
        printf 'generated_utc=%s\n' "$(date -u +%FT%TZ)"
        printf 'reason=%s\n' "$reason"
        printf 'script_version=%s\n\n' "$SCRIPT_VERSION"
        printf '[OS]\n'
        sed -n 's/^\(PRETTY_NAME\|VERSION_ID\|ID\)=/\1=/p' /etc/os-release 2>/dev/null || true
        uname -srvmo 2>/dev/null || true
        printf '\n[resources]\n'
        free -h 2>/dev/null || true
        df -h / 2>/dev/null || true
        swapon --show 2>/dev/null || true
        printf '\n[versions and hashes]\n'
        "$XUI_BIN" -v 2>/dev/null || true
        "$XRAY_BIN" version 2>/dev/null | sed -n '1p' || true
        sha256sum "$XUI_BIN" "$XRAY_BIN" 2>/dev/null || true
        printf '\n[services]\n'
        docker_local inspect -f '{{.Name}} state={{.State.Status}} image={{.Image}}' "$CONTAINER_NAME" 2>&1 || true
        systemctl --no-pager --full status fail2ban.service 2>&1 || true
        systemctl --no-pager --full status certbot.timer 2>&1 || true
        printf '\n[listeners]\n'
        ss -H -lntup 2>&1 || true
        printf '\n[ufw]\n'
        ufw status verbose 2>&1 || true
        printf '\n[certificate]\n'
        if [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
            local diag_domain
            diag_domain=$(cfg_get '.domain' 2>/dev/null || true)
            if [[ -n "$diag_domain" && -f "/etc/letsencrypt/live/${diag_domain}/fullchain.pem" ]]; then
                openssl x509 -in "/etc/letsencrypt/live/${diag_domain}/fullchain.pem" -noout -subject -issuer -dates 2>&1 || true
                dig +short A "$diag_domain" 2>/dev/null || true
                dig +short AAAA "$diag_domain" 2>/dev/null || true
            fi
        fi
        printf '\n[inbound, no secrets]\n'
        if [[ -f "$DB_FILE" ]]; then
            sqlite3 -readonly -header -column "$DB_FILE" \
                "SELECT id,tag,protocol,port,enable,COALESCE(json_extract(stream_settings,'$.security'),'') AS security,CASE WHEN json_type(stream_settings,'$.realitySettings.minClientVer') IS NULL THEN 'absent' ELSE 'present' END AS minClientVer,CASE WHEN json_type(stream_settings,'$.realitySettings.maxClientVer') IS NULL THEN 'absent' ELSE 'present' END AS maxClientVer FROM inbounds;" 2>&1 || true
            sqlite3 -readonly -header -column "$DB_FILE" \
                "SELECT email,limit_ip,total_gb,expiry_time,enable FROM clients WHERE email LIKE 'deploy-test-%';" 2>&1 || true
        fi
        printf '\n[xray config validation]\n'
        if [[ -x "$XRAY_BIN" && -f "$XRAY_CONFIG" ]]; then
            xray_test_config "$XRAY_CONFIG" 2>&1 || true
        fi
        printf '\n[x-ui journal]\n'
        docker_local logs --tail 120 "$CONTAINER_NAME" 2>&1 || true
    } > "$raw"

    python3 - "$raw" "$report" "$STATE_FILE" "$BOOTSTRAP_TOKEN_FILE" "$NODE_TOKEN_FILE" <<'PY'
import json
import pathlib
import re
import sys

src, dst, state_path, bootstrap_path, node_path = map(pathlib.Path, sys.argv[1:])
text = src.read_text(errors="replace")
secrets = []
try:
    state = json.loads(state_path.read_text())
    for key in ("panelBasePath", "adminUsername", "adminPassword"):
        value = state.get(key)
        if isinstance(value, str) and value:
            secrets.append(value)
except Exception:
    pass
for path in (bootstrap_path, node_path):
    try:
        value = path.read_text().strip()
        if value:
            secrets.append(value)
    except Exception:
        pass
for secret in sorted(set(secrets), key=len, reverse=True):
    text = text.replace(secret, "[REDACTED]")
text = re.sub(r"(?i)(authorization\s*:\s*bearer\s+)[^\s]+", r"\1[REDACTED]", text)
text = re.sub(r"vless://\S+", "vless://[REDACTED]", text)
text = re.sub(r'(?i)("?(?:privateKey|publicKey|password|apiToken)"?\s*[:=]\s*)"?[^"\s,}]+', r'\1[REDACTED]', text)
text = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "[UUID-REDACTED]", text)
dst.write_text(text)
PY
    chmod 0600 "$report"
    secure_remove_file "$raw"
    printf '%s\n' "$report"
}

die() {
    local message="$*"
    err "$message"
    if [[ -x "$XUI_BIN" ]]; then
        local report
        report=$(collect_diagnostics "$message" 2>/dev/null || true)
        [[ -n "$report" ]] && warn "Диагностика без секретов: $report"
    fi
    exit 1
}

on_error() {
    local rc=$? line="$1"
    trap - ERR
    err "Неожиданная ошибка на строке ${line}, код ${rc}."
    if [[ -x "$XUI_BIN" ]]; then
        local report
        report=$(collect_diagnostics "unexpected error at line ${line}, rc=${rc}" 2>/dev/null || true)
        [[ -n "$report" ]] && warn "Диагностика без секретов: $report"
    fi
    exit "$rc"
}
trap 'on_error "$LINENO"' ERR

require_root_and_platform() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите скрипт через sudo."
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
        die "Поддерживается только Ubuntu 24.04 LTS. Обнаружено: ${PRETTY_NAME:-unknown}."
    [[ "$(uname -m)" == "x86_64" ]] || die "Поддерживается только x86_64."
    [[ -d /run/systemd/system ]] || die "Требуется загрузка через systemd."
}

check_existing_install() {
    local path
    for path in "$STATE_DIR" "$STATE_FILE" "$OWNER_FILE" "$STACK_DIR" "$DB_DIR" "$IMAGE_LOCK_FILE"; do
        [[ ! -L "$path" ]] || die "Путь не должен быть символической ссылкой: $path"
    done
    if [[ -d "$STATE_DIR" ]]; then
        [[ "$(stat -c '%u:%a' "$STATE_DIR")" == '0:700' ]] || die "Каталог состояния должен быть root:700."
    fi
    if [[ ! -e "$OWNER_FILE" ]]; then
        for path in "$STACK_DIR" /etc/x-ui/x-ui.db /usr/local/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service /var/lib/xui-node-deploy; do
            [[ ! -e "$path" ]] || die "Найдена существующая установка/каталог $path. Нужен чистый VPS; миграция не выполняется."
        done
        if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
            die "Найден ранее установленный Docker/Podman. Этот установщик рассчитан на чистый VPS."
        fi
        for path in /etc/docker/daemon.json /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc /etc/fail2ban/jail.d/3x-ipl.conf; do
            [[ ! -e "$path" ]] || die "Найден неизвестный файл $path; автоматическая перезапись запрещена."
        done
    fi
    if command -v docker >/dev/null 2>&1 && docker_local info >/dev/null 2>&1; then
        if docker_local inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
            [[ "$(docker_local inspect -f '{{index .Config.Labels "io.xui-node-docker.managed"}}' "$CONTAINER_NAME")" == "$SCRIPT_VERSION" ]] || die "Имя контейнера занято посторонней установкой."
        fi
    fi
}

check_initial_conflicts() {
    local port
    while IFS= read -r port; do
        [[ "$port" != 80 && "$port" != 443 ]] || die "SSH использует TCP/$port. Он конфликтует с HTTP-01/REALITY; SSH автоматически не меняется."
    done < <(detect_ssh_ports)
    if [[ ! -e "$OWNER_FILE" ]]; then
        [[ "$(df -PB1 / | awk 'NR==2 {print $4}')" -gt 4294967296 ]] || die "Для Docker, релиза и swap нужно более 4 GiB свободного диска."
        for port in 80 443; do
            if port_is_listening "$port"; then
                die "TCP/$port уже занят. Нужен свежий VPS со свободными 80/443; службы не останавливались."
            fi
        done
        [[ ! -s /etc/default/x-ui ]] || die "Найден неизвестный /etc/default/x-ui; автоматическая установка запрещена."
        if command -v ufw >/dev/null 2>&1; then
            if ufw status | grep -q '^Status: active' || ufw show added | grep -q '^ufw '; then
                die "На сервере уже настроен UFW. Скрипт не перезаписывает неизвестные правила; нужен чистый тестовый VPS."
            fi
        fi
    fi
}

acquire_lock() {
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другой экземпляр скрипта уже работает."
}

valid_ipv4() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
    value = ipaddress.ip_address(sys.argv[1])
    raise SystemExit(0 if value.version == 4 and value.is_global else 1)
except ValueError:
    raise SystemExit(1)
PY
}

valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

port_is_listening() {
    local wanted="$1"
    ss -H -ltn 2>/dev/null | awk -v wanted="$wanted" '
        { addr=$4; sub(/^.*:/, "", addr); gsub(/[^0-9]/, "", addr); if (addr == wanted) found=1 }
        END { exit(found ? 0 : 1) }
    '
}

detect_public_ipv4() {
    local endpoint candidate
    for endpoint in \
        https://api4.ipify.org \
        https://ipv4.icanhazip.com \
        https://4.ident.me; do
        candidate=$(curl --disable --silent --show-error --fail --ipv4 --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -n "$candidate" ]] && valid_ipv4 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

detect_ssh_ports() {
    local candidate
    {
        /usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            awk '{print $4}' <<< "$SSH_CONNECTION"
        fi
        # Loopback sshd listeners are X11 forwarding, not public SSH entry ports.
        ss -H -lntp 2>/dev/null | awk '/sshd/ {a=$4; if (a ~ /^127\./ || a ~ /^\[?::1\]?:/) next; p=a; sub(/^.*:/,"",p); gsub(/[^0-9]/,"",p); print p}' || true
        systemctl show ssh.socket --property=Listen --value 2>/dev/null | \
            tr ' ' '\n' | sed -n -E 's/^.*:([0-9]+)$/\1/p' || true
    } | while IFS= read -r candidate; do
        [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate >= 1 && candidate <= 65535 )) && printf '%s\n' "$candidate"
    done | sort -nu
}

choose_panel_port() {
    local candidate attempt
    for attempt in $(seq 1 200); do
        candidate=$(shuf -i 20000-60000 -n 1)
        if ! port_is_listening "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

country_flag() {
    python3 - "$1" <<'PY'
import sys
code = sys.argv[1].upper()
print("".join(chr(0x1F1E6 + ord(ch) - ord("A")) for ch in code))
PY
}

prepare_os() {
    if ! is_done os-prep; then
        info "Обновление Ubuntu и установка базовых пакетов..."
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
        apt-get update
        apt-get -y -o Dpkg::Options::="--force-confold" upgrade
        apt-get install -y \
            ca-certificates certbot cron curl dnsutils fail2ban iproute2 iptables jq nftables logrotate \
            openssl python3 python3-systemd qrencode sqlite3 tar ufw unattended-upgrades util-linux

        install -m 0644 /dev/stdin /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        install -m 0644 /dev/stdin /etc/apt/apt.conf.d/52xui-node-no-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
        systemctl enable --now unattended-upgrades.service
        ensure_swap
        mark_done os-prep
        ok "ОС подготовлена; автоматические обновления безопасности Ubuntu включены."
    fi

    if [[ -f /var/run/reboot-required ]]; then
        warn "Ubuntu требует перезагрузку после обновлений."
        warn "Выполните: sudo reboot"
        warn "После входа снова запустите этот же скрипт — он продолжит с сохранённого этапа."
        exit 10
    fi
}

ensure_swap() {
    if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
        info "Swap уже активен; существующая конфигурация не меняется."
        return 0
    fi

    if [[ -e /swapfile ]]; then
        [[ -f "${STATE_DIR}/swap-created.done" && ! -L /swapfile ]] || die "Неактивный /swapfile уже существует. Неизвестный файл не изменяется."
        [[ "$(blkid -p -s TYPE -o value /swapfile 2>/dev/null)" == swap ]] || die "Незавершённое создание swap: требуется ручная проверка /swapfile."
    else
        [[ "$(df -PB1 / | awk 'NR==2 {print $4}')" -gt 3221225472 ]] || die "Для swap и установки нужно более 3 GiB свободного диска."
        info "Создание swap-файла 1 GiB..."
        install -m 0600 /dev/null /swapfile
        fallocate -l 1G /swapfile
        chmod 0600 /swapfile
        mkswap /swapfile >/dev/null
        mark_done swap-created
    fi
    swapon /swapfile
    if ! awk '$1=="/swapfile" && $3=="swap" {found=1} END{exit !found}' /etc/fstab; then
        cp -p -- /etc/fstab "${STATE_DIR}/fstab.before-swap"
        printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    findmnt --verify >/dev/null || die "Проверка fstab не прошла; перезагрузка запрещена до исправления."
    systemctl daemon-reload
    swapon --show | grep -qF /swapfile || die "Ядро не активировало /swapfile."
    ok "Swap 1 GiB активирован и добавлен в /etc/fstab."
}

create_or_load_config() {
    if [[ -f "$STATE_FILE" ]]; then
        [[ "$(stat -c '%u:%a' "$STATE_FILE")" == '0:600' ]] || die "Файл состояния должен принадлежать root и иметь права 600."
        jq -e '.schema == 1 and (.nodeName|test("^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$")) and
          (.panelPort|type=="number" and .>=20000 and .<=60000 and floor==.) and
          (.panelBasePath|test("^[0-9a-f]{32}$")) and
          (.testEmail|test("^deploy-test-[a-z0-9._-]+@local[.]test$")) and
          (.adminUsername|test("^admin_[0-9a-f]{12}$")) and
          (.adminPassword|test("^[0-9a-f]{48}$"))' "$STATE_FILE" >/dev/null || die "Повреждён $STATE_FILE."
        valid_domain "$(cfg_get '.domain')" || die "Некорректный домен в состоянии."
        valid_ipv4 "$(cfg_get '.publicIPv4')" || die "Некорректный IPv4 в состоянии."
        info "Используется сохранённая конфигурация узла $(cfg_get '.displayName')."
        return 0
    fi

    local domain country node_name display_name public_ipv4 panel_port panel_path admin_user admin_password test_email
    while true; do
        read -rp "Домен нового узла (A-запись уже должна существовать): " domain
        domain=${domain,,}
        domain=${domain%.}
        valid_domain "$domain" && break
        warn "Введите полное доменное имя, например us1.example.com."
    done
    while true; do
        read -rp "Двухбуквенный код страны (например US): " country
        country=${country^^}
        [[ "$country" =~ ^[A-Z]{2}$ ]] && break
        warn "Нужны ровно две латинские буквы."
    done
    while true; do
        read -rp "Короткое имя узла (например US1): " node_name
        [[ "$node_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$ ]] && break
        warn "Разрешены 2–32 символа: латинские буквы, цифры, точка, дефис и подчёркивание."
    done

    public_ipv4=$(detect_public_ipv4) || die "Не удалось автоматически определить публичный IPv4 сервера."
    panel_port=$(choose_panel_port) || die "Не удалось выбрать свободный порт панели в диапазоне 20000–60000."
    panel_path=$(openssl rand -hex 16)
    admin_user="admin_$(openssl rand -hex 6)"
    admin_password=$(openssl rand -hex 24)
    [[ ${#admin_password} -eq 48 ]] || die "Не удалось сгенерировать пароль панели."
    test_email="deploy-test-${node_name,,}-$(openssl rand -hex 4)@local.test"
    display_name="$(country_flag "$country") ${node_name}"

    local tmp
    tmp=$(mktemp "${STATE_DIR}/config.json.tmp.XXXXXX")
    jq -n \
        --arg domain "$domain" \
        --arg publicIPv4 "$public_ipv4" \
        --arg countryCode "$country" \
        --arg nodeName "$node_name" \
        --arg displayName "$display_name" \
        --arg panelBasePath "$panel_path" \
        --arg adminUsername "$admin_user" \
        --rawfile adminPassword <(printf '%s' "$admin_password") \
        --arg testEmail "$test_email" \
        --argjson panelPort "$panel_port" \
        '{schema:1,domain:$domain,publicIPv4:$publicIPv4,countryCode:$countryCode,nodeName:$nodeName,displayName:$displayName,panelPort:$panelPort,panelBasePath:$panelBasePath,adminUsername:$adminUsername,adminPassword:$adminPassword,testEmail:$testEmail,inboundId:0,registeredNodeId:0}' > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
    ok "Параметры узла сохранены с правами root-only."
}

verify_dns() {
    local domain expected current
    local -a a_records aaaa_records local_v6
    domain=$(cfg_get '.domain')
    expected=$(cfg_get '.publicIPv4')
    current=$(detect_public_ipv4) || die "Не удалось определить текущий публичный IPv4."
    [[ "$current" == "$expected" ]] || die "Публичный IPv4 изменился: ожидался $expected, сейчас $current. Проверьте сервер и DNS."

    mapfile -t a_records < <(dig +short A "$domain" | awk '/^[0-9]+(\.[0-9]+){3}$/ {print}' | sort -u)
    [[ ${#a_records[@]} -eq 1 && "${a_records[0]}" == "$expected" ]] || \
        die "A-запись $domain должна содержать только публичный IPv4 этого сервера: $expected. Сейчас: ${a_records[*]:-(нет)}."

    mapfile -t aaaa_records < <(dig +short AAAA "$domain" | awk '/:/ {print}' | sort -u)
    if (( ${#aaaa_records[@]} > 0 )); then
        mapfile -t local_v6 < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        (( ${#local_v6[@]} > 0 )) || die "У $domain есть AAAA-запись, но на сервере нет глобального IPv6. Удалите неправильную AAAA-запись."
        python3 - "${aaaa_records[*]}" "${local_v6[*]}" <<'PY' || die "AAAA-запись домена не принадлежит этому серверу. Исправьте или удалите её."
import ipaddress, sys
dns = {ipaddress.ip_address(v) for v in sys.argv[1].split()}
local = {ipaddress.ip_address(v) for v in sys.argv[2].split()}
raise SystemExit(0 if dns and dns <= local else 1)
PY
    fi
    ok "DNS проверен: $domain указывает на $expected."
}

provider_firewall_checkpoint() {
    is_done provider-firewall && return 0
    local panel_port ssh_csv
    local -a ssh_ports
    panel_port=$(cfg_get '.panelPort')
    mapfile -t ssh_ports < <(detect_ssh_ports)
    (( ${#ssh_ports[@]} > 0 )) || die "Не удалось определить активный SSH-порт."
    printf '\nНа внешнем firewall/VPS-панели должны быть разрешены входящие TCP-порты:\n'
    ssh_csv=$(printf '%s\n' "${ssh_ports[@]}" | paste -sd, -)
    printf '  SSH: %s\n  HTTP-01: 80\n  VLESS REALITY: 443\n  3x-ui HTTPS: %s\n\n' "$ssh_csv" "$panel_port"
    printf 'Скрипт не может изменить firewall провайдера.\n'
    printf 'На этом этапе 80/443 и панель могут ещё не слушаться: правила провайдера проверяются в его кабинете.\n'
    printf 'Для проверки UFW и слушающих портов используйте вторую SSH-сессию: sudo ufw status verbose; sudo ss -lntp\n'
    printf 'После запуска REALITY проверьте TCP/443 и порт панели из Windows (шаг 6 README).\n'
    local answer
    read -rp "После открытия этих портов введите ОТКРЫТО: " answer
    [[ "${answer^^}" == "ОТКРЫТО" ]] || die "Подтверждение не получено; системный UFW ещё не изменён."
    mark_done provider-firewall
}

configure_ufw() {
    local panel_port port answer
    local -a ssh_ports
    panel_port=$(cfg_get '.panelPort')
    mapfile -t ssh_ports < <(detect_ssh_ports)
    (( ${#ssh_ports[@]} > 0 )) || die "Не удалось определить активный SSH-порт; UFW не включён."
    grep -Eq '^IPV6=yes$' /etc/default/ufw || die "Для защиты IPv6 требуется IPV6=yes в /etc/default/ufw; UFW не изменён."

    for port in "${ssh_ports[@]}"; do
        ufw allow "${port}/tcp" comment 'SSH detected by xui-node-docker' >/dev/null
    done
    ufw allow 80/tcp comment 'Lets Encrypt HTTP-01' >/dev/null
    ufw allow 443/tcp comment 'VLESS REALITY' >/dev/null
    ufw allow "${panel_port}/tcp" comment '3x-ui HTTPS panel' >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    ufw logging low >/dev/null
    ufw --force enable >/dev/null

    if ! is_done ufw; then
        ok "UFW включён; текущая SSH-сессия должна сохраниться."
        printf '\nОткройте ВТОРОЕ SSH-подключение к серверу и убедитесь, что вход работает.\n'
        read -rp "После успешного второго входа введите SSH-OK: " answer
        [[ "${answer^^}" == "SSH-OK" ]] || die "Новый SSH-вход не подтверждён. Не закрывайте текущую сессию; исправьте внешний firewall/UFW."
        mark_done ufw
    fi
    ok "UFW: deny incoming/routed; добавлены разрешения SSH, TCP/80, TCP/443 и порта панели."
}

audit_ssh_security() {
    local effective password_auth keyboard_auth root_login pubkey_auth
    if ! effective=$(/usr/sbin/sshd -T 2>/dev/null); then
        warn "Не удалось прочитать эффективные настройки SSH; сам SSH-конфиг не изменялся."
        return 0
    fi
    password_auth=$(awk '$1 == "passwordauthentication" {print $2}' <<< "$effective" | tail -n 1)
    keyboard_auth=$(awk '$1 == "kbdinteractiveauthentication" {print $2}' <<< "$effective" | tail -n 1)
    root_login=$(awk '$1 == "permitrootlogin" {print $2}' <<< "$effective" | tail -n 1)
    pubkey_auth=$(awk '$1 == "pubkeyauthentication" {print $2}' <<< "$effective" | tail -n 1)

    info "SSH-аудит (без изменений): password=${password_auth:-unknown}, keyboard-interactive=${keyboard_auth:-unknown}, root=${root_login:-unknown}, public-key=${pubkey_auth:-unknown}."
    [[ "$password_auth" != "yes" ]] || warn "SSH PasswordAuthentication включён. После проверки входа по ключу рекомендуется отключить его вручную."
    [[ "$keyboard_auth" != "yes" ]] || warn "SSH keyboard-interactive включён; проверьте, нужен ли он."
    [[ "$root_login" != "yes" ]] || warn "Прямой SSH-вход root разрешён. Рекомендуется отдельный sudo-пользователь и ключ."
    [[ "$pubkey_auth" != "no" ]] || warn "SSH PubkeyAuthentication отключён; не отключайте пароль до настройки ключа."
}

valid_admin_email() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

ensure_admin_email() {
    local email
    email=$(jq -r '.adminEmail // empty' "$STATE_FILE")
    if [[ -n "$email" ]]; then
        valid_admin_email "$email" || die "Некорректный email в состоянии."
        return
    fi
    while true; do
        read -rp "Email для сертификата Let's Encrypt: " email || die "Ввод email прерван."
        valid_admin_email "$email" && break
        warn "Введите email, например admin@example.com."
    done
    cfg_set_string adminEmail "$email"
}

ensure_certificate() {
    local domain fullchain privkey hook admin_email
    domain=$(cfg_get '.domain')
    fullchain="/etc/letsencrypt/live/$domain/fullchain.pem"
    privkey="/etc/letsencrypt/live/$domain/privkey.pem"
    if [[ ! -s "$fullchain" || ! -s "$privkey" ]]; then
        port_is_listening 80 && die "TCP/80 занят; HTTP-01 не сможет выполниться."
        ensure_admin_email
        admin_email=$(cfg_get '.adminEmail')
        certbot certonly --standalone --preferred-challenges http --non-interactive \
            --agree-tos --no-eff-email --email "$admin_email" --domain "$domain"
    fi
    openssl x509 -in "$fullchain" -noout -checkend 604800 >/dev/null || die "Сертификат действует меньше 7 дней."
    openssl x509 -in "$fullchain" -noout -checkhost "$domain" >/dev/null || die "Неверный домен сертификата."
    [[ "$(openssl x509 -in "$fullchain" -pubkey -noout | sha256sum)" == "$(openssl pkey -in "$privkey" -pubout 2>/dev/null | sha256sum)" ]] || die "Ключ не соответствует сертификату."
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    hook=/etc/letsencrypt/renewal-hooks/deploy/35-xui-node-docker
    cat > "$hook" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/$domain" ]] || exit 0
command -v docker >/dev/null || exit 0
[[ "\$(docker --host unix:///var/run/docker.sock inspect -f '{{.State.Running}}' $CONTAINER_NAME 2>/dev/null || true)" == true ]] || exit 0
[[ "\$(docker --host unix:///var/run/docker.sock inspect -f '{{index .Config.Labels "io.xui-node-docker.managed"}}' $CONTAINER_NAME)" == "$SCRIPT_VERSION" ]] || exit 1
docker --host unix:///var/run/docker.sock exec $CONTAINER_NAME /bin/sh /opt/deploy/check-pins.sh
docker --host unix:///var/run/docker.sock exec $CONTAINER_NAME /app/bin/xray-linux-amd64 run -test -config /app/bin/config.json >/dev/null
docker --host unix:///var/run/docker.sock restart --time 30 $CONTAINER_NAME >/dev/null
EOF
    chmod 0755 "$hook"
    systemctl enable --now certbot.timer
    if ! is_done certbot-dryrun; then
        certbot renew --cert-name "$domain" --dry-run --no-random-sleep-on-renew
        mark_done certbot-dryrun
    fi
    mark_done certificate
    ok "Сертификат и автоматическое продление настроены; hook перезапускает контейнер."
}

verify_pinned_binaries() {
    [[ -x "$XUI_BIN" && -x "$XRAY_BIN" ]] || return 1
    [[ "$(sha256sum "$XUI_BIN" | awk '{print $1}')" == "$XUI_BINARY_SHA256" ]] || return 1
    [[ "$(sha256sum "$XRAY_BIN" | awk '{print $1}')" == "$XRAY_BINARY_SHA256" ]] || return 1
    [[ "$("$XUI_BIN" -v 2>/dev/null | tail -n 1)" == "$XUI_VERSION" ]] || return 1
    "$XRAY_BIN" version 2>/dev/null | sed -n '1p' | grep -Fq "Xray ${XRAY_VERSION} " || return 1
}

write_result_file() {
    local domain port path username password tmp
    domain=$(cfg_get '.domain')
    port=$(cfg_get '.panelPort')
    path=$(cfg_get '.panelBasePath')
    username=$(cfg_get '.adminUsername')
    password=$(cfg_get '.adminPassword')
    install -d -m 0700 "$DB_DIR"
    tmp=$(mktemp "$DB_DIR/deploy-result.env.tmp.XXXXXX")
    {
        printf 'XUI_VERSION=%q\n' "$XUI_VERSION"
        printf 'XRAY_VERSION=%q\n' "$XRAY_VERSION"
        printf 'XUI_USERNAME=%q\n' "$username"
        printf 'XUI_PASSWORD=%q\n' "$password"
        printf 'XUI_PANEL_PORT=%q\n' "$port"
        printf 'XUI_WEB_BASE_PATH=%q\n' "/${path}/"
        printf 'XUI_ACCESS_URL=%q\n' "https://${domain}:${port}/${path}/"
    } > "$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv -f -- "$tmp" "$RESULT_FILE"
}

install_xui() {
    local domain panel_port panel_path admin_user admin_password image attempt
    domain=$(cfg_get '.domain')
    panel_port=$(cfg_get '.panelPort')
    panel_path=$(cfg_get '.panelBasePath')
    admin_user=$(cfg_get '.adminUsername')
    admin_password=$(cfg_get '.adminPassword')
    [[ -z "${XUI_DB_FOLDER:-}${XUI_DB_TYPE:-}${XUI_DB_DSN:-}${XUI_BIN_FOLDER:-}" ]] || die "Нестандартные переменные XUI не поддерживаются."
    ensure_docker
    prepare_pinned_release
    ensure_image_lock
    configure_fail2ban
    generate_runtime_files
    if is_done xui; then
        verify_pinned_binaries || die "Проверенные бинарники изменены."
        compose up -d --pull never --no-build
        verify_runtime
        wait_for_panel
        return 0
    fi
    if [[ ! -f "$DB_FILE" ]] && port_is_listening "$panel_port"; then
        die "Порт панели занят неизвестным процессом."
    fi
    if ! is_done db-initialized; then
        [[ ! -f "$DB_FILE" ]] || is_done db-init-started || die "Найдена неизвестная база Docker-узла."
        mark_done db-init-started
        image=$(jq -er '.image' "$IMAGE_LOCK_FILE")
        # Credentials travel over stdin; docker's persisted argv contains no password.
        printf '%s\n' "$admin_user" "$admin_password" "$panel_port" "$panel_path" "$domain" |
            docker_local run --rm -i --network none --entrypoint /bin/sh \
                --mount "type=bind,src=$DB_DIR,dst=/etc/x-ui" \
                --mount "type=bind,src=$XUI_BIN,dst=/app/x-ui,readonly" \
                -e XUI_IN_DOCKER=true -e XUI_ENABLE_FAIL2BAN=true "$image" -eu -c '
IFS= read -r u
IFS= read -r p
IFS= read -r port
IFS= read -r path
IFS= read -r domain
/app/x-ui setting -username "$u" -password "$p" -port "$port" -webBasePath "$path" >/dev/null
/app/x-ui setting -webCert "/etc/letsencrypt/live/$domain/fullchain.pem" -webCertKey "/etc/letsencrypt/live/$domain/privkey.pem" >/dev/null
/app/x-ui migrate >/dev/null
'
        [[ "$(sqlite3 -readonly "$DB_FILE" "SELECT value FROM settings WHERE key='webPort';")" == "$panel_port" ]] || die "CLI не сохранил порт."
        [[ "$(sqlite3 -readonly "$DB_FILE" "SELECT value FROM settings WHERE key='webCertFile';")" == "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || die "CLI не сохранил сертификат."
        [[ "$(sqlite3 -readonly "$DB_FILE" "SELECT value FROM settings WHERE key='webKeyFile';")" == "/etc/letsencrypt/live/$domain/privkey.pem" ]] || die "CLI не сохранил ключ сертификата."
        mark_done db-initialized
    fi
    write_result_file
    compose up -d --pull never --no-build
    for attempt in $(seq 1 30); do
        runtime_running && break
        sleep 1
    done
    verify_runtime
    wait_for_panel
    docker_local exec "$CONTAINER_NAME" fail2ban-client ping | grep -Fq pong || die "Контейнер не видит Fail2ban хоста."
    docker_local exec "$CONTAINER_NAME" fail2ban-client status 3x-ipl >/dev/null || die "В контейнере недоступен jail 3x-ipl."
    mark_done xui
    ok "3x-ui $XUI_VERSION / Xray $XRAY_VERSION работают в Docker."
    if ! is_done credentials-shown; then
        printf '\nДанные панели:\n  URL: https://%s:%s/%s/\n  Login: %s\n  Password: %s\n  Root-only копия: %s\n\n' \
            "$domain" "$panel_port" "$panel_path" "$admin_user" "$admin_password" "$RESULT_FILE"
        mark_done credentials-shown
    fi
}

local_api_base() {
    printf 'https://%s:%s/%s/panel/api' "$(cfg_get '.domain')" "$(cfg_get '.panelPort')" "$(cfg_get '.panelBasePath')"
}

wait_for_panel() {
    local domain port path attempt
    domain=$(cfg_get '.domain')
    port=$(cfg_get '.panelPort')
    path=$(cfg_get '.panelBasePath')
    for attempt in $(seq 1 30); do
        if curl --disable --silent --show-error --fail --noproxy '*' \
            --resolve "${domain}:${port}:127.0.0.1" \
            --connect-timeout 2 --max-time 4 \
            "https://${domain}:${port}/${path}/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    die "Панель не отвечает по локальному HTTPS после 30 секунд."
}


api_call() {
    local token="$1" method="$2" url="$3" body_file="${4:-}" resolve="${5:-}" content_type="${6:-application/json}"
    local header_fd response_file code curl_rc=0
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || { err "Некорректный формат API-токена."; return 2; }
    response_file=$(mktemp /run/xui-node-docker.response.XXXXXX)
    chmod 0600 "$response_file"
    # A pipe descriptor, not argv or a file on disk (also for the main token).
    exec {header_fd}< <(printf 'Authorization: Bearer %s\nAccept: application/json\nContent-Type: %s\n' "$token" "$content_type")

    local -a args=(--silent --show-error --proto '=https' --noproxy '*' --request "$method" --header "@/dev/fd/${header_fd}" --connect-timeout 10 --max-time 45 --output "$response_file" --write-out '%{http_code}')
    [[ -n "$body_file" ]] && args+=(--data-binary "@${body_file}")
    [[ -n "$resolve" ]] && args+=(--resolve "$resolve")

    if code=$(curl --disable "${args[@]}" "$url"); then
        curl_rc=0
    else
        curl_rc=$?
    fi
    exec {header_fd}<&-

    if (( curl_rc != 0 )); then
        secure_remove_file "$response_file"
        return "$curl_rc"
    fi
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
        err "API вернул HTTP $code. Тело ответа не выводится, чтобы не раскрыть секреты."
        secure_remove_file "$response_file"
        return 22
    fi
    cat "$response_file"
    secure_remove_file "$response_file"
}

disable_node_subscription_server() {
    is_done sub-disabled && return 0
    local response body
    response=$(local_api_call "$LOCAL_API_TOKEN" POST /setting/all /dev/null) || die "Не удалось прочитать настройки панели."
    jq -e '.success == true and (.obj|type=="object")' <<< "$response" >/dev/null || die "Некорректный ответ настроек."
    body=$(mktemp /run/xui-node-docker.settings.XXXXXX.json)
    register_temp "$body"
    jq '.obj | .subEnable=false | .subJsonEnable=false | .subClashEnable=false' <<< "$response" > "$body"
    response=$(local_api_call "$LOCAL_API_TOKEN" POST /setting/update "$body") || die "Не удалось отключить отдельный сервер подписок узла."
    jq -e '.success==true' <<< "$response" >/dev/null || die "API отклонил настройки подписок."
    restart_runtime
    wait_for_panel
    mark_done sub-disabled
}

local_api_call() {
    local token="$1" method="$2" endpoint="$3" body_file="${4:-}" content_type="${5:-application/json}"
    local domain port
    domain=$(cfg_get '.domain')
    port=$(cfg_get '.panelPort')
    api_call "$token" "$method" "$(local_api_base)${endpoint}" "$body_file" "${domain}:${port}:127.0.0.1" "$content_type"
}

ensure_bootstrap_token() {
    if [[ -s "$BOOTSTRAP_TOKEN_FILE" ]]; then
        LOCAL_API_TOKEN=$(tr -d '\r\n' < "$BOOTSTRAP_TOKEN_FILE")
    else
        local output name tmp
        local count
        count=$(sqlite3 -readonly "$DB_FILE" 'SELECT count(*) FROM api_tokens;')
        if [[ "$count" != 0 ]]; then
            is_done bootstrap-generation-started || die "Обнаружены ранее созданные API-токены; CLI не будет их ротировать."
            [[ "$(sqlite3 -readonly "$DB_FILE" "SELECT count(*) FROM api_tokens WHERE name NOT IN ('install','cli-fallback');")" == 0 ]] || die "Найдены посторонние API-токены; требуется ручная проверка."
        fi
        mark_done bootstrap-generation-started
        output=$(xui_cli setting -getApiToken true 2>/dev/null)
        LOCAL_API_TOKEN=$(sed -n 's/^apiToken:[[:space:]]*//p' <<< "$output" | tail -n 1)
        [[ "$LOCAL_API_TOKEN" =~ ^[A-Za-z0-9]{48}$ ]] || die "Не удалось получить временный локальный API-токен."
        if grep -q 'fallback token' <<< "$output"; then
            name="cli-fallback"
        else
            name="install"
        fi
        tmp=$(mktemp "${STATE_DIR}/bootstrap-admin-token.tmp.XXXXXX")
        printf '%s\n' "$LOCAL_API_TOKEN" > "$tmp"
        chmod 0600 "$tmp"
        mv -f -- "$tmp" "$BOOTSTRAP_TOKEN_FILE"
        printf '%s\n' "$name" > "$BOOTSTRAP_NAME_FILE"
        chmod 0600 "$BOOTSTRAP_NAME_FILE"
    fi

    local status
    status=$(local_api_call "$LOCAL_API_TOKEN" GET /server/status) || die "Временный локальный API-токен не работает."
    jq -e '.success == true' <<< "$status" >/dev/null || die "Локальный API 3x-ui отклонил запрос."
}

scan_reality_target() {
    is_done reality-target && return 0
    local body response
    body=$(mktemp /run/xui-node-docker.body.XXXXXX)
    register_temp "$body"
    jq -nj --arg target "$REALITY_TARGET" --arg sni "$REALITY_SNI" \
        '{target:$target,sni:$sni,xver:0,allowPrivate:false} | to_entries | map(.key + "=" + (.value | tostring | @uri)) | join("&")' > "$body"
    info "Проверка Google как REALITY target..."
    response=$(local_api_call "$LOCAL_API_TOKEN" POST /server/scanRealityTarget "$body" "application/x-www-form-urlencoded") || die "Не удалось проверить REALITY target $REALITY_TARGET."
    jq -e '.success == true and .obj.feasible == true and .obj.tls13 == true and .obj.x25519 == true and .obj.certValid == true' <<< "$response" >/dev/null || \
        die "Google не прошёл встроенную проверку REALITY на этом сервере. Другой target автоматически не выбирается."
    mark_done reality-target
    ok "Google поддерживает необходимые TLS 1.3/X25519 параметры для REALITY."
}

build_inbound_payload() {
    local destination="$1" private_key="$2" public_key="$3" client_uuid="$4" short_id="$5" expiry_ms="$6" spider_x="$7"
    local domain test_email display_name
    domain=$(cfg_get '.domain')
    test_email=$(cfg_get '.testEmail')
    display_name=$(cfg_get '.displayName')
    jq -n \
        --rawfile privateKey <(printf '%s' "$private_key") \
        --arg publicKey "$public_key" \
        --arg clientUuid "$client_uuid" \
        --arg shortId "$short_id" \
        --arg testEmail "$test_email" \
        --arg remark "$display_name" \
        --arg target "$REALITY_TARGET" \
        --arg sni "$REALITY_SNI" \
        --arg tag "$INBOUND_TAG" \
        --arg shareAddr "$domain" \
        --arg spiderX "$spider_x" \
        --argjson expiryTime "$expiry_ms" \
        --argjson totalGB "$TEST_TRAFFIC_BYTES" \
        --argjson limitIp "$TEST_IP_LIMIT" \
        '{
          enable:false,
          remark:$remark,
          listen:"",
          port:443,
          protocol:"vless",
          expiryTime:0,
          total:0,
          tag:$tag,
          shareAddrStrategy:"custom",
          shareAddr:$shareAddr,
          settings:{
            clients:[{
              id:$clientUuid,
              email:$testEmail,
              flow:"xtls-rprx-vision",
              limitIp:$limitIp,
              totalGB:$totalGB,
              expiryTime:$expiryTime,
              enable:true,
              tgId:0,
              subId:($clientUuid|gsub("-";"")),
              comment:"Temporary Happ Windows deployment test",
              reset:0
            }],
            decryption:"none",
            encryption:"none",
            testseed:[],
            fallbacks:[]
          },
          streamSettings:{
            network:"tcp",
            security:"reality",
            tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},
            realitySettings:{
              show:false,
              xver:0,
              target:$target,
              serverNames:[$sni],
              privateKey:$privateKey,
              maxTimeDiff:0,
              shortIds:[$shortId],
              mldsa65Seed:"",
              settings:{
                publicKey:$publicKey,
                fingerprint:"firefox",
                serverName:"",
                spiderX:$spiderX,
                mldsa65Verify:""
              }
            }
          },
          sniffing:{
            enabled:true,
            destOverride:["http","tls","fakedns"],
            metadataOnly:false,
            routeOnly:false
          }
        }' > "$destination"
}

validate_preflight_xray_config() {
    local inbound_payload="$1" preflight
    preflight=$(mktemp /run/xui-node-docker.preflight.XXXXXX.json)
    register_temp "$preflight"
    jq '{
          log:{loglevel:"warning"},
          inbounds:[(. | {
            listen:"0.0.0.0",
            port,protocol,settings,streamSettings,tag,sniffing
          })],
          outbounds:[
            {protocol:"freedom",settings:{},tag:"direct"},
            {protocol:"blackhole",settings:{},tag:"blocked"}
          ]
        }
        | .inbounds[0].streamSettings.realitySettings |= del(.settings)' "$inbound_payload" > "$preflight"

    jq -e '.inbounds[0].streamSettings.realitySettings | (has("minClientVer")|not) and (has("maxClientVer")|not)' "$preflight" >/dev/null || \
        die "В предварительной конфигурации неожиданно появились ограничения версии клиента."
    info "Проверка конфигурации бинарником Xray ${XRAY_VERSION} до создания inbound..."
    xray_test_config "$preflight"
}

find_existing_inbound() {
    local response
    response=$(local_api_call "$LOCAL_API_TOKEN" GET /inbounds/list) || return 1
    jq -e '.success == true and (.obj|type=="array")' <<< "$response" >/dev/null || return 1
    jq -e --arg tag "$INBOUND_TAG" '(.obj|length)<=1 and all(.obj[]; .tag==$tag)' <<< "$response" >/dev/null || return 1
    jq -c --arg tag "$INBOUND_TAG" 'first(.obj[] | select(.tag == $tag)) // empty' <<< "$response"
}

ensure_inbound_and_test_client() {
    local existing response key_response private_key public_key client_uuid short_id expiry_ms spider_x payload inbound_id
    existing=$(find_existing_inbound) || die "Не удалось прочитать inbound либо обнаружены посторонние inbound. Создание запрещено."
    if [[ -n "$existing" ]]; then
        jq -e --arg email "$(cfg_get '.testEmail')" '
            .port == 443 and .protocol == "vless" and
            .streamSettings.security == "reality" and
            .streamSettings.realitySettings.target == "www.google.com:443" and
            (.streamSettings.realitySettings.serverNames | index("www.google.com") != null) and
            (.streamSettings.realitySettings | has("minClientVer") | not) and
            (.streamSettings.realitySettings | has("maxClientVer") | not) and
            (.settings.clients | length == 1) and .settings.clients[0].email == $email
        ' <<< "$existing" >/dev/null || die "Inbound с тегом $INBOUND_TAG существует, но не совпадает с безопасным шаблоном."
        inbound_id=$(jq -r '.id' <<< "$existing")
        cfg_set_number inboundId "$inbound_id"
    else
        response=$(local_api_call "$LOCAL_API_TOKEN" GET /clients/list) || die "Не удалось проверить отсутствие посторонних клиентов."
        jq -e '.success==true and (.obj|type=="array" and length==0)' <<< "$response" >/dev/null || die "На узле есть клиенты; автоматическое создание остановлено."
        port_is_listening 443 && die "TCP/443 уже занят неизвестным процессом; inbound не создаётся."
        key_response=$(local_api_call "$LOCAL_API_TOKEN" GET /server/getNewX25519Cert) || die "Не удалось сгенерировать ключи REALITY."
        private_key=$(jq -er '.obj.privateKey' <<< "$key_response")
        public_key=$(jq -er '.obj.publicKey' <<< "$key_response")
        [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ && "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "3x-ui вернул ключи REALITY неожиданного формата."
        client_uuid=$(xray_cli uuid)
        short_id=$(openssl rand -hex 8)
        expiry_ms=$(( $(date +%s) * 1000 + TEST_LIFETIME_MS ))
        spider_x="/$(openssl rand -hex 8)"
        payload=$(mktemp /run/xui-node-docker.inbound.XXXXXX.json)
        register_temp "$payload"
        build_inbound_payload "$payload" "$private_key" "$public_key" "$client_uuid" "$short_id" "$expiry_ms" "$spider_x"
        jq -e '.streamSettings.realitySettings | (has("minClientVer")|not) and (has("maxClientVer")|not)' "$payload" >/dev/null || \
            die "Payload содержит запрещённые minClientVer/maxClientVer."
        validate_preflight_xray_config "$payload"
        response=$(local_api_call "$LOCAL_API_TOKEN" POST /inbounds/add "$payload") || die "API не создал VLESS REALITY inbound."
        jq -e '.success == true and (.obj.id | numbers)' <<< "$response" >/dev/null || die "API вернул ошибку при создании inbound."
        inbound_id=$(jq -r '.obj.id' <<< "$response")
        cfg_set_number inboundId "$inbound_id"
        existing=$(jq -c '.obj' <<< "$response")
    fi

    # The API first stores a DISABLED inbound. Test a complete generated
    # configuration with this exact inbound before enabling TCP/443.
    payload=$(mktemp /run/xui-node-docker.inbound.XXXXXX.json)
    register_temp "$payload"
    printf '%s\n' "$existing" > "$payload"
    validate_preflight_xray_config "$payload"
    validate_generated_candidate "$payload"
    if ! jq -e '.enable==true' <<< "$existing" >/dev/null; then
        printf '{"enable":true}\n' > "$payload"
        response=$(local_api_call "$LOCAL_API_TOKEN" POST "/inbounds/setEnable/${inbound_id}" "$payload") || die "Не удалось включить проверенный inbound."
        jq -e '.success==true' <<< "$response" >/dev/null || die "API отказал во включении inbound."
    fi
    refresh_xray_after_validation
    verify_actual_xray
    mark_done inbound
    ok "VLESS + REALITY на TCP/443 создан; тестовый клиент ограничен 4 часами, 5 GiB и 3 IP."
}

validate_generated_candidate() {
    local inbound_file="$1" response candidate
    response=$(local_api_call "$LOCAL_API_TOKEN" GET /server/getConfigJson) || die "Не удалось получить конфигурацию из базы 3x-ui."
    jq -e '.success==true and (.obj.inbounds|type=="array")' <<< "$response" >/dev/null || die "API не вернул конфигурацию Xray."
    candidate=$(mktemp /run/xui-node-docker.candidate.XXXXXX.json)
    register_temp "$candidate"
    jq --slurpfile inbound "$inbound_file" --arg tag "$INBOUND_TAG" '
      .obj | .inbounds = ([.inbounds[]|select(.tag!=$tag)] +
      [($inbound[0] | {listen,port,protocol,settings,streamSettings,tag,sniffing}
        | if .listen=="" or .listen==null then del(.listen) else . end
        | .streamSettings.realitySettings |= del(.settings)
        | .settings.clients |= map(select(.enable==true)))])' <<< "$response" > "$candidate"
    xray_test_config "$candidate"
}

refresh_xray_after_validation() {
    local response candidate
    response=$(local_api_call "$LOCAL_API_TOKEN" GET /server/getConfigJson) || die "Не удалось получить конфигурацию для перезапуска Xray."
    candidate=$(mktemp /run/xui-node-docker.generated.XXXXXX.json)
    register_temp "$candidate"
    jq -e 'select(.success==true) | .obj | select(.inbounds|type=="array")' <<< "$response" > "$candidate" || die "Некорректная конфигурация API."
    xray_test_config "$candidate"
    response=$(local_api_call "$LOCAL_API_TOKEN" POST /server/restartXrayService /dev/null) || die "Проверенная конфигурация не была применена Xray."
    jq -e '.success==true' <<< "$response" >/dev/null || die "API не подтвердил перезапуск Xray."
}

verify_actual_xray() {
    local attempt
    for attempt in $(seq 1 20); do
        [[ -s "$XRAY_CONFIG" ]] && break
        sleep 1
    done
    [[ -s "$XRAY_CONFIG" ]] || die "3x-ui не сформировал config.json."
    xray_test_config "$XRAY_CONFIG"
    jq -e --arg tag "$INBOUND_TAG" '
        [.inbounds[] | select(.tag == $tag)] | length == 1
    ' "$XRAY_CONFIG" >/dev/null || die "В фактическом Xray config нет ровно одного inbound $INBOUND_TAG."
    jq -e --arg tag "$INBOUND_TAG" '
        .inbounds[] | select(.tag == $tag) |
        .port == 443 and .protocol == "vless" and
        .streamSettings.security == "reality" and
        .streamSettings.realitySettings.target == "www.google.com:443" and
        (.streamSettings.realitySettings | has("minClientVer") | not) and
        (.streamSettings.realitySettings | has("maxClientVer") | not) and
        (.streamSettings.realitySettings | has("settings") | not)
    ' "$XRAY_CONFIG" >/dev/null || die "Фактическая конфигурация Xray не совпадает с шаблоном или содержит ограничения версий."
    runtime_running || die "Контейнер 3x-ui не активен."
    for attempt in $(seq 1 15); do
        port_is_listening 443 && break
        sleep 1
    done
    port_is_listening 443 || die "После создания inbound TCP/443 не слушается."
    ok "Фактический config.json валиден; TCP/443 слушается."
}

get_test_link() {
    local encoded response link
    encoded=$(jq -rn --arg value "$(cfg_get '.testEmail')" '$value|@uri')
    response=$(local_api_call "$LOCAL_API_TOKEN" GET "/clients/links/${encoded}") || die "Не удалось получить тестовую ссылку."
    link=$(jq -er 'first(.obj[] | select(startswith("vless://")))' <<< "$response")
    [[ "$link" == *"@$(cfg_get '.domain'):443?"* && "$link" == *"security=reality"* ]] || die "Сгенерированная VLESS-ссылка содержит неожиданный адрес или параметры."
    printf '%s\n' "$link"
}

client_is_enabled() {
    local encoded response
    encoded=$(jq -rn --arg value "$(cfg_get '.testEmail')" '$value|@uri')
    response=$(local_api_call "$LOCAL_API_TOKEN" GET "/clients/get/${encoded}") || return 1
    jq -e '.success == true and .obj.client.enable == true' <<< "$response" >/dev/null
}

rearm_test_client_if_needed() {
    is_done client-verified && return 0
    local encoded response body expiry existing answer
    encoded=$(jq -rn --arg value "$(cfg_get '.testEmail')" '$value|@uri')
    response=$(local_api_call "$LOCAL_API_TOKEN" GET "/clients/get/${encoded}") || die "Тестовый клиент не найден."
    jq -e '.success==true and (.obj.client|type=="object")' <<< "$response" >/dev/null || die "API не вернул тестового клиента."
    if jq -e --argjson now "$(( $(date +%s)*1000 ))" '.obj | .client.enable==true and .client.expiryTime>$now and .usedTraffic<.client.totalGB' <<< "$response" >/dev/null; then
        return 0
    fi
    read -rp "Продлить ЭТОГО ЖЕ тестового клиента ещё на 4 часа (без сброса трафика)? Введите ТЕСТ: " answer
    [[ "${answer^^}" == ТЕСТ ]] || die "Продление теста не подтверждено."
    jq -e '.obj.usedTraffic < .obj.client.totalGB' <<< "$response" >/dev/null || die "Тестовые 5 GiB исчерпаны; автоматический сброс трафика запрещён."
    existing=$(find_existing_inbound) || die "Не удалось прочитать исходную модель клиента."
    expiry=$(( $(date +%s) * 1000 + TEST_LIFETIME_MS ))
    body=$(mktemp /run/xui-node-docker.body.XXXXXX)
    register_temp "$body"
    jq --argjson expiry "$expiry" --argjson total "$TEST_TRAFFIC_BYTES" --argjson limit "$TEST_IP_LIMIT" \
        '.settings.clients[0] | .enable=true | .expiryTime=$expiry | .totalGB=$total | .limitIp=$limit' <<< "$existing" > "$body"
    response=$(local_api_call "$LOCAL_API_TOKEN" POST "/clients/update/${encoded}" "$body") || die "Не удалось повторно активировать тестового клиента."
    jq -e '.success == true' <<< "$response" >/dev/null || die "API отклонил повторную активацию тестового клиента."
    refresh_xray_after_validation
    verify_actual_xray
}

manual_happ_test() {
    is_done client-verified && return 0
    rearm_test_client_if_needed
    local link answer report observed_ip
    link=$(get_test_link)
    printf '\n%sТест только в Happ на Windows%s\n' "$C_GREEN" "$C_RESET"
    printf '1. Импортируйте эту VLESS-ссылку в Happ:\n\n%s\n\n' "$link"
    printf '2. Либо отсканируйте QR-код:\n\n'
    printf '%s' "$link" | qrencode -t ANSIUTF8
    printf '\n3. Выберите этот профиль, включите TUN/полный туннель и откройте несколько сайтов.\n'
    printf '   Проверьте IPv4, например через https://api4.ipify.org. Ожидается: %s\n' "$(cfg_get '.publicIPv4')"
    warn "Отсутствие minClientVer не снимает встроенный минимум Xray. Совместимость вашей версии Happ подтверждается только этим тестом."
    printf '   Серверная проверка не заменяет этот внешний тест.\n\n'

    while true; do
        read -rp "Результат: 1 = всё работает, 2 = не работает: " answer
        case "$answer" in
            1)
                read -rp "Введите IPv4, который показал браузер Windows через Happ: " observed_ip
                [[ "$observed_ip" == "$(cfg_get '.publicIPv4')" ]] || die "IP не совпал с новым VPS. Регистрация не выполняется."
                disable_test_client
                mark_done client-verified
                ok "Внешний тест подтверждён; тестовый клиент оставлен в базе отключённым."
                return 0
                ;;
            2)
                report=$(collect_diagnostics "Happ Windows connection test failed")
                warn "Узел НЕ зарегистрирован в основной панели."
                warn "Inbound и тестовый клиент сохранены для диагностики; клиент активен до истечения 4 часов."
                warn "Очищенный отчёт: $report"
                warn "После исправления снова запустите скрипт — он продолжит проверку без переустановки."
                exit 20
                ;;
            *) warn "Введите 1 или 2." ;;
        esac
    done
}

disable_test_client() {
    local body response encoded verify
    body=$(mktemp /run/xui-node-docker.body.XXXXXX)
    register_temp "$body"
    jq -n --arg email "$(cfg_get '.testEmail')" '{emails:[$email]}' > "$body"
    response=$(local_api_call "$LOCAL_API_TOKEN" POST /clients/bulkDisable "$body") || die "Не удалось отключить тестового клиента; регистрация остановлена."
    jq -e '.success == true' <<< "$response" >/dev/null || die "API не подтвердил отключение тестового клиента."
    encoded=$(jq -rn --arg value "$(cfg_get '.testEmail')" '$value|@uri')
    verify=$(local_api_call "$LOCAL_API_TOKEN" GET "/clients/get/${encoded}") || die "Не удалось проверить отключение тестового клиента."
    jq -e '.obj.client.enable == false' <<< "$verify" >/dev/null || die "Тестовый клиент остался включён; регистрация остановлена."
    refresh_xray_after_validation
    verify_actual_xray
    jq -e --arg email "$(cfg_get '.testEmail')" '[.inbounds[].settings.clients[]? | select(.email==$email)] | length==0' "$XRAY_CONFIG" >/dev/null || die "Отключённый клиент остался в фактическом config.json."
}

ensure_node_sync_token() {
    if [[ -s "$NODE_TOKEN_FILE" ]]; then
        NODE_API_TOKEN=$(tr -d '\r\n' < "$NODE_TOKEN_FILE")
        local status
        if status=$(local_api_call "$NODE_API_TOKEN" GET /server/status 2>/dev/null) && jq -e '.success == true' <<< "$status" >/dev/null; then
            return 0
        fi
        is_done registration-attempted && die "После попытки регистрации node-sync токен не ротируется автоматически. Проверьте его вручную."
        warn "Сохранённый node-sync токен недействителен; будет заменён до регистрации."
    fi
    if is_done registration-attempted && [[ ! -s "$NODE_TOKEN_FILE" ]]; then
        die "Отсутствует сохранённый node-sync токен после попытки регистрации; автоматическая ротация запрещена."
    fi

    local token_name list token_id delete_body create_body response tmp
    token_name="central-$(cfg_get '.nodeName')"
    list=$(local_api_call "$LOCAL_API_TOKEN" GET /setting/apiTokens) || die "Не удалось прочитать список локальных API-токенов."
    token_id=$(jq -r --arg name "$token_name" 'first(.obj[] | select(.name == $name and .scope == "node-sync") | .id) // empty' <<< "$list")
    if [[ -n "$token_id" ]]; then
        delete_body=$(mktemp /run/xui-node-docker.body.XXXXXX)
        register_temp "$delete_body"
        jq -n '{expectedScope:"node-sync"}' > "$delete_body"
        response=$(local_api_call "$LOCAL_API_TOKEN" POST "/setting/apiTokens/delete/${token_id}" "$delete_body") || die "Не удалось заменить старый node-sync токен."
        jq -e '.success == true' <<< "$response" >/dev/null || die "API не удалил старый node-sync токен."
    fi

    create_body=$(mktemp /run/xui-node-docker.body.XXXXXX)
    register_temp "$create_body"
    jq -n --arg name "$token_name" '{name:$name,scope:"node-sync",expiresAt:0}' > "$create_body"
    response=$(local_api_call "$LOCAL_API_TOKEN" POST /setting/apiTokens/create "$create_body") || die "Не удалось создать node-sync токен."
    NODE_API_TOKEN=$(jq -er '.obj.token' <<< "$response")
    [[ "$NODE_API_TOKEN" =~ ^[A-Za-z0-9]{48}$ ]] || die "node-sync токен имеет неожиданный формат."
    tmp=$(mktemp "${STATE_DIR}/node-sync-token.tmp.XXXXXX")
    printf '%s\n' "$NODE_API_TOKEN" > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$NODE_TOKEN_FILE"
    local status
    status=$(local_api_call "$NODE_API_TOKEN" GET /server/status) || die "Созданный node-sync токен не работает."
    jq -e '.success == true' <<< "$status" >/dev/null || die "Созданный node-sync токен отклонён."
}

normalize_panel_url() {
    # Input is data on stdin, never evaluated as shell code.
    python3 -c '
import sys, urllib.parse
value = sys.stdin.read().strip()
try:
    if not value or any(c.isspace() or ord(c)<32 or ord(c)==127 for c in value):
        raise ValueError()
    u = urllib.parse.urlsplit(value)
    if u.scheme != "https" or not u.hostname or u.username is not None or u.password is not None:
        raise ValueError()
    if u.query or u.fragment or "\\" in value or (u.port is not None and not 1<=u.port<=65535):
        raise ValueError()
    path = u.path.rstrip("/")
    for suffix in ("/panel/nodes", "/panel"):
        if path.endswith(suffix):
            path = path[:-len(suffix)]
            break
    print(urllib.parse.urlunsplit(("https",u.netloc,path,"","")))
except ValueError:
    sys.exit(2)
'
}

ensure_main_panel_base() {
    local value normalized
    value=$(jq -r '.mainPanelBase // empty' "$STATE_FILE")
    if [[ -n "$value" ]]; then
        printf '%s' "$value" | normalize_panel_url >/dev/null || die "Некорректный адрес основной панели в состоянии."
        return
    fi
    while true; do
        read -rp "Полный HTTPS URL основной панели, включая порт и basePath: " value || die "Ввод адреса прерван."
        if normalized=$(printf '%s' "$value" | normalize_panel_url); then break; fi
        warn "Нужен HTTPS URL без логина, пароля, query и fragment; путь /panel/nodes допускается."
    done
    cfg_set_string mainPanelBase "$normalized"
}

normalize_main_panel_base() {
    local value
    value=$(cfg_get '.mainPanelBase') || die "Не задан адрес основной панели."
    printf '%s' "$value" | normalize_panel_url
}

main_api_call() {
    local method="$1" endpoint="$2" body_file="${3:-}"
    api_call "$MAIN_API_TOKEN" "$method" "$(normalize_main_panel_base)/panel/api${endpoint}" "$body_file"
}

build_node_payload() {
    local destination="$1"
    jq -n \
        --arg name "$(cfg_get '.displayName')" \
        --arg address "$(cfg_get '.domain')" \
        --arg basePath "/$(cfg_get '.panelBasePath')/" \
        --rawfile apiToken <(printf '%s' "$NODE_API_TOKEN") \
        --arg tag "$INBOUND_TAG" \
        --argjson port "$(cfg_get '.panelPort')" \
        '{
          id:0,
          name:$name,
          remark:"Provisioned by xui-node-docker",
          scheme:"https",
          address:$address,
          port:$port,
          basePath:$basePath,
          apiToken:$apiToken,
          clearApiToken:false,
          enable:true,
          allowPrivateAddress:false,
          tlsVerifyMode:"verify",
          pinnedCertSha256:"",
          inboundSyncMode:"selected",
          inboundTags:[$tag],
          outboundTag:""
        }' > "$destination"
}

register_with_main_panel() {
    is_done client-verified || die "Внешний тест Happ ещё не подтверждён; регистрация запрещена."
    local local_clients
    local_clients=$(local_api_call "$LOCAL_API_TOKEN" GET /clients/list) || die "Не удалось проверить клиентов перед регистрацией."
    jq -e --arg email "$(cfg_get '.testEmail')" '.success==true and (.obj|length==1) and .obj[0].email==$email and .obj[0].enable==false' <<< "$local_clients" >/dev/null || die "Перед регистрацией на узле должен быть ровно один отключённый тестовый клиент."
    ensure_node_sync_token

    ensure_main_panel_base

    printf '\nДля финальной регистрации нужен API-токен основной панели с областью admin.\n'
    printf 'Он будет прочитан скрыто, использован только в памяти и сразу удалён из переменной.\n'
    read -rsp "API-токен основной панели: " MAIN_API_TOKEN
    printf '\n'
    [[ "$MAIN_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || die "Некорректный формат токена; запрос не отправлен."

    local list duplicates exact_count exact_id payload response remote_inbounds node_id probe verify
    list=$(main_api_call GET /nodes/list) || die "Основная панель недоступна или токен не имеет области admin. Узел не зарегистрирован."
    jq -e '.success == true and (.obj | arrays)' <<< "$list" >/dev/null || die "Основная панель вернула неожиданный ответ."
    duplicates=$(jq --arg name "$(cfg_get '.displayName')" --arg address "$(cfg_get '.domain')" \
        '[.obj[] | select(.name == $name or .address == $address)]' <<< "$list")

    if (( $(jq 'length' <<< "$duplicates") > 0 )); then
        is_done registration-attempted || die "Совпадающий узел уже существовал до попытки регистрации этим скриптом. Автоматическое присвоение запрещено."
        [[ "$(jq 'length' <<< "$duplicates")" == 1 ]] || die "Обнаружено несколько записей с совпадающим именем/доменом. Изменения запрещены."
        exact_count=$(jq \
            --arg name "$(cfg_get '.displayName')" \
            --arg address "$(cfg_get '.domain')" \
            --arg basePath "/$(cfg_get '.panelBasePath')/" \
            --arg tag "$INBOUND_TAG" \
            --argjson port "$(cfg_get '.panelPort')" \
            '[.[] | select(.id>0 and .name == $name and .address == $address and .port == $port and .basePath == $basePath and .scheme=="https" and .tlsVerifyMode=="verify" and .allowPrivateAddress==false and .outboundTag=="" and .enable == true and .inboundSyncMode == "selected" and .inboundTags==[$tag])] | length' <<< "$duplicates")
        [[ "$exact_count" == "1" ]] || die "На основной панели уже есть узел с таким именем или адресом, но параметры отличаются. Автоматическое изменение запрещено."
        exact_id=$(jq \
            --arg name "$(cfg_get '.displayName')" \
            --arg address "$(cfg_get '.domain')" \
            'first(.[] | select(.name == $name and .address == $address) | .id) // empty' <<< "$duplicates")
        probe=$(main_api_call POST "/nodes/probe/${exact_id}" /dev/null) || die "Существующая запись узла не прошла проверку."
        jq -e '.success == true and .obj.status == "online" and .obj.xrayState == "running"' <<< "$probe" >/dev/null || die "Существующий узел зарегистрирован, но не online/running."
        node_id="$exact_id"
        ok "Идентичная запись узла уже существует и работает; повторное создание пропущено."
    else
        local master_clients test_uuid test_subid
        test_uuid=$(jq -er '.obj[0].uuid' <<< "$local_clients")
        test_subid=$(jq -er '.obj[0].subId' <<< "$local_clients")
        master_clients=$(main_api_call GET /clients/list) || die "Не удалось проверить коллизии клиентов на основной панели."
        jq -e --arg email "$(cfg_get '.testEmail')" --arg uuid "$test_uuid" --arg subid "$test_subid" '
          .success==true and (.obj|type=="array") and
          all(.obj[]; .email!=$email and .uuid!=$uuid and .subId!=$subid)' <<< "$master_clients" >/dev/null || die "Идентификатор тестового клиента совпадает с клиентом основной панели; регистрация запрещена."
        payload=$(mktemp /run/xui-node-docker.node.XXXXXX.json)
        register_temp "$payload"
        build_node_payload "$payload"

        info "Проверка узла основной панелью до сохранения..."
        response=$(main_api_call POST /nodes/test "$payload") || die "Основная панель не смогла подключиться к узлу; запись не создана."
        jq -e --arg panel "$XUI_VERSION" --arg xray "$XRAY_VERSION" '
            .success == true and .obj.status == "online" and .obj.xrayState == "running" and
            (.obj.panelVersion | contains($panel)) and (.obj.xrayVersion | contains($xray))
        ' <<< "$response" >/dev/null || die "Проверка основной панели не подтвердила online, Xray running и зафиксированные версии."

        remote_inbounds=$(main_api_call POST /nodes/inbounds "$payload") || die "Основная панель не смогла получить список inbound узла."
        jq -e --arg tag "$INBOUND_TAG" '.success == true and ([.obj[] | select(.tag == $tag and .port == 443 and .protocol == "vless")] | length == 1)' <<< "$remote_inbounds" >/dev/null || \
            die "Основная панель не видит ожидаемый inbound $INBOUND_TAG; регистрация остановлена."

        mark_done registration-attempted
        response=$(main_api_call POST /nodes/add "$payload") || die "Результат добавления неизвестен: запрос мог сохраниться на основной панели. Повторный запуск сначала сверит существующую запись; вручную дубликат не создавайте."
        jq -e '.success == true and (.obj.id | numbers)' <<< "$response" >/dev/null || die "Основная панель не подтвердила добавление узла."
        node_id=$(jq -r '.obj.id' <<< "$response")
        cfg_set_number registeredNodeId "$node_id"
        probe=$(main_api_call POST "/nodes/probe/${node_id}" /dev/null) || die "Узел добавлен, но контрольный probe не выполнен."
        jq -e '.success == true and .obj.status == "online" and .obj.xrayState == "running"' <<< "$probe" >/dev/null || die "Контрольный probe после добавления не подтвердил online/running."
        verify=$(main_api_call GET "/nodes/get/${node_id}") || die "Не удалось проверить сохранённые параметры узла."
        jq -e --arg tag "$INBOUND_TAG" '
            .success == true and .obj.enable == true and .obj.inboundSyncMode == "selected" and
            .obj.inboundTags==[$tag] and .obj.tlsVerifyMode == "verify"
        ' <<< "$verify" >/dev/null || die "Сохранённая запись не подтверждает selective sync и TLS verify."
    fi

    cfg_set_number registeredNodeId "$node_id"
    verify_main_sync "$node_id"
    mark_done registered
    MAIN_API_TOKEN=""
    unset MAIN_API_TOKEN
    finalize_local_credentials
    ok "Узел зарегистрирован; синхронизация включена только для $INBOUND_TAG."
}

verify_main_sync() {
    local node_id="$1" response candidate attempt encoded client inbound_id
    encoded=$(jq -rn --arg value "$(cfg_get '.testEmail')" '$value|@uri')
    for attempt in $(seq 1 12); do
        response=$(main_api_call GET /inbounds/list) || die "Узел добавлен, но проверка синхронизации недоступна. Повторите запуск; узел не удалён."
        jq -e '.success==true and (.obj|type=="array")' <<< "$response" >/dev/null || die "Не удалось прочитать inbound основной панели."
        candidate=$(jq -c --argjson node "$node_id" '[.obj[]|select(.nodeId==$node)]' <<< "$response")
        if [[ "$(jq 'length' <<< "$candidate")" == 1 ]]; then
            jq -e --arg email "$(cfg_get '.testEmail')" --arg tag "$INBOUND_TAG" --arg alias "n${node_id}-${INBOUND_TAG}" '
              .[0] | (.tag==$tag or .tag==$alias) and .port==443 and .protocol=="vless" and
              (.settings.clients|length==1) and .settings.clients[0].email==$email and
              .settings.clients[0].enable==false' <<< "$candidate" >/dev/null || die "Синхронизированный inbound/клиент отличается от ожидаемого. Узел сохранён для диагностики."
            inbound_id=$(jq -r '.[0].id' <<< "$candidate")
            client=$(main_api_call GET "/clients/get/${encoded}") || die "Не удалось проверить импортированного тестового клиента."
            jq -e --argjson id "$inbound_id" '.success==true and .obj.client.enable==false and .obj.inboundIds==[$id]' <<< "$client" >/dev/null || die "Основная панель не подтвердила отключённого клиента с единственным inbound."
            ok "Основная панель импортировала только ожидаемый inbound и отключённого тестового клиента."
            return 0
        fi
        [[ "$(jq 'length' <<< "$candidate")" == 0 ]] || die "Узел синхронизировал более одного inbound. Требуется ручная проверка."
        sleep 5
    done
    die "Узел зарегистрирован, но импорт inbound не подтверждён за минуту. Повторите запуск для сверки; ничего не удалено."
}

finalize_local_credentials() {
    is_done cleanup && return 0
    cleanup_bootstrap_admin_tokens || die "Узел зарегистрирован, но отзыв временного admin-токена не подтверждён. Повторите запуск или отзовите его в панели узла."
    secure_remove_file "$NODE_TOKEN_FILE"
    mark_done cleanup
}

cleanup_bootstrap_admin_tokens() {
    # A timed-out DELETE may already have revoked its own credential.
    # Confirm this locally, read-only; never regenerate an admin token here.
    if [[ "$(sqlite3 -readonly "$DB_FILE" "SELECT count(*) FROM api_tokens WHERE name IN ('install','cli-fallback');")" == 0 ]]; then
        secure_remove_file "$BOOTSTRAP_TOKEN_FILE"
        secure_remove_file "$BOOTSTRAP_NAME_FILE"
        return 0
    fi
    [[ -s "$BOOTSTRAP_TOKEN_FILE" ]] || return 1
    LOCAL_API_TOKEN=$(tr -d '\r\n' < "$BOOTSTRAP_TOKEN_FILE")
    local current_name list body name id scope response
    current_name=$(tr -d '\r\n' < "$BOOTSTRAP_NAME_FILE" 2>/dev/null || true)
    [[ "$current_name" == install || "$current_name" == cli-fallback ]] || return 1
    list=$(local_api_call "$LOCAL_API_TOKEN" GET /setting/apiTokens) || return 1
    jq -e '.success==true and (.obj|type=="array")' <<< "$list" >/dev/null || return 1
    body=$(mktemp /run/xui-node-docker.body.XXXXXX)
    register_temp "$body"

    for name in install cli-fallback; do
        [[ "$name" == "$current_name" ]] && continue
        id=$(jq -r --arg name "$name" 'first(.obj[] | select(.name == $name and (.scope == "admin" or .scope == "")) | .id) // empty' <<< "$list")
        scope=$(jq -r --arg name "$name" 'first(.obj[] | select(.name == $name and (.scope == "admin" or .scope == "")) | (if .scope == "" then "admin" else .scope end)) // empty' <<< "$list")
        [[ -n "$id" ]] || continue
        [[ -n "$scope" ]] || scope=admin
        jq -n --arg scope "$scope" '{expectedScope:$scope}' > "$body"
        response=$(local_api_call "$LOCAL_API_TOKEN" POST "/setting/apiTokens/delete/${id}" "$body") || return 1
        jq -e '.success==true' <<< "$response" >/dev/null || return 1
    done

    id=$(jq -r --arg name "$current_name" 'first(.obj[] | select(.name == $name and (.scope == "admin" or .scope == "")) | .id) // empty' <<< "$list")
    scope=$(jq -r --arg name "$current_name" 'first(.obj[] | select(.name == $name and (.scope == "admin" or .scope == "")) | (if .scope == "" then "admin" else .scope end)) // empty' <<< "$list")
    if [[ -n "$id" ]]; then
        [[ -n "$scope" ]] || scope=admin
        jq -n --arg scope "$scope" '{expectedScope:$scope}' > "$body"
        response=$(local_api_call "$LOCAL_API_TOKEN" POST "/setting/apiTokens/delete/${id}" "$body") || return 1
        jq -e '.success==true' <<< "$response" >/dev/null || return 1
    else
        return 1
    fi
    LOCAL_API_TOKEN=""
    unset LOCAL_API_TOKEN
    secure_remove_file "$BOOTSTRAP_TOKEN_FILE"
    secure_remove_file "$BOOTSTRAP_NAME_FILE"
}

show_status() {
    printf 'xui-node-docker %s\n' "$SCRIPT_VERSION"
    if [[ ! -f "$STATE_FILE" ]]; then
        printf 'state: not initialized\n'
        return 0
    fi
    printf 'node: %s\n' "$(cfg_get '.displayName')"
    printf 'domain: %s\n' "$(cfg_get '.domain')"
    printf 'panel_port: %s\n' "$(cfg_get '.panelPort')"
    printf 'registered: %s\n' "$(is_done registered && echo yes || echo no)"
    printf 'registration_attempted: %s\n' "$(is_done registration-attempted && echo yes || echo no)"
    printf 'bootstrap_cleanup_verified: %s\n' "$(is_done cleanup && echo yes || echo no)"
    printf 'client_test_verified: %s\n' "$(is_done client-verified && echo yes || echo no)"
    printf 'x-ui_container: %s\n' "$(docker_local inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unavailable)"
    printf 'image_pin: %s\n' "$(verify_runtime >/dev/null 2>&1 && echo OK || echo ERROR)"
    printf 'fail2ban_service: %s\n' "$(systemctl is-active fail2ban.service 2>/dev/null || true)"
    printf 'certbot_timer: %s\n' "$(systemctl is-active certbot.timer 2>/dev/null || true)"
    if verify_pinned_binaries; then
        printf 'pinned_binaries: OK (3x-ui %s, Xray %s)\n' "$XUI_VERSION" "$XRAY_VERSION"
    else
        printf 'pinned_binaries: ERROR\n'
    fi
    printf 'tcp_443_listening: %s\n' "$(port_is_listening 443 && echo yes || echo no)"
    if [[ -f "$DB_FILE" ]]; then
        sqlite3 -readonly -header -column "$DB_FILE" \
            "SELECT id,remark,tag,protocol,port,enable,CASE WHEN json_type(stream_settings,'$.realitySettings.minClientVer') IS NULL THEN 'absent' ELSE 'present' END AS minClientVer,CASE WHEN json_type(stream_settings,'$.realitySettings.maxClientVer') IS NULL THEN 'absent' ELSE 'present' END AS maxClientVer FROM inbounds WHERE tag='${INBOUND_TAG}';" || true
        sqlite3 -readonly -header -column "$DB_FILE" \
            "SELECT email,limit_ip,total_gb,expiry_time,enable FROM clients WHERE email='$(cfg_get '.testEmail')';" || true
    fi
}


docker_local() {
    env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        docker --host unix:///var/run/docker.sock "$@"
}

compose() {
    docker_local compose --project-name "$COMPOSE_PROJECT" --project-directory "$STACK_DIR" \
        --env-file /dev/null --file "$COMPOSE_FILE" "$@"
}

runtime_running() {
    [[ "$(docker_local inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == true ]]
}

restart_runtime() {
    verify_runtime
    compose restart --timeout 30
}

xui_cli() {
    docker_local exec "$CONTAINER_NAME" /app/x-ui "$@"
}

xray_cli() {
    docker_local exec "$CONTAINER_NAME" /app/bin/xray-linux-amd64 "$@"
}

xray_test_config() {
    local config_file="$1"
    [[ -s "$config_file" ]] || return 1
    if [[ "${XUI_NODE_DOCKER_LIBRARY_MODE:-0}" == 1 ]]; then
        "$XRAY_BIN" run -test -config "$config_file"
    else
        docker_local exec -i "$CONTAINER_NAME" /app/bin/xray-linux-amd64 \
            run -test -config stdin: < "$config_file"
    fi
}

ensure_docker() {
    if ! is_done docker-install-started; then
        command -v docker >/dev/null 2>&1 && die "Docker появился после начальной проверки; требуется ручной разбор."
        mark_done docker-install-started
    fi
    if ! is_done docker; then
        install -d -m 0755 /etc/apt/keyrings
        curl --disable --fail --show-error --silent --proto '=https' --connect-timeout 15 --max-time 120 \
            https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod 0644 /etc/apt/keyrings/docker.asc
        cat > /etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        chmod 0644 /etc/apt/sources.list.d/docker.sources
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker.service
        docker_local info >/dev/null || die "Docker daemon недоступен."
        docker_local compose version >/dev/null || die "Docker Compose plugin недоступен."
        mark_done docker
    fi
    systemctl is-active --quiet docker.service || die "Docker не запущен; проверьте службу docker."
    docker_local info >/dev/null
    docker_local compose version >/dev/null
}

prepare_pinned_release() {
    local tmpdir archive extracted entry
    if [[ -d "$XUI_DIR" ]]; then
        verify_pinned_binaries || die "Содержимое release отличается от проверенного архива."
    else
        tmpdir=$(mktemp -d /var/tmp/xui-node-docker.release.XXXXXX)
        register_temp "$tmpdir"
        archive="$tmpdir/release.tar.gz"
        curl --disable --fail --location --show-error --proto '=https' --proto-redir '=https' \
            --retry 3 --connect-timeout 15 --max-time 600 "$XUI_ARCHIVE_URL" -o "$archive"
        printf '%s  %s\n' "$XUI_ARCHIVE_SHA256" "$archive" | sha256sum --check --status || die "Неверный SHA-256 архива."
        # Reject traversal and special entries before extraction.
        python3 - "$archive" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as tar:
    for member in tar:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "x-ui":
            raise SystemExit("Unexpected archive path")
        if not (member.isfile() or member.isdir()):
            raise SystemExit("Unexpected archive member type")
PY
        tar -xzf "$archive" --no-same-owner -C "$tmpdir"
        extracted="$tmpdir/x-ui"
        printf '%s  %s\n%s  %s\n' "$XUI_BINARY_SHA256" "$extracted/x-ui" "$XRAY_BINARY_SHA256" "$extracted/bin/xray-linux-amd64" |
            sha256sum --check --status || die "Бинарники релиза не совпали."
        mv -- "$extracted" "$XUI_DIR"
        chown -R root:root "$XUI_DIR"
        chmod 0755 "$XUI_BIN" "$XRAY_BIN"
        verify_pinned_binaries || die "Версии бинарников не совпали."
    fi
    if [[ ! -d "$STACK_DIR/xray" ]]; then
        install -d -m 0700 "$STACK_DIR/xray"
        cp -a -- "$XUI_DIR/bin/." "$STACK_DIR/xray/"
    fi
    [[ -x "$STACK_DIR/xray/xray-linux-amd64" ]] || die "Рабочий каталог Xray неполон."
    [[ "$(sha256sum "$STACK_DIR/xray/xray-linux-amd64" | awk '{print $1}')" == "$XRAY_BINARY_SHA256" ]] || die "Рабочий Xray изменён."
    install -d -m 0700 "$LOG_DIR/xui" "$STACK_DIR/runtime"
}

validate_image_lock() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    jq -e --arg archive "$XUI_ARCHIVE_SHA256" --arg xui "$XUI_BINARY_SHA256" --arg xray "$XRAY_BINARY_SHA256" '
      .schema==1 and .platform=="linux/amd64" and
      (.image|type=="string" and test("^ghcr\\.io/mhsanaei/3x-ui@sha256:[a-f0-9]{64}$")) and
      .xuiVersion=="3.7.0" and .xrayVersion=="26.7.28" and
      .archiveSha256==$archive and .xuiSha256==$xui and .xraySha256==$xray
    ' "$1" >/dev/null
}

ensure_image_lock() {
    local ref tmp original_version
    if [[ -n "$IMAGE_LOCK_INPUT" ]]; then
        validate_image_lock "$IMAGE_LOCK_INPUT" || die "Переданный image-lock не соответствует комплекту."
        if [[ -f "$IMAGE_LOCK_FILE" ]]; then
            [[ "$(jq -r '.image' "$IMAGE_LOCK_INPUT")" == "$(jq -r '.image' "$IMAGE_LOCK_FILE")" ]] || die "Другой digest для существующего узла запрещён."
        else
            install -m 0600 "$IMAGE_LOCK_INPUT" "$IMAGE_LOCK_FILE"
        fi
    fi
    if [[ ! -f "$IMAGE_LOCK_FILE" ]]; then
        info "Первый узел: получаем официальный тег 3.7.0 и закрепляем digest."
        docker_local pull --platform linux/amd64 "$RUNTIME_REPOSITORY:$RUNTIME_TAG"
        ref=$(docker_local image inspect "$RUNTIME_REPOSITORY:$RUNTIME_TAG" |
            jq -er '.[0].RepoDigests[] | select(test("^ghcr\\.io/mhsanaei/3x-ui@sha256:[a-f0-9]{64}$"))' | head -n 1)
        [[ -n "$ref" ]] || die "Registry не вернул digest образа."
        tmp=$(mktemp "$STACK_DIR/image-lock.json.tmp.XXXXXX")
        jq -n --arg image "$ref" --arg archive "$XUI_ARCHIVE_SHA256" --arg xui "$XUI_BINARY_SHA256" --arg xray "$XRAY_BINARY_SHA256" \
            '{schema:1,platform:"linux/amd64",image:$image,xuiVersion:"3.7.0",xrayVersion:"26.7.28",archiveSha256:$archive,xuiSha256:$xui,xraySha256:$xray}' > "$tmp"
        chmod 0600 "$tmp"
        validate_image_lock "$tmp" || die "Некорректный digest."
        mv -- "$tmp" "$IMAGE_LOCK_FILE"
    fi
    validate_image_lock "$IMAGE_LOCK_FILE" || die "Сохранённый image-lock повреждён."
    ref=$(jq -er '.image' "$IMAGE_LOCK_FILE")
    if ! docker_local image inspect "$ref" >/dev/null 2>&1; then
        docker_local pull --platform linux/amd64 "$ref"
    fi
    [[ "$(docker_local image inspect -f '{{.Os}}/{{.Architecture}}' "$ref")" == linux/amd64 ]] || die "Архитектура образа не amd64."
    original_version=$(docker_local run --rm --network none --entrypoint /app/x-ui "$ref" -v 2>/dev/null | tail -n 1)
    [[ "$original_version" == "$XUI_VERSION" ]] || die "Официальный образ содержит неожиданную версию панели."
    docker_local run --rm --network none --entrypoint /bin/sh "$ref" -eu -c \
        'command -v curl >/dev/null; command -v sha256sum >/dev/null; fail2ban-client -h >/dev/null' ||
        die "В образе нет необходимых curl/sha256sum/Fail2ban client."
    mark_done image
    ok "Docker-образ закреплён; для следующего VPS сохраните --image-lock."
}

verify_runtime() {
    local expected info
    validate_image_lock "$IMAGE_LOCK_FILE" || return 1
    verify_pinned_binaries || return 1
    expected=$(docker_local image inspect -f '{{.Id}}' "$(jq -er '.image' "$IMAGE_LOCK_FILE")") || return 1
    info=$(docker_local inspect "$CONTAINER_NAME") || return 1
    jq -e --arg image "$expected" --arg version "$SCRIPT_VERSION" --arg db "$DB_DIR" --arg release "$XUI_DIR" '
      .[0] | .State.Running==true and .Image==$image and
      .HostConfig.NetworkMode=="host" and .HostConfig.Privileged==false and
      .HostConfig.ReadonlyRootfs==true and
      .Config.Labels["io.xui-node-docker.managed"]==$version and
      ([.Mounts[] | select(.Destination=="/etc/x-ui" and .Source==$db and .RW==true)] | length==1) and
      ([.Mounts[] | select(.Destination=="/app/x-ui" and .Source==($release+"/x-ui") and .RW==false)] | length==1) and
      ([.Mounts[] | select(.Destination=="/app/bin/xray-linux-amd64" and .Source==($release+"/bin/xray-linux-amd64") and .RW==false)] | length==1)
    ' <<< "$info" >/dev/null || return 1
    docker_local exec "$CONTAINER_NAME" /bin/sh /opt/deploy/check-pins.sh || return 1
    docker_local exec "$CONTAINER_NAME" fail2ban-client ping | grep -Fq pong || return 1
    docker_local exec "$CONTAINER_NAME" fail2ban-client status 3x-ipl >/dev/null || return 1
}


generate_runtime_files() {
    local domain port base image
    domain=$(cfg_get '.domain'); port=$(cfg_get '.panelPort'); base=$(cfg_get '.panelBasePath')
    image=$(jq -er '.image' "$IMAGE_LOCK_FILE")
    install -d -m 0700 "$STACK_DIR/runtime" "$LOG_DIR/xui"
    cat > "$STACK_DIR/runtime/check-pins.sh" <<EOF
#!/bin/sh
set -eu
printf '%s  %s\n%s  %s\n' '$XUI_BINARY_SHA256' /app/x-ui '$XRAY_BINARY_SHA256' /app/bin/xray-linux-amd64 | sha256sum -c >/dev/null
[ "\$(/app/x-ui -v 2>/dev/null | tail -n 1)" = '$XUI_VERSION' ]
/app/bin/xray-linux-amd64 version | head -n 1 | grep -F 'Xray $XRAY_VERSION ' >/dev/null
EOF
    cat > "$STACK_DIR/runtime/entrypoint.sh" <<'EOF'
#!/bin/sh
set -eu
/bin/sh /opt/deploy/check-pins.sh
# Fail2ban runs on the host. The shared socket permits real probes and bans.
attempt=0
until fail2ban-client ping >/dev/null 2>&1 && fail2ban-client status 3x-ipl >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || { echo 'Host Fail2ban is unavailable' >&2; exit 1; }
    sleep 2
done
exec /app/x-ui
EOF
    cat > "$STACK_DIR/runtime/healthcheck.sh" <<'EOF'
#!/bin/sh
set -eu
fail2ban-client ping >/dev/null
fail2ban-client status 3x-ipl >/dev/null
curl --disable --noproxy '*' --silent --fail --connect-timeout 2 --max-time 4 \
    --resolve "$XUI_HEALTH_DOMAIN:$XUI_HEALTH_PORT:127.0.0.1" \
    "https://$XUI_HEALTH_DOMAIN:$XUI_HEALTH_PORT/$XUI_HEALTH_PATH/" >/dev/null
EOF
    chmod 0700 "$STACK_DIR/runtime/"*.sh
    jq -n --arg image "$image" --arg stack "$STACK_DIR" --arg db "$DB_DIR" --arg release "$XUI_DIR" \
        --arg logs "$LOG_DIR/xui" --arg version "$SCRIPT_VERSION" --arg domain "$domain" \
        --arg port "$port" --arg path "$base" '
      def bind($src;$dst;$ro): {type:"bind",source:$src,target:$dst,read_only:$ro,bind:{create_host_path:false}};
      {services:{xui:{
        image:$image, platform:"linux/amd64", pull_policy:"never",
        container_name:"xui-node-docker", restart:"unless-stopped", init:true,
        network_mode:"host", read_only:true, user:"0:0",
        cap_drop:["ALL"],cap_add:["NET_BIND_SERVICE"],
        security_opt:["no-new-privileges:true"],
        stop_grace_period:"30s",working_dir:"/app",
        entrypoint:["/bin/sh","/opt/deploy/entrypoint.sh"],
        labels:{"io.xui-node-docker.managed":$version},
        environment:{
          TZ:"UTC",XUI_IN_DOCKER:"true",XUI_MAIN_FOLDER:"/app",
          XUI_DB_FOLDER:"/etc/x-ui",XUI_BIN_FOLDER:"/app/bin",XUI_LOG_FOLDER:"/var/log/x-ui",
          XUI_ENABLE_FAIL2BAN:"true",XRAY_LOCATION_ASSET:"/app/bin",
          XUI_HEALTH_DOMAIN:$domain,XUI_HEALTH_PORT:$port,XUI_HEALTH_PATH:$path
        },
        volumes:[
          bind($db;"/etc/x-ui";false),
          bind($release+"/x-ui";"/app/x-ui";true),
          bind($stack+"/xray";"/app/bin";false),
          bind($release+"/bin/xray-linux-amd64";"/app/bin/xray-linux-amd64";true),
          bind($logs;"/var/log/x-ui";false),
          bind($stack+"/runtime";"/opt/deploy";true),
          bind("/etc/letsencrypt";"/etc/letsencrypt";true),
          bind("/run/fail2ban";"/var/run/fail2ban";true)
        ],
        tmpfs:["/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777","/run:rw,nosuid,nodev,noexec,size=16m"],
        healthcheck:{test:["CMD","/bin/sh","/opt/deploy/healthcheck.sh"],interval:"30s",timeout:"6s",retries:3,start_period:"120s"},
        logging:{driver:"json-file",options:{"max-size":"10m","max-file":"3"}}
      }}}
    ' > "$COMPOSE_FILE"
    chmod 0600 "$COMPOSE_FILE"
    compose config --quiet
}

configure_fail2ban() {
    local port panel_port exempt_csv
    local -a ssh_ports
    panel_port=$(cfg_get '.panelPort')
    mapfile -t ssh_ports < <(detect_ssh_ports)
    (( ${#ssh_ports[@]} > 0 && ${#ssh_ports[@]} <= 12 )) || die "Неожиданное число SSH-портов."
    exempt_csv=$(printf '%s\n' "${ssh_ports[@]}" "$panel_port" 80 | sort -nu | paste -sd, -)
    install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d
    install -d -m 0700 "$LOG_DIR/xui"
    touch "$LOG_DIR/xui/3xipl.log" "$LOG_DIR/xui/3xipl-banned.log"
    cat > /etc/fail2ban/jail.d/sshd-xui-docker.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $(IFS=,; echo "${ssh_ports[*]}")
maxretry = 5
findtime = 10m
bantime = 1h
banaction = iptables-multiport
EOF
    cat > /etc/fail2ban/jail.d/3x-ipl.conf <<EOF
[3x-ipl]
enabled = true
backend = polling
filter = 3x-ipl
action = xui-docker-ipl
logpath = $LOG_DIR/xui/3xipl.log
maxretry = 1
findtime = 32
bantime = 30m
EOF
    cat > /etc/fail2ban/filter.d/3x-ipl.conf <<'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF
    cat > /etc/fail2ban/action.d/xui-docker-ipl.conf <<EOF
[INCLUDES]
before = iptables-allports.conf
[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>
actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>
actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'
actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $LOG_DIR/xui/3xipl-banned.log
actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> $LOG_DIR/xui/3xipl-banned.log
[Init]
name = xui-docker-ipl
chain = INPUT
exemptports = $exempt_csv
EOF
    cat > /etc/logrotate.d/xui-node-docker <<EOF
$LOG_DIR/xui/*.log {
    daily
    size 10M
    rotate 5
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
    chmod 0644 /etc/fail2ban/jail.d/sshd-xui-docker.local /etc/fail2ban/jail.d/3x-ipl.conf \
        /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/xui-docker-ipl.conf /etc/logrotate.d/xui-node-docker
    fail2ban-client -t >/dev/null || die "Конфигурация Fail2ban не прошла проверку."
    systemctl enable --now fail2ban.service
    fail2ban-client reload >/dev/null
    fail2ban-client ping | grep -Fq pong || die "Fail2ban не отвечает."
    fail2ban-client status sshd >/dev/null || die "Нет jail sshd."
    fail2ban-client status 3x-ipl >/dev/null || die "Нет jail 3x-ipl."
    [[ -S /run/fail2ban/fail2ban.sock ]] || die "Не найден сокет Fail2ban."
    mark_done fail2ban
    ok "Fail2ban хоста защищает SSH и обеспечивает лимит IP в контейнере."
}

main() {
    local mode=run own_dir
    while (( $# )); do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --status|--diagnose|--validate|--image-lock)
                [[ "$mode" == run ]] || die "Выберите один режим."
                mode="$1"; shift ;;
            --use-image-lock)
                (( $# >= 2 )) || die "После --use-image-lock нужен путь."
                IMAGE_LOCK_INPUT=$(realpath -e -- "$2") || die "Файл image-lock не найден."
                shift 2 ;;
            run) shift ;;
            *) usage; return 2 ;;
        esac
    done
    require_root_and_platform
    acquire_lock
    check_existing_install
    case "$mode" in
        --status) show_status; return ;;
        --diagnose) collect_diagnostics 'manual request'; return ;;
        --image-lock) validate_image_lock "$IMAGE_LOCK_FILE" || die "Нет корректного image-lock."; cat "$IMAGE_LOCK_FILE"; return ;;
        --validate)
            verify_runtime
            wait_for_panel
            xray_test_config "$XRAY_CONFIG"
            docker_local exec "$CONTAINER_NAME" fail2ban-client status 3x-ipl >/dev/null
            port_is_listening 443 || die "TCP/443 не слушается."
            ok "Контейнер, pin, HTTPS, Xray, Fail2ban и TCP/443 проверены."
            return ;;
    esac
    [[ -t 0 ]] || die "Запускайте скрипт в интерактивном SSH-терминале."
    check_initial_conflicts
    install -d -m 0700 "$STATE_DIR" "$STACK_DIR" "$DB_DIR" "$LOG_DIR"
    [[ -e "$OWNER_FILE" ]] || install -m 0600 /dev/null "$OWNER_FILE"
    if [[ -z "$IMAGE_LOCK_INPUT" ]]; then
        own_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        [[ ! -f "$own_dir/xui-docker-image.lock.json" ]] || IMAGE_LOCK_INPUT="$own_dir/xui-docker-image.lock.json"
    fi
    if is_done registered; then
        verify_runtime
        wait_for_panel
        finalize_local_credentials
        ok "Узел уже зарегистрирован; повторное создание не выполняется."
        show_status
        return
    fi
    prepare_os
    create_or_load_config
    verify_dns
    provider_firewall_checkpoint
    configure_ufw
    audit_ssh_security
    ensure_certificate
    install_xui
    ensure_bootstrap_token
    if is_done registration-attempted; then
        register_with_main_panel
        show_status
        return
    fi
    disable_node_subscription_server
    scan_reality_target
    ensure_inbound_and_test_client
    manual_happ_test
    register_with_main_panel
    printf '\nГотово. Узел %s зарегистрирован; синхронизируется только inbound %s.\n' "$(cfg_get '.displayName')" "$INBOUND_TAG"
    printf 'Тестовый клиент сохранён отключённым. Проверка: sudo %s --status\n' "$0"
}

if [[ "${XUI_NODE_DOCKER_LIBRARY_MODE:-0}" != "1" ]]; then
    main "$@"
fi
