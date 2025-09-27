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
Usage: fk-user-renew.sh [--color|--no-color]
Extends an existing SSH user's expiry by the requested number of days.
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
if ! id "$FK_USERNAME" >/dev/null 2>&1; then
    printf 'User not found.\n'
    exit 1
fi
read -rp 'Additional days: ' FK_DAYS
if ! [[ "$FK_DAYS" =~ ^[0-9]+$ ]]; then
    printf 'Days must be numeric.\n'
    exit 1
fi

CURRENT=$(chage -l "$FK_USERNAME" | awk -F': ' '/Account expires/{print $2}')
if [[ "$CURRENT" == "never" || -z "$CURRENT" ]]; then
    CURRENT_DATE=$(date +%Y-%m-%d)
else
    CURRENT_DATE=$(date -d "$CURRENT" +%Y-%m-%d)
fi

NEW_DATE=$(date -d "$CURRENT_DATE + $FK_DAYS days" +%Y-%m-%d)
chage -E "$NEW_DATE" "$FK_USERNAME"

fk_box '----------- Account Renewal -----------' \
    " Username     : $FK_USERNAME" \
    " Previous Exp.: $CURRENT_DATE" \
    " New Expiry   : $NEW_DATE" \
    " Extended by  : ${FK_DAYS} days"

fk_log "Renewed user $FK_USERNAME to $NEW_DATE"
fk_print_post_action
