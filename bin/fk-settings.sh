#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155
set -euo pipefail

# FlashKidd SSH Manager shared library and Settings CLI
# This script is designed to be sourced by other fk-* utilities.

if [[ "${FK_SETTINGS_SH_LOADED:-0}" -eq 1 ]]; then
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        fk_settings_cli "$@"
        exit 0
    fi
    return 0 2>/dev/null || true
fi

FK_SETTINGS_SH_LOADED=1

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FK_CONFIG_DIR="${FK_CONFIG_DIR:-/etc/fk-ssh}"
FK_SETTINGS_FILE="$FK_CONFIG_DIR/settings.env"
FK_PORTS_FILE="$FK_CONFIG_DIR/ports.env"
FK_LOG_DIR="$FK_CONFIG_DIR/logs"
FK_BACKUP_DIR="$FK_CONFIG_DIR/backups"
FK_FIREWALL_FILE="$FK_CONFIG_DIR/firewall.rules"
FK_DEFAULT_LOG="$FK_LOG_DIR/fk-ssh.log"
FK_STD_BANNER='+-------------------------------------------------------------+
| FlashKidd SSH Manager                                      |
| Secure • Modern • Customizable                              |
| GitHub: https://github.com/FlashKidd/flashkidd-ssh-manager  |
+-------------------------------------------------------------+'
FK_POST_ACTION_BANNER=0

mkdir -p "$FK_LOG_DIR" "$FK_BACKUP_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Color handling
FK_COLOR_ENABLED=0
FK_COLOR_FORCED=0
FK_COLOR_OFF=0
FK_ARGS=()

fk_color_supports() {
    [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]
}

fk_define_colors() {
    if [[ $FK_COLOR_ENABLED -eq 1 ]]; then
        C_RESET='\033[0m'
        C_DIM='\033[2m'
        C_RED='\033[31;1m'
        C_GREEN='\033[32;1m'
        C_YELLOW='\033[33;1m'
        C_BLUE='\033[34;1m'
        C_MAGENTA='\033[35;1m'
        C_CYAN='\033[36;1m'
        C_WHITE='\033[37;1m'
    else
        C_RESET=''
        C_DIM=''
        C_RED=''
        C_GREEN=''
        C_YELLOW=''
        C_BLUE=''
        C_MAGENTA=''
        C_CYAN=''
        C_WHITE=''
    fi
}

fk_common_init() {
    FK_ARGS=()
    local arg
    FK_COLOR_ENABLED=0
    FK_COLOR_FORCED=0
    FK_COLOR_OFF=0
    if [[ ${FK_COLOR:-0} -eq 1 ]]; then
        FK_COLOR_ENABLED=1
    fi
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --color)
                FK_COLOR_ENABLED=1
                FK_COLOR_FORCED=1
                ;;
            --no-color)
                FK_COLOR_ENABLED=0
                FK_COLOR_OFF=1
                ;;
            *)
                FK_ARGS+=("$arg")
                ;;
        esac
        shift || true
    done
    if [[ $FK_COLOR_ENABLED -eq 0 && $FK_COLOR_OFF -eq 0 ]]; then
        if fk_color_supports; then
            FK_COLOR_ENABLED=1
        fi
    fi
    fk_define_colors
}

fk_color() {
    local color="$1"; shift
    local text="$*"
    case "$color" in
        red) printf '%s%s%s' "$C_RED" "$text" "$C_RESET" ;;
        green) printf '%s%s%s' "$C_GREEN" "$text" "$C_RESET" ;;
        yellow) printf '%s%s%s' "$C_YELLOW" "$text" "$C_RESET" ;;
        blue) printf '%s%s%s' "$C_BLUE" "$text" "$C_RESET" ;;
        magenta) printf '%s%s%s' "$C_MAGENTA" "$text" "$C_RESET" ;;
        cyan) printf '%s%s%s' "$C_CYAN" "$text" "$C_RESET" ;;
        dim) printf '%s%s%s' "$C_DIM" "$text" "$C_RESET" ;;
        bold) printf '\033[1m%s%s' "$text" "$C_RESET" ;;
        *) printf '%s' "$text" ;;
    esac
}

fk_log() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '[%s] %s\n' "$ts" "$msg" >> "$FK_DEFAULT_LOG"
}

fk_require_root() {
    if [[ $EUID -ne 0 ]]; then
        printf 'This command must be run as root.\n' >&2
        exit 1
    fi
}

fk_load_env() {
    if [[ -f "$FK_SETTINGS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$FK_SETTINGS_FILE"
    fi
    if [[ -f "$FK_PORTS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$FK_PORTS_FILE"
    fi
}

fk_save_env_value() {
    local file="$1" key="$2" value="$3"
    touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

fk_banner() {
    printf '%s\n' "$FK_STD_BANNER"
}

fk_box() {
    local title="$1"; shift
    local lines=("$@")
    local width=0
    for line in "${lines[@]}"; do
        [[ ${#line} -gt $width ]] && width=${#line}
    done
    [[ ${#title} -gt $width ]] && width=${#title}
    width=$((width + 4))
    local border
    border="+$(printf -- '-%.0s' $(seq 1 $((width-2))))+"
    printf '%s\n' "$border"
    printf '| %-'"$((width-4))"'s |
' "$title"
    printf '\n'
    for line in "${lines[@]}"; do
        printf '| %-'"$((width-4))"'s |
' "$line"
        printf '\n'
    done
    printf '%s\n' "$border"
}

fk_prompt_confirm() {
    local prompt="${1:-Are you sure? [y/N]}"
    local reply
    read -rp "$prompt " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

fk_primary_ipv4() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    printf '%s' "${ip:-unknown}"
}

fk_validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((port > 0 && port < 65536))
}

fk_port_in_use() {
    local port="$1"
    if ss -lntup 2>/dev/null | awk '{print $5}' | grep -q ":$port$"; then
        return 0
    fi
    return 1
}

fk_firewall_backend() {
    if command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
        echo ufw
        return
    fi
    if command -v nft >/dev/null 2>&1; then
        echo nft
        return
    fi
    if command -v iptables >/dev/null 2>&1; then
        echo iptables
        return
    fi
    echo none
}

fk_firewall_flush() {
    local backend
    backend=$(fk_firewall_backend)
    case "$backend" in
        ufw)
            while read -r rule; do
                [[ -z "$rule" ]] && continue
                ufw --force delete allow "$rule" >/dev/null 2>&1 || true
            done < <(awk -F'|' '{print $2}' "$FK_FIREWALL_FILE" 2>/dev/null)
            ;;
        nft)
            nft delete table inet fk_ssh >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -t filter -D INPUT -j FLASHKIDD >/dev/null 2>&1 || true
            iptables -t filter -F FLASHKIDD >/dev/null 2>&1 || true
            iptables -t filter -X FLASHKIDD >/dev/null 2>&1 || true
            ;;
        *) ;;
    esac
    : > "$FK_FIREWALL_FILE"
}

fk_firewall_apply() {
    local backend ports proto service
    backend=$(fk_firewall_backend)
    ports="$1"
    proto="${2:-tcp}"
    service="${3:-generic}"
    touch "$FK_FIREWALL_FILE"
    case "$backend" in
        ufw)
            ufw --force enable >/dev/null 2>&1 || true
            local port
            for port in $ports; do
                ufw allow "$port"/$proto comment "FlashKidd $service" >/dev/null 2>&1 || true
                printf '%s|%s/%s\n' "$service" "$port" "$proto" >> "$FK_FIREWALL_FILE"
            done
            ;;
        nft)
            nft list table inet fk_ssh >/dev/null 2>&1 || nft add table inet fk_ssh
            nft list chain inet fk_ssh input >/dev/null 2>&1 || nft add chain inet fk_ssh input '{ type filter hook input priority 0; }'
            local port
            for port in $ports; do
                nft add rule inet fk_ssh input $proto dport "$port" accept comment "FlashKidd $service" >/dev/null 2>&1 || true
                printf '%s|%s/%s\n' "$service" "$port" "$proto" >> "$FK_FIREWALL_FILE"
            done
            ;;
        iptables)
            iptables -t filter -N FLASHKIDD >/dev/null 2>&1 || true
            iptables -t filter -C INPUT -j FLASHKIDD >/dev/null 2>&1 || iptables -t filter -A INPUT -j FLASHKIDD
            local port
            for port in $ports; do
                iptables -t filter -C FLASHKIDD -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
                    iptables -t filter -A FLASHKIDD -p "$proto" --dport "$port" -m comment --comment 'FlashKidd allow' -j ACCEPT
                printf '%s|%s/%s\n' "$service" "$port" "$proto" >> "$FK_FIREWALL_FILE"
            done
            ;;
        none)
            printf 'Firewall backend not available; skipping firewall configuration.\n' >&2
            ;;
    esac
}

fk_firewall_summary() {
    local backend=$(fk_firewall_backend)
    printf 'Firewall backend: %s\n' "$backend"
    if [[ -s "$FK_FIREWALL_FILE" ]]; then
        printf 'Open ports managed by FlashKidd:\n'
        column -t -s'|' "$FK_FIREWALL_FILE" 2>/dev/null | sed 's/\// /'
    else
        printf 'No FlashKidd managed firewall entries.\n'
    fi
}

fk_firewall_reconcile_ports() {
    local entries="$1" service="$2"
    fk_firewall_flush
    local entry port proto
    for entry in $entries; do
        port="${entry%/*}"
        proto="${entry##*/}"
        fk_firewall_apply "$port" "$proto" "$service"
    done
    fk_firewall_summary
}

fk_print_post_action() {
    FK_POST_ACTION_BANNER=1
    fk_banner
}

fk_require_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf 'Missing required file: %s\n' "$file" >&2
        exit 1
    fi
}

fk_settings_cli() {
    fk_common_init "$@"
    set -- "${FK_ARGS[@]}"
    fk_require_root
    fk_load_env
    local choice
    while true; do
        fk_banner
        printf '\nSettings & Security Menu\n'
        cat <<'MENU'
1) Toggle remote fetch guard
2) View pinned versions
3) Update pinned versions
4) Verify binary checksums
5) Show firewall summary
0) Back
MENU
        read -rp 'Select option: ' choice
        case "$choice" in
            1)
                local current="${FK_DISABLE_REMOTE_FETCH:-0}"
                local new=1
                if [[ "$current" == "1" ]]; then
                    new=0
                fi
                fk_save_env_value "$FK_SETTINGS_FILE" "FK_DISABLE_REMOTE_FETCH" "$new"
                fk_box 'Remote Fetch Guard' "Updated: FK_DISABLE_REMOTE_FETCH=$new"
                fk_print_post_action
                ;;
            2)
                printf 'Pinned binary versions (settings.env):\n'
                if [[ -f "$FK_SETTINGS_FILE" ]]; then
                    grep '^FK_PIN_' "$FK_SETTINGS_FILE" || printf 'No pins yet.\n'
                else
                    printf 'No pins yet.\n'
                fi
                fk_print_post_action
                ;;
            3)
                read -rp 'Binary name (e.g. V2RAY): ' bin
                read -rp 'Version string: ' ver
                read -rp 'SHA256 checksum: ' sha
                if [[ -n "$bin" && -n "$ver" && -n "$sha" ]]; then
                    fk_save_env_value "$FK_SETTINGS_FILE" "FK_PIN_${bin}_VERSION" "$ver"
                    fk_save_env_value "$FK_SETTINGS_FILE" "FK_PIN_${bin}_SHA256" "$sha"
                    fk_box 'Pinned Binary' "${bin}: $ver" "SHA256: $sha"
                    fk_print_post_action
                fi
                ;;
            4)
                read -rp 'Path to binary: ' path
                if [[ -x "$path" ]]; then
                    local sha
                    sha=$(sha256sum "$path" | awk '{print $1}')
                    fk_box 'Checksum' "File: $path" "SHA256: $sha"
                    fk_print_post_action
                else
                    printf 'Invalid path or not executable.\n'
                fi
                ;;
            5)
                fk_firewall_summary
                fk_print_post_action
                ;;
            0)
                break
                ;;
            *)
                printf 'Invalid option.\n'
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    fk_settings_cli "$@"
fi
