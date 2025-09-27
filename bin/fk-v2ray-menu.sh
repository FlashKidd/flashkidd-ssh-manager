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
Usage: fk-v2ray-menu.sh [--color|--no-color]
Provides V2Ray VMess/VLESS/WebSocket client management and configuration helpers.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

V2RAY_DIR="/etc/v2ray"
CLIENT_DIR="$V2RAY_DIR/clients"
CONFIG_FILE="$V2RAY_DIR/config.json"
SERVICE_NAME="fk-v2ray.service"
SERVER_IP=$(fk_primary_ipv4)
mkdir -p "$CLIENT_DIR"

ensure_service() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<CFG
{
  "inbounds": [
    {
      "port": ${V2RAY_VMESS_TCP:-10086},
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "settings": { "clients": [] }
    },
    {
      "port": ${V2RAY_VMESS_WS:-80},
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/fkws" } },
      "settings": { "clients": [] }
    },
    {
      "port": ${V2RAY_VLESS_TLS:-443},
      "protocol": "vless",
      "streamSettings": { "network": "tcp", "security": "tls" },
      "settings": { "clients": [], "decryption": "none" }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
CFG
        fk_log 'Initialized V2Ray base config'
    fi
    if ! systemctl list-unit-files | grep -q "^$SERVICE_NAME"; then
        cat > "/etc/systemd/system/$SERVICE_NAME" <<UNIT
[Unit]
Description=FlashKidd V2Ray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/fk-v2ray-run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
        fk_log 'Installed fk-v2ray systemd unit'
    fi
}

save_client() {
    local name="$1" proto="$2" uuid="$3" expiry="$4" extra="$5"
    cat > "$CLIENT_DIR/$name.json" <<JSON
{
  "name": "$name",
  "protocol": "$proto",
  "uuid": "$uuid",
  "expiry": "$expiry",
  "extra": $extra
}
JSON
}

rebuild_config() {
    local tmp="$CONFIG_FILE.tmp"
    jq '(.inbounds[] | select(.protocol=="vmess") | .settings.clients) = [] | (.inbounds[] | select(.protocol=="vless") | .settings.clients) = []' "$CONFIG_FILE" > "$tmp" || cp "$CONFIG_FILE" "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    local client_json
    for client_json in "$CLIENT_DIR"/*.json; do
        [[ -e "$client_json" ]] || continue
        local proto
        proto=$(jq -r '.protocol' "$client_json")
        case "$proto" in
            vmess)
                jq --argfile cli "$client_json" '(.inbounds[] | select(.protocol=="vmess") | .settings.clients) += [$cli|{id:.uuid, alterId:0, email:.name}]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
                ;;
            vless)
                jq --argfile cli "$client_json" '(.inbounds[] | select(.protocol=="vless") | .settings.clients) += [$cli|{id:.uuid, email:.name, flow:""}]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
                ;;
        esac
    done
}

vmess_link() {
    local name="$1"
    local host="${V2RAY_DOMAIN:-$SERVER_IP}"
    local port="${V2RAY_VMESS_TCP:-10086}"
    local uuid
    uuid=$(jq -r '.uuid' "$CLIENT_DIR/$name.json")
    local data
    data=$(jq -n --arg v "auto" --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$uuid" '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"tcp",type:"none",host:"",path:""}')
    printf 'vmess://%s\n' "$(echo "$data" | base64 -w0)"
}

vless_link() {
    local name="$1"
    local host="${V2RAY_DOMAIN:-$SERVER_IP}"
    local port="${V2RAY_VLESS_TLS:-443}"
    local uuid
    uuid=$(jq -r '.uuid' "$CLIENT_DIR/$name.json")
    printf 'vless://%s@%s:%s?encryption=none&security=tls#%s\n' "$uuid" "$host" "$port" "$name"
}

create_vmess() {
    ensure_service
    read -rp 'Client name: ' name
    [[ -n "$name" ]] || { printf 'Name required.\n'; return; }
    if [[ -f "$CLIENT_DIR/$name.json" ]]; then
        printf 'Client exists.\n'
        return
    fi
    read -rp 'Validity days: ' days
    [[ "$days" =~ ^[0-9]+$ ]] || { printf 'Invalid days.\n'; return; }
    local uuid
    uuid=$(uuidgen)
    local expiry
    expiry=$(date -d "$days days" +%Y-%m-%d)
    save_client "$name" vmess "$uuid" "$expiry" '{}'
    rebuild_config
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    local link
    link=$(vmess_link "$name")
    fk_box 'VMess client created' "Name: $name" "UUID: $uuid" "Expires: $expiry" "Link: $link"
    fk_print_post_action
}

create_vless() {
    ensure_service
    read -rp 'Client name: ' name
    [[ -n "$name" ]] || { printf 'Name required.\n'; return; }
    if [[ -f "$CLIENT_DIR/$name.json" ]]; then
        printf 'Client exists.\n'
        return
    fi
    read -rp 'Validity days: ' days
    [[ "$days" =~ ^[0-9]+$ ]] || { printf 'Invalid days.\n'; return; }
    local uuid
    uuid=$(uuidgen)
    local expiry
    expiry=$(date -d "$days days" +%Y-%m-%d)
    save_client "$name" vless "$uuid" "$expiry" '{}'
    rebuild_config
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    local link
    link=$(vless_link "$name")
    fk_box 'VLESS client created' "Name: $name" "UUID: $uuid" "Expires: $expiry" "Link: $link"
    fk_print_post_action
}

show_clients() {
    printf '%-16s %-8s %-12s %-36s\n' Name Proto Expiry UUID
    local file
    for file in "$CLIENT_DIR"/*.json; do
        [[ -e "$file" ]] || continue
        jq -r '[.name,.protocol,.expiry,.uuid]|@tsv' "$file" | awk '{printf "%-16s %-8s %-12s %-36s\n", $1,$2,$3,$4}'
    done
    local name
    read -rp 'Show link for client (blank to skip): ' name
    if [[ -n "$name" && -f "$CLIENT_DIR/$name.json" ]]; then
        case "$(jq -r '.protocol' "$CLIENT_DIR/$name.json")" in
            vmess)
                vmess_link "$name"
                ;;
            vless)
                vless_link "$name"
                ;;
        esac
    fi
    fk_box 'Summary' "Client list refreshed $(date '+%H:%M:%S')"
    fk_print_post_action
}

renew_client() {
    read -rp 'Client name: ' name
    [[ -f "$CLIENT_DIR/$name.json" ]] || { printf 'Client not found.\n'; return; }
    read -rp 'Additional days: ' days
    [[ "$days" =~ ^[0-9]+$ ]] || { printf 'Invalid days.\n'; return; }
    local current
    current=$(jq -r '.expiry' "$CLIENT_DIR/$name.json")
    [[ -n "$current" ]] || current=$(date +%Y-%m-%d)
    local new
    new=$(date -d "$current + $days days" +%Y-%m-%d)
    jq --arg exp "$new" '.expiry=$exp' "$CLIENT_DIR/$name.json" > "$CLIENT_DIR/$name.json.tmp" && mv "$CLIENT_DIR/$name.json.tmp" "$CLIENT_DIR/$name.json"
    fk_box 'Client renewed' "Name: $name" "Previous: $current" "New: $new"
    fk_print_post_action
}

delete_client() {
    read -rp 'Client name: ' name
    [[ -f "$CLIENT_DIR/$name.json" ]] || { printf 'Client not found.\n'; return; }
    if fk_prompt_confirm "Delete $name? [y/N]"; then
        rm -f "$CLIENT_DIR/$name.json"
        rebuild_config
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
        fk_box 'Client removed' "Name: $name"
        fk_print_post_action
    fi
}

while true; do
    fk_banner
    cat <<'MENU'
V2Ray Menu
1) Create VMess client
2) Create VLESS client
3) Show configs / links
4) Renew client
5) Delete client
0) Back
MENU
    read -rp 'Select: ' opt
    case "$opt" in
        1) create_vmess ;;
        2) create_vless ;;
        3) show_clients ;;
        4) renew_client ;;
        5) delete_client ;;
        0) break ;;
        *) printf 'Invalid.\n' ;;
    esac
done
