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
Usage: fk-recon.sh [--color|--no-color]
Runs the FlashKidd reconnaissance suite: port scan, subdomain scan, scraper, and SNI/fronting detection.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env

LOG_FILE="$FK_LOG_DIR/recon-$(date '+%Y%m%d-%H%M%S').txt"

port_scan() {
    read -rp 'Target host/IP: ' host
    read -rp 'Ports (e.g. 22,80,443 or 1-1024): ' ports
    printf '== Port scan %s ==\n' "$host" | tee -a "$LOG_FILE"
    IFS=',' read -ra port_list <<<"$ports"
    for item in "${port_list[@]}"; do
        if [[ "$item" =~ - ]]; then
            start=${item%-*}
            end=${item#*-}
            for ((p=start; p<=end; p++)); do
                if nc -z -w1 "$host" "$p" >/dev/null 2>&1; then
                    printf 'Port %s open\n' "$p" | tee -a "$LOG_FILE"
                fi
            done
        else
            if nc -z -w1 "$host" "$item" >/dev/null 2>&1; then
                printf 'Port %s open\n' "$item" | tee -a "$LOG_FILE"
            fi
        fi
    done
}

subdomain_scan() {
    read -rp 'Base domain: ' domain
    read -rp 'Wordlist path (blank for built-in): ' wordlist
    printf '== Subdomain scan %s ==\n' "$domain" | tee -a "$LOG_FILE"
    if [[ -n "$wordlist" && -f "$wordlist" ]]; then
        words=$(cat "$wordlist")
    else
        words=$'www\napi\ncdn\nportal\nedge'
    fi
    while IFS= read -r sub; do
        fqdn="$sub.$domain"
        if host "$fqdn" >/dev/null 2>&1; then
            printf '%s resolves\n' "$fqdn" | tee -a "$LOG_FILE"
        fi
    done <<<"$words"
}

web_scrape() {
    read -rp 'URL to scrape: ' url
    printf '== Web scrape %s ==\n' "$url" | tee -a "$LOG_FILE"
    body=$(curl -fsSL "$url" || true)
    if [[ -z "$body" ]]; then
        printf 'No content fetched.\n' | tee -a "$LOG_FILE"
        return
    fi
    printf 'Links found:\n' | tee -a "$LOG_FILE"
    printf '%s' "$body" | grep -Eo 'https?://[^" ]+' | sort -u | tee -a "$LOG_FILE"
    printf '\nHeaders:\n' | tee -a "$LOG_FILE"
    curl -fsSI "$url" | tee -a "$LOG_FILE"
}

run_fronting() {
    read -rp 'JSON config path (blank to skip): ' json
    read -rp 'SNI host: ' sni
    read -rp 'Resolve IP: ' ip
    read -rp 'HTTP host override (blank for SNI): ' host
    read -rp 'Path [/]: ' req_path
    cmd=("$SCRIPT_DIR/fk-detect-fronting.sh" --ip "$ip" --sni "$sni")
    [[ -n "$json" ]] && cmd+=(--json "$json")
    [[ -n "$host" ]] && cmd+=(--host "$host")
    [[ -n "$req_path" ]] && cmd+=(--path "$req_path")
    "${cmd[@]}" | tee -a "$LOG_FILE"
}

while true; do
    fk_banner
    cat <<'MENU'
Recon Suite
1) Port scan
2) Subdomain scan
3) Web scraper
4) Detect fronting / SNI mismatch
0) Back
MENU
    read -rp 'Select: ' opt
    case "$opt" in
        1) port_scan ;;
        2) subdomain_scan ;;
        3) web_scrape ;;
        4) run_fronting ;;
        0) break ;;
        *) printf 'Invalid.\n' ;;
    esac
    fk_box 'Recon complete' "Results saved to $LOG_FILE"
    fk_print_post_action
done
