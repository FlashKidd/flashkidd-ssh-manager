#!/usr/bin/env bash
set -euo pipefail

: "${FK_COLOR:=1}"

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/fk-settings.sh"

usage() {
    cat <<'USAGE'
Usage: fk-detect-fronting.sh [options]
  -j, --json <file>      Parse V2Ray/XRay JSON config for defaults
      --ip <IP>          Target IP address
      --sni <host>       TLS SNI / primary host
      --host <host>      Alternate HTTP Host header
      --path <path>      HTTP request path (default /)
      --out <csv>        Append CSV report to file
      --timeout <sec>    Timeout for network requests (default 10)
      --verbose          Increase logging
      --no-color         Disable colors
      --color            Force colors
      --help             Show this help
USAGE
}

fk_common_init "$@"
set -- "${FK_ARGS[@]}"

JSON_FILE=""
TARGET_IP=""
SNI_HOST=""
ALT_HOST=""
REQ_PATH="/"
CSV_OUT=""
TIMEOUT=10
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--json)
            JSON_FILE="$2"
            shift 2
            ;;
        --ip)
            TARGET_IP="$2"
            shift 2
            ;;
        --sni)
            SNI_HOST="$2"
            shift 2
            ;;
        --host)
            ALT_HOST="$2"
            shift 2
            ;;
        --path)
            REQ_PATH="$2"
            shift 2
            ;;
        --out)
            CSV_OUT="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -n "$JSON_FILE" ]]; then
    fk_require_file "$JSON_FILE"
    parsed_ip=$(jq -r '(.outbounds? // [] | .[0]? | .settings?.vnext?[0]?.address) // (.dns?.hosts?|to_entries[]?|select(.key|test("^[0-9.]+$") )|.key)' "$JSON_FILE" | head -n1)
    [[ "$parsed_ip" == "null" ]] && parsed_ip=""
    TARGET_IP=${TARGET_IP:-$parsed_ip}
    parsed_sni=$(jq -r '(.inbounds[]? | .streamSettings?.tlsSettings?.serverName) // empty' "$JSON_FILE" | head -n1)
    [[ "$parsed_sni" == "null" ]] && parsed_sni=""
    SNI_HOST=${SNI_HOST:-$parsed_sni}
    parsed_host=$(jq -r '(.inbounds[]? | .streamSettings?.wsSettings?.headers?.Host) // (.streamSettings?.grpcSettings?.serviceName) // empty' "$JSON_FILE" | head -n1)
    [[ "$parsed_host" == "null" ]] && parsed_host=""
    ALT_HOST=${ALT_HOST:-$parsed_host}
    local_port=$(jq -r '(.inbounds[]? | .port) // empty' "$JSON_FILE" | head -n1)
    [[ -n "$local_port" && "$local_port" != "null" ]] && PORT_HINT="$local_port"
fi

if [[ -z "$TARGET_IP" || -z "$SNI_HOST" ]]; then
    printf 'Error: --ip and --sni are required (or via --json).\n' >&2
    usage
    exit 2
fi

ALT_HOST=${ALT_HOST:-$SNI_HOST}
[[ "$REQ_PATH" == */* ]] || REQ_PATH="/$REQ_PATH"
PORT_HINT=${PORT_HINT:-443}
PORT=${PORT_HINT}

printf '%s\n' "${C_CYAN}FlashKidd Fronting Detector${C_RESET}"
printf '%s\n' "${C_YELLOW}Legal notice: perform only on targets you control or have permission to test.${C_RESET}"

history_file="/tmp/fk-fronting-history"
current_ts=$(date +%s)
old_entries=""
if [[ -f "$history_file" ]]; then
    while read -r ts; do
        if (( current_ts - ts < 60 )); then
            old_entries+="$ts\n"
        fi
    done < "$history_file"
fi
entry_count=$(printf '%s' "$old_entries" | awk 'NF' | wc -l)
if (( entry_count >= 3 )) && [[ $VERBOSE -eq 0 ]]; then
    printf '%s\n' "${C_YELLOW}Rate limit reached (3/min). Use --verbose to override by editing history.${C_RESET}"
    exit 3
fi
printf '%s' "$old_entries$current_ts\n" > "$history_file"

resolve_dns() {
    local host="$1"
    getent hosts "$host" | awk '{print $1}' | sort -u
}

DNS_SNI=$(resolve_dns "$SNI_HOST" | paste -sd',' -)
DNS_ALT=""
if [[ "$ALT_HOST" != "$SNI_HOST" ]]; then
    DNS_ALT=$(resolve_dns "$ALT_HOST" | paste -sd',' -)
fi

[[ -n "$DNS_SNI" ]] || DNS_SNI="unresolved"
[[ -n "$DNS_ALT" ]] || DNS_ALT="unresolved"

printf '%s\n' "${C_BLUE}DNS Resolution${C_RESET}"
printf ' SNI  : %s -> %s\n' "$SNI_HOST" "$DNS_SNI"
printf ' Host : %s -> %s\n' "$ALT_HOST" "$DNS_ALT"

TLS_INFO=""
CERT_FILE="$(mktemp)"
if openssl s_client -servername "$SNI_HOST" -connect "$TARGET_IP:$PORT" -timeout "$TIMEOUT" </dev/null >"$CERT_FILE" 2>&1; then
    CERT_CN=$(awk -F'=' '/subject=/ {print $NF; exit}' "$CERT_FILE")
    CERT_ISSUER=$(awk -F'=' '/issuer=/ {print $NF; exit}' "$CERT_FILE")
    CERT_SAN=$(grep -i 'DNS:' "$CERT_FILE" | head -n1 | sed 's/.*DNS://;s/,.*//')
    CERT_VALID_FROM=$(grep -i 'notBefore' "$CERT_FILE" | head -n1 | awk -F'=' '{print $2}')
    CERT_VALID_TO=$(grep -i 'notAfter' "$CERT_FILE" | head -n1 | awk -F'=' '{print $2}')
    TLS_OK=1
else
    TLS_OK=0
fi

printf '%s\n' "${C_BLUE}TLS Certificate${C_RESET}"
if (( TLS_OK == 1 )); then
    printf ' CN     : %s\n' "$CERT_CN"
    printf ' SAN    : %s\n' "$CERT_SAN"
    printf ' Issuer : %s\n' "$CERT_ISSUER"
    printf ' Valid  : %s -> %s\n' "$CERT_VALID_FROM" "$CERT_VALID_TO"
else
    printf ' Unable to establish TLS session.\n'
fi

http_request() {
    local host="$1" header_host="$2"
    curl -ksS --resolve "$host:$PORT:$TARGET_IP" -H "Host: $header_host" --max-time "$TIMEOUT" "https://$host$REQ_PATH"
}

HTTP_CONTROL=$(http_request "$SNI_HOST" "$SNI_HOST" || true)
HTTP_TEST=$(http_request "$SNI_HOST" "$ALT_HOST" || true)

CONTROL_LEN=${#HTTP_CONTROL}
TEST_LEN=${#HTTP_TEST}
CONTROL_HASH=$(printf '%s' "$HTTP_CONTROL" | sha256sum | awk '{print $1}')
TEST_HASH=$(printf '%s' "$HTTP_TEST" | sha256sum | awk '{print $1}')

HEADER_FILE="$FK_LOG_DIR/fronting-$(date '+%Y%m%d-%H%M%S')-$TARGET_IP.headers"
mkdir -p "$FK_LOG_DIR"
{ curl -ksSI --resolve "$SNI_HOST:$PORT:$TARGET_IP" "https://$SNI_HOST$REQ_PATH"; printf '\n'; curl -ksSI --resolve "$SNI_HOST:$PORT:$TARGET_IP" -H "Host: $ALT_HOST" "https://$SNI_HOST$REQ_PATH"; } > "$HEADER_FILE" 2>/dev/null || true

printf '%s\n' "${C_BLUE}HTTP fingerprints${C_RESET}"
printf ' Control bytes : %s\n' "$CONTROL_LEN"
printf ' Alternate     : %s\n' "$TEST_LEN"

headers_detect=$(grep -Ei 'cf-ray|x-cache|via|akamai|cloudflare|sucuri|x-sucuri-id|fastly' "$HEADER_FILE" | tr -d '\r' | paste -sd',' -)
headers_detect=${headers_detect:-none}
printf ' CDN headers    : %s\n' "$headers_detect"

REASONS=()
VERDICT="OK"
EXIT_CODE=0

if (( TLS_OK == 0 )); then
    REASONS+=('tls_failed')
    VERDICT="WARN"
fi
if (( TLS_OK == 1 )) && [[ "$CERT_SAN" != *"$SNI_HOST"* ]]; then
    REASONS+=('san_mismatch')
    [[ "$VERDICT" == "OK" ]] && VERDICT="WARN"
fi
if [[ "$ALT_HOST" != "$SNI_HOST" && $CONTROL_LEN -gt 0 && $TEST_LEN -gt 0 ]]; then
    if [[ "$CONTROL_HASH" == "$TEST_HASH" ]]; then
        REASONS+=('identical_bodies')
        VERDICT="FAIL"
        EXIT_CODE=2
    elif (( TEST_LEN > 0 )); then
        REASONS+=('alt_host_served')
        [[ "$VERDICT" != "FAIL" ]] && VERDICT="WARN"
    fi
fi
if [[ "$headers_detect" == *cloudflare* || "$headers_detect" == *akamai* || "$headers_detect" == *fastly* ]]; then
    REASONS+=('cdn_detected')
fi

printf '%s\n' "${C_BLUE}Heuristics${C_RESET}"
verdict_color="$C_GREEN"
if [[ "$VERDICT" == "FAIL" ]]; then
    verdict_color="$C_RED"
elif [[ "$VERDICT" == "WARN" ]]; then
    verdict_color="$C_YELLOW"
fi
printf ' Verdict : %s%s%s\n' "$verdict_color" "$VERDICT" "$C_RESET"
printf ' Reasons : %s\n' "${REASONS[*]:-none}"
printf ' Headers : %s\n' "$headers_detect"
printf ' Saved headers -> %s\n' "$HEADER_FILE"

if [[ -n "$CSV_OUT" ]]; then
    reasons_csv="${REASONS[*]:-}"
    reasons_csv=${reasons_csv// /;}
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$TARGET_IP" "$SNI_HOST" "$ALT_HOST" "$PORT" "$VERDICT" "$reasons_csv" "${CERT_CN:-}" "${CERT_SAN:-}" "$headers_detect" >> "$CSV_OUT"
fi

rm -f "$CERT_FILE"

exit "$EXIT_CODE"
