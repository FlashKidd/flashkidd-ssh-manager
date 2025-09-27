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
Usage: fk-users-online.sh [--color|--no-color]
Displays a table of currently connected SSH sessions and associated processes.
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

printf '%-16s %-8s %-20s %-20s %-8s\n' 'USER' 'TTY' 'IP' 'LOGIN TIME' 'PID'
who | while read -r user tty date time rest; do
    ip="${rest##*(}"; ip="${ip%)}"
    pid=$(ps -t "$tty" -o pid= | head -n1 | tr -d ' ')
    printf '%-16s %-8s %-20s %-20s %-8s\n' "$user" "$tty" "${ip:-n/a}" "$date $time" "${pid:-n/a}"
done

printf '\nActive sshd sessions:\n'
ss -tnp 2>/dev/null | awk '/sshd/ {print $5"\t"$6}'

fk_box 'Summary' "Online users listed at $(date '+%H:%M:%S')"
fk_log 'Listed online users'
fk_print_post_action
