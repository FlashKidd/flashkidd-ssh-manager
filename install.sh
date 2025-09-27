#!/usr/bin/env bash
set -euo pipefail

# FlashKidd SSH Manager installer
# This script is idempotent and safe to re-run.

REPO_ROOT=""
TEMP_ARCHIVE_DIR=""
BIN_DIR=""
CONFIG_DIR="/etc/fk-ssh"
SYMLINK_DIR="/usr/local/bin"
LOG_DIR="$CONFIG_DIR/logs"
BACKUP_DIR="$CONFIG_DIR/backups"
PORTS_WERE_PRESENT=0

DRY_RUN=0
AUTO_MODE=0
CHANNEL="stable"
ARCHIVE_REF="GIT_COMMIT_PLACEHOLDER"
ARCHIVE_SHA256=""

# Allow overrides for testing or air-gapped deployments
ARCHIVE_REF="${FK_INSTALL_REF:-$ARCHIVE_REF}"
ARCHIVE_SHA256="${FK_INSTALL_SHA256:-$ARCHIVE_SHA256}"

# When the script is executed directly from the repository the placeholder above
# is replaced via release automation. If it is still present we fall back to the
# main branch without a checksum (callers can set FK_INSTALL_REF/FK_INSTALL_SHA256
# for stricter verification).
if [[ "$ARCHIVE_REF" == "GIT_COMMIT_PLACEHOLDER" ]]; then
    ARCHIVE_REF="main"
    ARCHIVE_SHA256=""
fi

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

cleanup_temp_dir() {
    if [[ -n "$TEMP_ARCHIVE_DIR" && -d "$TEMP_ARCHIVE_DIR" ]]; then
        rm -rf "$TEMP_ARCHIVE_DIR"
    fi
}

download_repo_archive() {
    TEMP_ARCHIVE_DIR="$(mktemp -d)"
    trap cleanup_temp_dir EXIT
    local archive="$TEMP_ARCHIVE_DIR/repo.tar.gz"
    local url="https://github.com/FlashKidd/flashkidd-ssh-manager/archive/${ARCHIVE_REF}.tar.gz"
    print_step "Fetching repository assets (${ARCHIVE_REF})"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] curl -fsSL %s -o %s\n' "$url" "$archive"
        if [[ -n "$ARCHIVE_SHA256" ]]; then
            printf '[dry-run] echo "%s  %s" | sha256sum -c -\n' "$ARCHIVE_SHA256" "$archive"
        fi
        printf '[dry-run] tar -xzf %s -C %s\n' "$archive" "$TEMP_ARCHIVE_DIR"
        REPO_ROOT="$TEMP_ARCHIVE_DIR/flashkidd-ssh-manager-${ARCHIVE_REF}"
        return
    fi
    if ! curl -fsSL "$url" -o "$archive"; then
        printf 'Failed to download repository archive from %s\n' "$url" >&2
        exit 1
    fi
    if [[ -n "$ARCHIVE_SHA256" ]]; then
        if ! echo "$ARCHIVE_SHA256  $archive" | sha256sum -c - >/dev/null 2>&1; then
            printf 'Checksum verification failed for archive (%s).\n' "$ARCHIVE_SHA256" >&2
            exit 1
        fi
    fi
    if ! tar -xzf "$archive" -C "$TEMP_ARCHIVE_DIR"; then
        printf 'Failed to unpack repository archive.\n' >&2
        exit 1
    fi
    local extracted
    extracted="$(find "$TEMP_ARCHIVE_DIR" -maxdepth 1 -mindepth 1 -type d -name 'flashkidd-ssh-manager*' | head -n1)"
    if [[ -z "$extracted" ]]; then
        printf 'Unable to locate extracted repository directory.\n' >&2
        exit 1
    fi
    REPO_ROOT="$extracted"
}

resolve_repo_root() {
    local source_path="${BASH_SOURCE[0]:-}"
    local candidate=""
    if [[ -n "$source_path" && -f "$source_path" ]]; then
        candidate="$(cd "$(dirname "$source_path")" && pwd -P)"
    else
        candidate="$(pwd -P)"
    fi
    if [[ -d "$candidate/bin" && -f "$candidate/install.sh" ]]; then
        REPO_ROOT="$candidate"
        return
    fi
    download_repo_archive
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
    if [[ ! -d "$BIN_DIR" ]]; then
        print_warn "Repository bin directory not found ($BIN_DIR)."
        return
    fi
    local script
    for script in "$BIN_DIR"/fk-*; do
        [[ -f "$script" ]] || continue
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
    if [[ $DRY_RUN -eq 1 ]]; then
        local key default
        for key in "${!defaults[@]}"; do
            default="${!key:-${defaults[$key]}}"
            printf '[dry-run] %s would be set to %s\n' "$key" "$default"
        done
        return
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
    resolve_repo_root
    BIN_DIR="$REPO_ROOT/bin"
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
