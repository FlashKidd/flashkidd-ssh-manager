#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/fk-settings.sh"

fk_common_init "$@"
set -- "${FK_ARGS[@]}"

usage() {
    cat <<'USAGE'
Usage: fk-banner.sh [--color|--no-color]
Manage SSH login banners (/etc/issue.net) and MOTD.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

DEFAULT_BANNER=$'+---------------------------------------+\n|  FlashKidd SSH Manager               |\n|  Welcome to your secured platform    |\n+---------------------------------------+' 

apply_default() {
    printf '%s\n' "$DEFAULT_BANNER" > /etc/issue.net
    printf '%s\n' "$DEFAULT_BANNER" > /etc/motd
    ensure_sshd_banner
    fk_box 'Banner updated' 'Default banner applied.'
    systemctl reload ssh >/dev/null 2>&1 || true
    fk_print_post_action
}

ensure_sshd_banner() {
    if ! grep -q '^Banner ' /etc/ssh/sshd_config 2>/dev/null; then
        printf '\nBanner /etc/issue.net\n' >> /etc/ssh/sshd_config
    else
        sed -i 's#^Banner .*#Banner /etc/issue.net#' /etc/ssh/sshd_config
    fi
}

import_banner() {
    read -rp 'File path: ' path
    fk_require_file "$path"
    cp "$path" /etc/issue.net
    cp "$path" /etc/motd
    ensure_sshd_banner
    systemctl reload ssh >/dev/null 2>&1 || true
    fk_box 'Banner updated' "Imported from $path"
    fk_print_post_action
}

interactive_edit() {
    printf 'Enter banner text. Finish with a single line containing EOF.\n'
    tmp=$(mktemp)
    while IFS= read -r line; do
        [[ "$line" == "EOF" ]] && break
        printf '%s\n' "$line" >> "$tmp"
    done
    cp "$tmp" /etc/issue.net
    cp "$tmp" /etc/motd
    rm -f "$tmp"
    ensure_sshd_banner
    systemctl reload ssh >/dev/null 2>&1 || true
    fk_box 'Banner updated' 'Custom banner applied.'
    fk_print_post_action
}

show_current() {
    printf '----- /etc/issue.net -----\n'
    cat /etc/issue.net 2>/dev/null || printf 'No banner set.\n'
    printf '\n----- /etc/motd -----\n'
    cat /etc/motd 2>/dev/null || printf 'No MOTD set.\n'
    fk_box 'Summary' 'Banner and MOTD shown above.'
    fk_print_post_action
}

while true; do
    fk_banner
    cat <<'MENU'
Banner Manager
1) Show current banner
2) Apply default FlashKidd banner
3) Import banner from file
4) Enter banner text manually
0) Back
MENU
    read -rp 'Select: ' opt
    case "$opt" in
        1) show_current ;;
        2) apply_default ;;
        3) import_banner ;;
        4) interactive_edit ;;
        0) break ;;
        *) printf 'Invalid.\n' ;;
    esac
done
