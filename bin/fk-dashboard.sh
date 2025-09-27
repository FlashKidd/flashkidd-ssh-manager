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
Usage: fk-dashboard.sh [--color|--no-color]
Shows system overview including CPU, RAM, disk, uptime, users, and top processes.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root

cpu=$(awk -F' ' '/^cpu / {usage=($2+$4)*100/($2+$4+$5); printf "%.1f", usage }' /proc/stat)
mem_used=$(free -m | awk '/Mem:/ {print $3}')
mem_total=$(free -m | awk '/Mem:/ {print $2}')
disk=$(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')
uptime=$(uptime -p)
users=$(who | wc -l)

printf '%-10s %-15s %-20s %-20s %-10s\n' CPU% "RAM (MB)" "Disk" Uptime "Users"
printf '%-10s %-15s %-20s %-20s %-10s\n' "$cpu" "$mem_used/$mem_total" "$disk" "$uptime" "$users"

printf '\nTop processes:\n'
ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n6

printf '\nNetwork snapshot:\n'
ip -brief address

fk_box 'Dashboard' 'Snapshot generated.'
fk_print_post_action
