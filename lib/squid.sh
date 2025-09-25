#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULTS_FILE="$ROOT_DIR/conf/defaults.json"
SQUID_CONF=${SQUID_CONF:-/etc/squid/squid.conf}

read_defaults_squid_ports() {
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); ports=data["default_ports"].get("squid", [8080,3128]); print(" ".join(str(p) for p in ports))' "$DEFAULTS_FILE"
}

get_squid_ports() {
  local ports=()
  if [[ -f $SQUID_CONF ]]; then
    while read -r line; do
      if [[ $line =~ ^[[:space:]]*http_port[[:space:]]+([0-9]+) ]]; then
        ports+=("${BASH_REMATCH[1]}")
      fi
    done <"$SQUID_CONF"
  fi
  if [[ ${#ports[@]} -eq 0 ]]; then
    read -r -a ports <<<"$(read_defaults_squid_ports)"
  fi
  printf '%s\n' "${ports[*]}"
}

set_squid_ports() {
  local new_ports=("$@")
  if [[ ${#new_ports[@]} -eq 0 ]]; then
    echo "No ports specified" >&2
    return 1
  fi
  mkdir -p "$(dirname "$SQUID_CONF")"
  local tmp
  tmp=$(mktemp)
  {
    echo "# Managed by flashkidd-ssh-manager"
    for port in "${new_ports[@]}"; do
      echo "http_port $port"
    done
  } >"$tmp"
  mv "$tmp" "$SQUID_CONF"
}

reload_squid() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload squid >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service squid reload >/dev/null 2>&1 || true
  fi
}

update_squid_ports() {
  set_squid_ports "$@"
  reload_squid
}
