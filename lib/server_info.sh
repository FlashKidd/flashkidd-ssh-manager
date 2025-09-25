#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

get_server_ip() {
  local ip_route ip_curl
  if command -v ip >/dev/null 2>&1; then
    ip_route=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
  fi
  if [[ -n ${ip_route:-} ]] && [[ $ip_route =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip_route"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    ip_curl=$(curl -s --max-time 5 ifconfig.co 2>/dev/null || true)
    if [[ -z ${ip_curl:-} ]] || [[ ! $ip_curl =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      ip_curl=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
  fi
  if [[ -n ${ip_curl:-} ]] && [[ $ip_curl =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip_curl"
    return 0
  fi
  if command -v hostname >/dev/null 2>&1; then
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n ${host_ip:-} ]] && [[ $host_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$host_ip"
      return 0
    fi
  fi
  return 1
}
