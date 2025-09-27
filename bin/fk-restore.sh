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
Usage: fk-restore.sh [--color|--no-color]
Restores configuration from a FlashKidd backup tarball.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

read -rp 'Backup path: ' BACKUP
fk_require_file "$BACKUP"

if ! fk_prompt_confirm 'This will overwrite existing configs. Continue? [y/N]'; then
    printf 'Restore aborted.\n'
    exit 0
fi

tmpdir=$(mktemp -d)
tar -xzf "$BACKUP" -C "$tmpdir"

copy_tree() {
    local src="$1" dest="$2"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$src" "$dest"
    else
        mkdir -p "$dest"
        cp -a "$src"/. "$dest"/
    fi
}

copy_tree "$tmpdir/etc/fk-ssh" "$FK_CONFIG_DIR"
[[ -d "$tmpdir/etc/v2ray" ]] && copy_tree "$tmpdir/etc/v2ray" /etc/v2ray
[[ -d "$tmpdir/etc/openvpn" ]] && copy_tree "$tmpdir/etc/openvpn" /etc/openvpn
[[ -d "$tmpdir/etc/wireguard" ]] && copy_tree "$tmpdir/etc/wireguard" /etc/wireguard
[[ -f "$tmpdir/etc/issue.net" ]] && cp "$tmpdir/etc/issue.net" /etc/issue.net
[[ -f "$tmpdir/etc/motd" ]] && cp "$tmpdir/etc/motd" /etc/motd

rm -rf "$tmpdir"

systemctl daemon-reload
systemctl restart ssh >/dev/null 2>&1 || true
systemctl restart fk-v2ray.service >/dev/null 2>&1 || true
systemctl restart openvpn >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0 >/dev/null 2>&1 || true

fk_box 'Restore complete' "Source: $BACKUP"
fk_print_post_action
