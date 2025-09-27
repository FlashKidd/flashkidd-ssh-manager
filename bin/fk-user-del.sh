#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/fk-settings.sh"

usage() {
    cat <<'USAGE'
Usage: fk-user-del.sh [--color|--no-color]
Deletes an SSH user (home directory removed) after confirmation.
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

if ! fk_prompt_confirm "Confirm deletion of $FK_USERNAME? [y/N]"; then
    printf 'Aborted.\n'
    exit 0
fi

userdel -r "$FK_USERNAME" >/dev/null 2>&1 || userdel "$FK_USERNAME"

# Remove throttle rule if present
if [[ -f "$FK_CONFIG_DIR/throttle.rules" ]]; then
    grep -v "^$FK_USERNAME " "$FK_CONFIG_DIR/throttle.rules" > "$FK_CONFIG_DIR/throttle.rules.tmp" || true
    mv "$FK_CONFIG_DIR/throttle.rules.tmp" "$FK_CONFIG_DIR/throttle.rules"
fi

fk_box '----------- Account Deleted -----------' \
    " Username : $FK_USERNAME" \
    " Status   : Removed"

fk_log "Deleted user $FK_USERNAME"
fk_print_post_action
