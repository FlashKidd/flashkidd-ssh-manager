#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULTS_FILE="$ROOT_DIR/conf/defaults.json"
LOG_FILE="/var/log/flashkidd-ssh-manager.log"
USERS_DIR="/opt/flashkidd/conf/users"
USERS_INDEX="/opt/flashkidd/conf/users.json"

mkdir -p "$USERS_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

write_atomic() {
  local path=$1
  local perm=$2
  local content=$3
  local dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.tmp.XXXXXX")
  printf '%s' "$content" >"$tmp"
  chmod "$perm" "$tmp"
  mv "$tmp" "$path"
}

log_action() {
  local timestamp action user server_ip services expires payloads vmess_json
  timestamp=$(date --iso-8601=seconds)
  action=$1
  user=$2
  server_ip=$3
  services=$4
  expires=$5
  payloads=$6
  vmess_json=$7
  printf '%s action=%s user=%s server_ip=%s services=%s expires=%s payloads=%s vmess_json=%s\n' \
    "$timestamp" "$action" "$user" "$server_ip" "$services" "$expires" "$payloads" "$vmess_json" >>"$LOG_FILE"
}

update_index() {
  local username=$1
  local file_path=$2
  local created_at=$3
  local expires_at=$4
  python3 - "$USERS_INDEX" "$username" "$file_path" "$created_at" "$expires_at" <<'PY'
import json, sys, os
index_path, username, file_path, created_at, expires_at = sys.argv[1:6]
record = {"username": username, "file": file_path, "created_at": created_at, "expires_at": expires_at}
if os.path.exists(index_path):
    with open(index_path) as fh:
        data = json.load(fh)
else:
    data = {"users": []}
users = [u for u in data.get("users", []) if u.get("username") != username]
users.append(record)
data["users"] = users
content = json.dumps(data, indent=2)
dirname = os.path.dirname(index_path)
os.makedirs(dirname, exist_ok=True)
tmp_path = os.path.join(dirname, f'.tmp.{os.getpid()}')
with open(tmp_path, 'w') as fh:
    fh.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, index_path)
PY
}

create_user() {
  local username="flashkidd"
  local auth_method="password"
  local password=""
  local services_json="[]"
  local ports_json="{}"
  local server_ip=""
  local payloads_json="[]"
  local created_at=""
  local expires_at=""
  local vmess_link=""
  local vmess_json_path=""
  local json_output=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --username) username=$2; shift 2;;
      --auth-method) auth_method=$2; shift 2;;
      --password) password=$2; shift 2;;
      --services) services_json=$2; shift 2;;
      --ports) ports_json=$2; shift 2;;
      --server-ip) server_ip=$2; shift 2;;
      --payloads) payloads_json=$2; shift 2;;
      --created-at) created_at=$2; shift 2;;
      --expires-at) expires_at=$2; shift 2;;
      --vmess-link) vmess_link=$2; shift 2;;
      --vmess-json-path) vmess_json_path=$2; shift 2;;
      --json-output) json_output=$2; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 1;;
    esac
  done

  if [[ -z $server_ip ]]; then
    echo "server_ip is required" >&2
    exit 1
  fi
  if [[ -z $created_at ]]; then
    created_at=$(date --iso-8601=seconds)
  fi
  if [[ -z $password ]]; then
    password=""
  fi

  local user_file="$USERS_DIR/${username}.json"
  local json_content
  json_content=$(python3 - <<PY
import json, sys
username = ${username@Q}
auth_method = ${auth_method@Q}
password = ${password@Q}
services = json.loads(${services_json@Q})
ports = json.loads(${ports_json@Q})
server_ip = ${server_ip@Q}
payloads = json.loads(${payloads_json@Q})
created_at = ${created_at@Q}
expires_at = ${expires_at@Q}
vmess_link = ${vmess_link@Q}
content = {
  "username": username,
  "auth_method": auth_method,
  "password": password,
  "services": services,
  "server_ip": server_ip,
  "ports": ports,
  "vmess_link": vmess_link or None,
  "payload_paths": payloads,
  "created_at": created_at,
  "expires_at": expires_at or None
}
print(json.dumps(content, indent=2))
PY
)

  write_atomic "$user_file" 600 "$json_content"
  update_index "$username" "$user_file" "$created_at" "$expires_at"
  local services_log payloads_log
  services_log=$(python3 - "$services_json" <<'PY'
import json, sys
print(",".join(json.loads(sys.argv[1])))
PY
)
  payloads_log=$(python3 - "$payloads_json" <<'PY'
import json, sys
print(",".join(json.loads(sys.argv[1])))
PY
)
  log_action create "$username" "$server_ip" "$services_log" "$expires_at" "$payloads_log" "$vmess_json_path"

  if [[ -n $json_output ]]; then
    write_atomic "$json_output" 600 "$json_content"
  fi
  printf '%s\n' "$json_content"
}

revoke_user() {
  local username=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --username) username=$2; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 1;;
    esac
  done
  if [[ -z $username ]]; then
    echo "Username required" >&2
    exit 1
  fi
  local user_file="$USERS_DIR/${username}.json"
  if [[ -f $user_file ]]; then
    rm -f "$user_file"
  fi
  python3 - "$USERS_INDEX" "$username" <<'PY'
import json, sys, os
index_path, username = sys.argv[1:3]
if not os.path.exists(index_path):
    sys.exit(0)
with open(index_path) as fh:
    data = json.load(fh)
users = [u for u in data.get("users", []) if u.get("username") != username]
data["users"] = users
content = json.dumps(data, indent=2)
dirname = os.path.dirname(index_path)
os.makedirs(dirname, exist_ok=True)
tmp_path = os.path.join(dirname, f'.tmp.{os.getpid()}')
with open(tmp_path, 'w') as fh:
    fh.write(content)
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, index_path)
PY
  log_action revoke "$username" "-" "-" "-" "-"
}

command=$1; shift || true
case ${command:-} in
  create) create_user "$@" ;;
  revoke) revoke_user "$@" ;;
  *) echo "Usage: $0 {create|revoke} ..." >&2; exit 1;;
 esac
