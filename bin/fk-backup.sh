#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${BASH_SOURCE+x} ]]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
else
    SCRIPT_PATH="$0"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/fk-settings.sh"

fk_common_init "$@"
set -- "${FK_ARGS[@]}"

usage() {
    cat <<'USAGE'
Usage: fk-backup.sh [--color|--no-color]
Creates a tar.gz archive of FlashKidd SSH Manager configuration and service assets.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

mkdir -p "$FK_BACKUP_DIR"
BACKUP_PATH="$FK_BACKUP_DIR/fk-ssh-$(date '+%Y%m%d-%H%M%S').tar.gz"

FILES_TO_BACKUP=(
    "$FK_CONFIG_DIR/ports.env"
    "$FK_CONFIG_DIR/settings.env"
    "$FK_CONFIG_DIR/throttle.rules"
    "$FK_CONFIG_DIR/templates"
    "/etc/v2ray"
    "/etc/openvpn"
    "/etc/wireguard"
    "/etc/issue.net"
    "/etc/motd"
)

TMP_LIST="$(mktemp)"
for item in "${FILES_TO_BACKUP[@]}"; do
    [[ -e "$item" ]] && printf '%s\n' "$item" >> "$TMP_LIST"
done

tar -czf "$BACKUP_PATH" -T "$TMP_LIST"
rm -f "$TMP_LIST"

fk_box 'Backup complete' "Archive: $BACKUP_PATH"
fk_print_post_action
