#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$ROOT_DIR/lib/server_info.sh"

server_ip=$(get_server_ip)
if [[ ! $server_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "get_server_ip did not return IPv4" >&2
  exit 1
fi

echo "Server IP: $server_ip"

test_user="fk_test_$RANDOM"
json_out="/tmp/${test_user}.json"
expires=$(date -d '+1 day' --iso-8601=seconds)
output=$("$ROOT_DIR/bin/fk-ssh" user create --user "$test_user" --services ssh --expires "$expires" --json-output "$json_out")
clean_output=$(printf '%s' "$output" | perl -pe 's/\x1b\[[0-9;]*m//g')
if [[ $clean_output != *"ServerIP : $server_ip"* ]]; then
  echo "Human summary missing ServerIP" >&2
  exit 1
fi
if [[ $clean_output != *"Ports    : ssh=22, http=80, tls=443"* ]]; then
  echo "Human summary missing port map" >&2
  exit 1
fi

user_json_path="/opt/flashkidd/conf/users/${test_user}.json"
if [[ ! -f $user_json_path ]]; then
  echo "User JSON not created" >&2
  exit 1
fi
perm=$(stat -c '%a' "$user_json_path")
if [[ $perm != "600" ]]; then
  echo "User JSON permissions incorrect" >&2
  exit 1
fi

python3 - "$user_json_path" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
required = ["username","auth_method","password","services","server_ip","ports","payload_paths","created_at","expires_at"]
for key in required:
    assert key in data, f"missing {key}"
print("JSON schema validated")
PY

if [[ ! -f $json_out ]]; then
  echo "json-output file missing" >&2
  exit 1
fi

mapfile -t vmess_lines < <("$ROOT_DIR/bin/fk-payload.sh" --proto vmess --user "$test_user" --json)
vmess_json=${vmess_lines[-1]}
python3 - <<PY "$vmess_json"
import json, sys
info = json.loads(sys.argv[1])
assert "vmess_link" in info and info["vmess_link"].startswith("vmess://"), "vmess link missing"
assert "payload_path" in info and info["payload_path"], "payload path missing"
print("VMess payload validated")
PY

python3 - <<'PY' "$ROOT_DIR/conf/defaults.json"
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
ports = data["default_ports"].get("squid")
assert ports == [8080, 3128], "Squid defaults incorrect"
print("Defaults validated")
PY

echo "All tests passed"
