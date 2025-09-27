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
Usage: fk-logs.sh [--color|--no-color]
Shows authentication logs and active service sessions.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root

printf '--- auth.log (last 50) ---\n'
if [[ -f /var/log/auth.log ]]; then
    tail -n 50 /var/log/auth.log
else
    journalctl -u ssh -n 50
fi

printf '\n--- Active sessions ---\n'
ss -tnp | grep -E 'sshd|openvpn|wg0|v2ray' || printf 'No active sessions.\n'

fk_box 'Log snapshot' 'Displayed recent entries and sessions.'
fk_print_post_action
