#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/fk-settings.sh"

usage() {
    cat <<'USAGE'
Usage: fk-user-add.sh [--color|--no-color]
Prompts for username, password, and active days, then provisions a locked-shell SSH user.
USAGE
}

fk_common_init "$@"
set -- "${FK_ARGS[@]}"

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

read -rp 'Username: ' FK_USERNAME
if [[ -z "$FK_USERNAME" ]]; then
    printf 'Username cannot be empty.\n'
    exit 1
fi
if id "$FK_USERNAME" >/dev/null 2>&1; then
    printf 'User already exists.\n'
    exit 1
fi

read -rsp 'Password: ' FK_PASSWORD
printf '\n'
if [[ -z "$FK_PASSWORD" ]]; then
    printf 'Password cannot be empty.\n'
    exit 1
fi
read -rp 'Active days: ' FK_DAYS
if ! [[ "$FK_DAYS" =~ ^[0-9]+$ ]]; then
    printf 'Active days must be numeric.\n'
    exit 1
fi

useradd -M -s /bin/false "$FK_USERNAME"
echo -e "$FK_PASSWORD\n$FK_PASSWORD" | passwd "$FK_USERNAME" >/dev/null
EXPDATE=$(date -d "$FK_DAYS days" +%Y-%m-%d)
chage -E "$EXPDATE" "$FK_USERNAME"

SERVER_IP=$(fk_primary_ipv4)
SSH_PORTS=${SSH_PORT_PRIMARY:-22}
if [[ -n "${SSH_PORT_SECONDARY:-}" ]]; then
    SSH_PORTS="$SSH_PORTS ${SSH_PORT_SECONDARY}"
fi

cat <<BOX
+----------------- Account Created ------------------+
 Server IP   : $SERVER_IP
 Username    : $FK_USERNAME
 Password    : $FK_PASSWORD
 Expires     : $EXPDATE  (${FK_DAYS} days)
 SSH Port(s) : $SSH_PORTS
-----------------------------------------------------
 Copy/paste ready SSH:
 ssh $FK_USERNAME@$SERVER_IP -p ${SSH_PORT_PRIMARY:-22}
+----------------------------------------------------+
BOX

fk_log "Created user $FK_USERNAME expiring $EXPDATE"
fk_print_post_action
