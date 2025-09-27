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
Usage: fk-port-manager.sh [--color|--no-color]
Safely updates service ports defined in /etc/fk-ssh/ports.env with rollback support.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

services=(
    "SSH_PORT_PRIMARY:Primary SSH"
    "SSH_PORT_SECONDARY:Secondary SSH"
    "SSH_TLS_PORT:SSH over TLS"
    "V2RAY_VMESS_TCP:V2Ray VMess TCP"
    "V2RAY_VMESS_WS:V2Ray VMess WS"
    "V2RAY_VMESS_TLS:V2Ray VMess TLS"
    "V2RAY_VLESS_TLS:V2Ray VLESS TLS"
    "OPENVPN_UDP:OpenVPN UDP"
    "OPENVPN_TCP:OpenVPN TCP"
    "WIREGUARD_UDP:WireGuard UDP"
)

printf 'Current ports (from %s):\n' "$FK_PORTS_FILE"
for entry in "${services[@]}"; do
    IFS=':' read -r key label <<<"$entry"
    printf ' %-20s : %s\n' "$label" "${!key:-unset}"
done

read -rp 'Service key to modify (e.g. SSH_PORT_PRIMARY): ' key
if [[ -z "$key" ]]; then
    printf 'No selection.\n'
    exit 1
fi

valid=0
for entry in "${services[@]}"; do
    IFS=':' read -r var _ <<<"$entry"
    if [[ "$key" == "$var" ]]; then
        valid=1
        break
    fi
done
if (( valid == 0 )); then
    printf 'Unknown service key: %s\n' "$key"
    exit 1
fi

read -rp 'New port (or space separated ports): ' new_ports
if [[ -z "$new_ports" ]]; then
    printf 'No port supplied.\n'
    exit 1
fi

for port in $new_ports; do
    if ! fk_validate_port "$port"; then
        printf 'Invalid port: %s\n' "$port"
        exit 1
    fi
    if fk_port_in_use "$port"; then
        printf 'Port %s already in use.\n' "$port"
        exit 1
    fi
done

backup="$FK_PORTS_FILE.$(date +%s).bak"
if [[ -f "$FK_PORTS_FILE" ]]; then
    cp "$FK_PORTS_FILE" "$backup"
else
    touch "$FK_PORTS_FILE"
    cp "$FK_PORTS_FILE" "$backup"
fi
trap 'cp "$backup" "$FK_PORTS_FILE"; printf "Rollback applied.\n"' ERR

fk_save_env_value "$FK_PORTS_FILE" "$key" "\"$new_ports\""

# reopen firewall
fk_load_env
entries=""
for p in ${SSH_PORT_PRIMARY:-22} ${SSH_PORT_SECONDARY:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/tcp"
done
for p in ${SSH_TLS_PORT:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/tcp"
done
for p in ${V2RAY_VMESS_TCP:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/tcp"
done
for p in ${V2RAY_VMESS_WS:-} ${V2RAY_VMESS_TLS:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/tcp"
done
for p in ${V2RAY_VLESS_TLS:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/tcp"
done
for p in ${OPENVPN_UDP:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/udp"
done
for p in ${OPENVPN_TCP:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/tcp"
done
for p in ${WIREGUARD_UDP:-}; do
    [[ -n "$p" ]] && entries+=" ${p}/udp"
done
entries=$(echo "$entries" | sed 's/^ *//')
fk_firewall_reconcile_ports "$entries" "FlashKidd core"

trap - ERR
rm -f "$backup"

fk_box 'Port updated' "Key: $key" "New port(s): $new_ports" "Firewall refreshed"
fk_print_post_action
