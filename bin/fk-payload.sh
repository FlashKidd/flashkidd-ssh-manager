#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULTS_FILE="$ROOT_DIR/conf/defaults.json"
source "$ROOT_DIR/lib/server_info.sh"

usage() {
  cat <<USAGE
Usage: $0 --proto <vmess|vless|ssh|openvpn|shadowsocks|http-proxy|socks5> [options]
Options:
  --user <username>
  --port <port>
  --sni <sni>
  --out <dir>
  --json
  --password <secret>
  --proxy-type <type>
USAGE
}

load_default_port() {
  local key=$1
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data["default_ports"].get(sys.argv[2], ""))' "$DEFAULTS_FILE" "$key"
}

proto=""
username="flashkidd"
port=""
sni=""
out_dir="/opt/flashkidd/payloads"
json_flag=0
password=""
proxy_type="none"

while [[ $# -gt 0 ]]; do
  case $1 in
    --proto) proto=$2; shift 2;;
    --user) username=$2; shift 2;;
    --port) port=$2; shift 2;;
    --sni) sni=$2; shift 2;;
    --out) out_dir=$2; shift 2;;
    --json) json_flag=1; shift;;
    --password) password=$2; shift 2;;
    --proxy-type) proxy_type=$2; shift 2;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z $proto ]]; then
  echo "--proto required" >&2
  exit 1
fi

server_ip=$(get_server_ip)
if [[ -z $server_ip ]]; then
  echo "Unable to determine server IP" >&2
  exit 1
fi

mkdir -p "$out_dir"

emit_json() {
  local content=$1
  if [[ $json_flag -eq 1 ]]; then
    printf '%s\n' "$content"
  fi
}

vmess_payload() {
  local vmess_port=${port:-$(load_default_port v2ray)}
  local uuid
  uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  local payload_path="$out_dir/${username}-vmess-${server_ip}-${vmess_port}.json"
  local tmp
  tmp=$(mktemp "$out_dir/.tmp.vmess.XXXXXX")
  VMESS_UUID="$uuid" VMESS_PORT="$vmess_port" VMESS_HOST="$server_ip" VMESS_SNI="$sni" python3 - <<'PY' >"$tmp"
import json, os
print(json.dumps({
    "v": "2",
    "ps": os.environ["VMESS_HOST"],
    "add": os.environ["VMESS_HOST"],
    "port": os.environ["VMESS_PORT"],
    "id": os.environ["VMESS_UUID"],
    "aid": "0",
    "net": "tcp",
    "type": "none",
    "host": os.environ.get("VMESS_SNI", ""),
    "path": "",
    "tls": "tls"
}, indent=2))
PY
  chmod 600 "$tmp"
  mv "$tmp" "$payload_path"
  local vmess_link
  vmess_link=$(VMESS_JSON_PATH="$payload_path" python3 - <<'PY'
import base64, os
with open(os.environ["VMESS_JSON_PATH"], 'rb') as fh:
    data = fh.read()
print('vmess://' + base64.urlsafe_b64encode(data).decode().rstrip('='))
PY
)
  printf '%s\n' "$vmess_link"
  if [[ $json_flag -eq 1 ]]; then
    VMESS_LINK="$vmess_link" VMESS_PATH="$payload_path" VMESS_PORT="$vmess_port" VMESS_SNI="$sni" VMESS_HOST="$server_ip" python3 - <<'PY'
import json, os
print(json.dumps({
    "remote_host": os.environ["VMESS_HOST"],
    "remote_port": int(os.environ["VMESS_PORT"]),
    "sni": os.environ.get("VMESS_SNI", ""),
    "vmess_link": os.environ["VMESS_LINK"],
    "payload_path": os.environ["VMESS_PATH"]
}))
PY
  fi
}

vless_payload() {
  local vless_port=${port:-$(load_default_port v2ray)}
  local uuid
  uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  local line="vless://${uuid}@${server_ip}:${vless_port}?encryption=none&type=tcp&security=tls"
  printf '%s\n' "$line"
  if [[ $json_flag -eq 1 ]]; then
    VLESS_URI="$line" VLESS_PORT="$vless_port" python3 - <<'PY'
import json, os
print(json.dumps({
    "remote_host": os.environ.get("SERVER_IP", ""),
    "remote_port": int(os.environ["VLESS_PORT"]),
    "sni": os.environ.get("SNI", ""),
    "vless_uri": os.environ["VLESS_URI"]
}))
PY
  fi
}

fields_payload() {
  local remote_port=$1
  local payload=$2
  printf 'remote_host=%s\n' "$server_ip"
  printf 'remote_port=%s\n' "$remote_port"
  printf 'proxy_type=%s\n' "$proxy_type"
  printf 'payload=%s\n' "$payload"
  printf 'username=%s\n' "$username"
  printf 'password=%s\n' "${password:-<set-password>}"
  if [[ $json_flag -eq 1 ]]; then
    REMOTE_PORT="$remote_port" PAYLOAD="$payload" python3 - <<'PY'
import json, os
print(json.dumps({
    "remote_host": os.environ.get("SERVER_IP", ""),
    "remote_port": int(os.environ["REMOTE_PORT"]),
    "proxy_type": os.environ.get("PROXY_TYPE", ""),
    "payload": os.environ.get("PAYLOAD", ""),
    "username": os.environ.get("USERNAME", ""),
    "password": os.environ.get("PASSWORD", "")
}))
PY
  fi
}

export SERVER_IP="$server_ip"
export PROXY_TYPE="$proxy_type"
export USERNAME="$username"
export PASSWORD="${password:-<set-password>}"
export SNI="$sni"

case $proto in
  vmess)
    vmess_payload
    ;;
  vless)
    vless_payload
    ;;
  ssh)
    ssh_port=${port:-$(load_default_port ssh)}
    payload="CONNECT ${server_ip}:${ssh_port} HTTP/1.1\\r\\nHost: example.com\\r\\n\\r\\n"
    fields_payload "$ssh_port" "$payload"
    ;;
  openvpn)
    ovpn_port=${port:-$(load_default_port openvpn)}
    payload="remote ${server_ip} ${ovpn_port} udp"
    fields_payload "$ovpn_port" "$payload"
    ;;
  shadowsocks)
    ss_port=${port:-8388}
    payload="server=${server_ip};port=${ss_port};method=aes-256-gcm;password=${password:-<set-password>}"
    fields_payload "$ss_port" "$payload"
    ;;
  http-proxy)
    http_port=${port:-$(load_default_port http)}
    payload="GET / HTTP/1.1\\r\\nHost: ${server_ip}\\r\\n\\r\\n"
    fields_payload "$http_port" "$payload"
    ;;
  socks5)
    socks_port=${port:-1080}
    payload="socks5://${server_ip}:${socks_port}"
    fields_payload "$socks_port" "$payload"
    ;;
  *)
    echo "Unsupported proto: $proto" >&2
    exit 1
    ;;
 esac
