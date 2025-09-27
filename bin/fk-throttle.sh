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

THROTTLE_FILE="$FK_CONFIG_DIR/throttle.rules"

usage() {
    cat <<'USAGE'
Usage: fk-throttle.sh [--color|--no-color] [--remove <user>] [--apply]
Apply or manage per-user bandwidth throttling using tc and iptables marks.
USAGE
}

fk_common_init "$@"
ARGS=("${FK_ARGS[@]}")
set -- "${FK_ARGS[@]}"

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

REMOVE_USER=""
APPLY_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)
            REMOVE_USER="$2"
            shift 2
            ;;
        --apply)
            APPLY_ONLY=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

fk_require_root
fk_load_env

ensure_unit() {
    local unit="/etc/systemd/system/fk-throttle.service"
    if [[ ! -f "$unit" ]]; then
        cat > "$unit" <<UNIT
[Unit]
Description=FlashKidd per-user throttling
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fk-throttle.sh --apply

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable fk-throttle.service >/dev/null 2>&1 || true
    fi
}

iface_from_route() {
    ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

apply_throttles() {
    local iface
    iface=$(iface_from_route)
    [[ -n "$iface" ]] || { printf 'Unable to determine primary interface.\n'; return 1; }
    tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
    tc qdisc add dev "$iface" root handle 1: htb default 0
    tc class add dev "$iface" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit
    iptables -t mangle -D OUTPUT -j FK-THROTTLE >/dev/null 2>&1 || true
    iptables -t mangle -F FK-THROTTLE >/dev/null 2>&1 || true
    iptables -t mangle -X FK-THROTTLE >/dev/null 2>&1 || true
    iptables -t mangle -N FK-THROTTLE >/dev/null 2>&1
    iptables -t mangle -A OUTPUT -j FK-THROTTLE >/dev/null 2>&1
    local idx=10
    while read -r username up down; do
        [[ -n "$username" ]] || continue
        local uid
        uid=$(id -u "$username" 2>/dev/null || true)
        [[ -n "$uid" ]] || continue
        local classid="1:${idx}"
        local ceil_val
        if (( up > down )); then
            ceil_val=$up
        else
            ceil_val=$down
        fi
        tc class add dev "$iface" parent 1:1 classid "$classid" htb rate "${down}kbit" ceil "${ceil_val}kbit"
        tc qdisc add dev "$iface" parent "$classid" handle "$idx": sfq
        tc filter add dev "$iface" protocol ip parent 1: prio 1 handle "$idx" fw flowid "$classid"
        iptables -t mangle -A FK-THROTTLE -m owner --uid-owner "$uid" -j MARK --set-mark "$idx"
        idx=$((idx + 1))
    done < "$THROTTLE_FILE" 2>/dev/null
}

if [[ $APPLY_ONLY -eq 1 ]]; then
    apply_throttles
    exit 0
fi

ensure_unit
mkdir -p "$FK_CONFIG_DIR"
touch "$THROTTLE_FILE"

if [[ -n "$REMOVE_USER" ]]; then
    grep -v "^$REMOVE_USER " "$THROTTLE_FILE" > "$THROTTLE_FILE.tmp" || true
    mv "$THROTTLE_FILE.tmp" "$THROTTLE_FILE"
    apply_throttles
    fk_box 'Throttle removed' "User: $REMOVE_USER"
    fk_print_post_action
    exit 0
fi

read -rp 'Username: ' user
id "$user" >/dev/null 2>&1 || { printf 'User not found.\n'; exit 1; }
read -rp 'Up kb/s: ' up
read -rp 'Down kb/s: ' down
if ! [[ "$up" =~ ^[0-9]+$ && "$down" =~ ^[0-9]+$ ]]; then
    printf 'Speeds must be numeric.\n'
    exit 1
fi
if (( up <= 0 || down <= 0 )); then
    printf 'Speeds must be greater than zero.\n'
    exit 1
fi

# store as user up down
grep -v "^$user " "$THROTTLE_FILE" > "$THROTTLE_FILE.tmp" || true
mv "$THROTTLE_FILE.tmp" "$THROTTLE_FILE"
printf '%s %s %s\n' "$user" "$up" "$down" >> "$THROTTLE_FILE"
apply_throttles

fk_box 'Throttle applied' "User: $user" "Up: ${up}kb/s" "Down: ${down}kb/s"
fk_print_post_action
