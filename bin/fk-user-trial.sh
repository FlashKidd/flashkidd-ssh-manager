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

usage() {
    cat <<'USAGE'
Usage: fk-user-trial.sh [--color|--no-color]
Creates a time-limited trial SSH user with auto-generated credentials.
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

read -rp 'Trial days (1/3): ' FK_DAYS
FK_DAYS=${FK_DAYS:-1}
if [[ "$FK_DAYS" != "1" && "$FK_DAYS" != "3" ]]; then
    printf 'Trial days must be 1 or 3.\n'
    exit 1
fi

rand_string() {
    tr -dc 'a-z0-9' </dev/urandom | head -c "$1"
}

FK_USERNAME="trial$(rand_string 4)"
while id "$FK_USERNAME" >/dev/null 2>&1; do
    FK_USERNAME="trial$(rand_string 4)"
done
FK_PASSWORD="$(rand_string 10)"

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
+----------------- Trial Account Created ------------------+
 Server IP   : $SERVER_IP
 Username    : $FK_USERNAME (Trial)
 Password    : $FK_PASSWORD
 Expires     : $EXPDATE  (${FK_DAYS} days)
 SSH Port(s) : $SSH_PORTS
-----------------------------------------------------
 Copy/paste ready SSH:
 ssh $FK_USERNAME@$SERVER_IP -p ${SSH_PORT_PRIMARY:-22}
+----------------------------------------------------+
BOX

fk_log "Created trial user $FK_USERNAME expiring $EXPDATE"
fk_print_post_action
