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
Usage: fk-payloads.sh [--color|--no-color]
Generates ready-to-copy payload templates for SSH, TLS, and V2Ray clients.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env
SERVER_IP=$(fk_primary_ipv4)

read -rp 'SSH username: ' username
read -rp 'SSH password: ' password

vmess_json=$(jq -n --arg v "auto" --arg ps "$username" --arg add "$SERVER_IP" --arg port "${V2RAY_VMESS_TCP:-10086}" --arg id "$(uuidgen)" '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"ws",type:"none",host:"",path:"/fkws",tls:"tls"}')
vmess_link="vmess://$(echo "$vmess_json" | base64 -w0)"
vless_link="vless://$(uuidgen)@$SERVER_IP:${V2RAY_VLESS_TLS:-443}?encryption=none&security=tls#${username}"

fk_box 'Payloads' \
    "SSH Direct : ssh $username@$SERVER_IP -p ${SSH_PORT_PRIMARY:-22}" \
    "SSH TLS    : CONNECT $SERVER_IP:${SSH_TLS_PORT:-443}@${SSH_TLS_PORT:-443}" \
    "HTTP-Injector : GET https://$SERVER_IP/ HTTP/1.1\r\nHost: $SERVER_IP\r\n\r\n" \
    "VMess      : $vmess_link" \
    "VLESS      : $vless_link"

fk_print_post_action
