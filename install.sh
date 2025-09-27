#!/usr/bin/env bash
set -euo pipefail

# FlashKidd SSH Manager installer
# This script is idempotent and safe to re-run.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/fk-ssh"
BIN_DIR="$REPO_ROOT/bin"
SYMLINK_DIR="/usr/local/bin"
LOG_DIR="$CONFIG_DIR/logs"
BACKUP_DIR="$CONFIG_DIR/backups"
PORTS_WERE_PRESENT=0

DRY_RUN=0
AUTO_MODE=0
CHANNEL="stable"

print_step() {
    printf '==> %s\n' "$1"
}

print_warn() {
    printf 'Warning: %s\n' "$1" >&2
}

usage() {
    cat <<USAGE
FlashKidd SSH Manager installer
Usage: $0 [--dry-run] [--auto] [--channel <name>]

Options:
  --dry-run         Show actions without changing the system
  --auto            Skip confirmations; accept defaults when possible
  --channel <name>  Persisted in settings.env as FK_CHANNEL=<name>
  --help            Display this help message
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --auto)
                AUTO_MODE=1
                shift
                ;;
            --channel)
                CHANNEL="${2:-}"
                if [[ -z "$CHANNEL" ]]; then
                    printf 'Error: --channel requires a value\n' >&2
                    exit 2
                fi
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage
                exit 2
                ;;
        esac
    done
}

run_or_print() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        printf 'This installer must be run as root.\n' >&2
        exit 1
    fi
}

install_packages() {
    local pkgs=("openssh-server" "curl" "jq" "coreutils" "iproute2" "nftables" "iptables" "ufw" "openvpn" "wireguard-tools" "nginx" "openssl" "tar" "xz-utils" "dnsutils" "netcat-openbsd")
    print_step "Installing dependencies via apt"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] apt-get update\n'
        printf '[dry-run] apt-get install -y %s\n' "${pkgs[*]}"
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    else
        print_warn "apt-get not found. Please install dependencies manually."
    fi
}

create_dirs() {
    for dir in "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR"; do
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '[dry-run] mkdir -p %s\n' "$dir"
        else
            mkdir -p "$dir"
        fi
    done
    if [[ -f "$CONFIG_DIR/ports.env" ]]; then
        PORTS_WERE_PRESENT=1
    fi
}

copy_examples() {
    local files=("ports.env" "settings.env")
    for file in "${files[@]}"; do
        local example="$REPO_ROOT/etc/fk-ssh/${file}.example"
        local dest="$CONFIG_DIR/$file"
        if [[ ! -f "$example" ]]; then
            print_warn "Missing example file: $example"
            continue
        fi
        if [[ -f "$dest" ]]; then
            continue
        fi
        print_step "Initializing $dest from example"
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '[dry-run] cp %s %s\n' "$example" "$dest"
        else
            cp "$example" "$dest"
            chmod 600 "$dest"
        fi
    done
    # Templates
    if [[ -f "$REPO_ROOT/etc/fk-ssh/templates/detect-docs.md.example" ]]; then
        local tmpl_dest="$CONFIG_DIR/templates"
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '[dry-run] mkdir -p %s\n' "$tmpl_dest"
            printf '[dry-run] cp %s %s/\n' "$REPO_ROOT/etc/fk-ssh/templates/detect-docs.md.example" "$tmpl_dest"
        else
            mkdir -p "$tmpl_dest"
            cp "$REPO_ROOT/etc/fk-ssh/templates/detect-docs.md.example" "$tmpl_dest/"
        fi
    fi
}

write_channel() {
    local dest="$CONFIG_DIR/settings.env"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] update %s with FK_CHANNEL=%s\n' "$dest" "$CHANNEL"
        return
    fi
    if grep -q '^FK_CHANNEL=' "$dest" 2>/dev/null; then
        sed -i "s/^FK_CHANNEL=.*/FK_CHANNEL=$CHANNEL/" "$dest"
    else
        printf '\nFK_CHANNEL=%s\n' "$CHANNEL" >> "$dest"
    fi
}

create_symlinks() {
    print_step "Linking executables into $SYMLINK_DIR"
    for script in "$BIN_DIR"/fk-*; do
        local name
        name="$(basename "$script")"
        local dest="$SYMLINK_DIR/$name"
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '[dry-run] ln -sf %s %s\n' "$script" "$dest"
            continue
        fi
        ln -sf "$script" "$dest"
        chmod +x "$script"
    done
}

prompt_ports_if_needed() {
    local ports_file="$CONFIG_DIR/ports.env"
    if [[ $PORTS_WERE_PRESENT -eq 1 && -s "$ports_file" ]]; then
        return
    fi
    cat <<'PORTS'
FlashKidd SSH Manager requires confirmation of service ports.
Provide ports (press Enter for defaults).
PORTS
    declare -A defaults=(
        [SSH_PORT_PRIMARY]=22
        [SSH_PORT_SECONDARY]=80
        [SSH_TLS_PORT]=443
        [SQUID_PORTS]='8080 3128 90'
        [V2RAY_VMESS_TCP]=10086
        [V2RAY_VMESS_WS]=80
        [V2RAY_VMESS_TLS]=443
        [V2RAY_VLESS_TLS]=443
        [OPENVPN_UDP]=1194
        [OPENVPN_TCP]=443
        [WIREGUARD_UDP]=51820
        [WEBSOCKET_SSH_PORTS]='80 443'
    )
    if [[ -f "$ports_file" ]]; then
        # shellcheck disable=SC1090
        source "$ports_file"
    fi
    : > "$ports_file"
    local key value
    for key in "${!defaults[@]}"; do
        local default="${!key:-${defaults[$key]}}"
        if [[ $AUTO_MODE -eq 1 ]]; then
            value="$default"
        else
            read -rp "$key [$default]: " value
            value="${value:-$default}"
        fi
        printf '%s="%s"\n' "$key" "$value" >> "$ports_file"
    done
    chmod 600 "$ports_file"
}

main() {
    parse_args "$@"
    ensure_root
    print_step "Installing FlashKidd SSH Manager"
    create_dirs
    copy_examples
    write_channel
    prompt_ports_if_needed
    install_packages
    create_symlinks
    print_step "Installation complete"
    if [[ $DRY_RUN -eq 1 ]]; then
        print_warn "Dry-run mode enabled; no changes were made."
    fi
    printf 'Run: fk-ssh\n'
}

main "$@"
