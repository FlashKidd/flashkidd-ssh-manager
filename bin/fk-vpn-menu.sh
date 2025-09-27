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
Usage: fk-vpn-menu.sh [--color|--no-color]
Manages OpenVPN and WireGuard client profiles for FlashKidd SSH Manager.
USAGE
}

if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

fk_require_root
fk_load_env
SERVER_IP=$(fk_primary_ipv4)

OVPN_BASE="/etc/openvpn"
OVPN_CLIENT_DIR="$OVPN_BASE/client"
OVPN_PKI_DIR="$OVPN_BASE/fk-pki"
WG_DIR="/etc/wireguard"
WG_CLIENT_DIR="$WG_DIR/clients"
mkdir -p "$OVPN_CLIENT_DIR" "$OVPN_PKI_DIR" "$WG_CLIENT_DIR"

init_openvpn_pki() {
    local ca_cert="$OVPN_PKI_DIR/ca.crt"
    local ca_key="$OVPN_PKI_DIR/ca.key"
    local ta_key="$OVPN_PKI_DIR/ta.key"
    if [[ ! -f "$ca_cert" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$ca_key" -out "$ca_cert" \
            -days 3650 -subj "/C=US/ST=Flash/L=Kidd/O=FlashKidd/OU=SSH/CN=FlashKidd-CA"
        fk_log 'Created OpenVPN CA'
    fi
    if [[ ! -f "$ta_key" ]]; then
        openvpn --genkey --secret "$ta_key"
    fi
}

create_openvpn_client() {
    init_openvpn_pki
    read -rp 'Client name: ' name
    [[ -n "$name" ]] || { printf 'Name required.\n'; return; }
    local client_key="$OVPN_PKI_DIR/${name}.key"
    local client_csr="$OVPN_PKI_DIR/${name}.csr"
    local client_crt="$OVPN_PKI_DIR/${name}.crt"
    local ca_cert="$OVPN_PKI_DIR/ca.crt"
    local ca_key="$OVPN_PKI_DIR/ca.key"
    local ta_key="$OVPN_PKI_DIR/ta.key"
    openssl genrsa -out "$client_key" 2048
    openssl req -new -key "$client_key" -out "$client_csr" -subj "/CN=$name"
    openssl x509 -req -in "$client_csr" -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial -out "$client_crt" -days 825
    local ovpn="$OVPN_CLIENT_DIR/${name}.ovpn"
    cat > "$ovpn" <<OVPN
client
dev tun
proto udp
remote $SERVER_IP ${OPENVPN_UDP:-1194}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
key-direction 1
verb 3
<ca>
$(cat "$ca_cert")
</ca>
<cert>
$(cat "$client_crt")
</cert>
<key>
$(cat "$client_key")
</key>
<tls-auth>
$(cat "$ta_key")
</tls-auth>
OVPN
    fk_box 'OpenVPN profile created' "Client: $name" "Path: $ovpn"
    fk_print_post_action
}

create_wireguard_client() {
    local iface="wg0"
    read -rp 'Client name: ' name
    [[ -n "$name" ]] || { printf 'Name required.\n'; return; }
    local priv pub preshared
    priv=$(wg genkey)
    pub=$(printf '%s' "$priv" | wg pubkey)
    preshared=$(wg genpsk)
    local server_pub
    if [[ -f "$WG_DIR/$iface-server.key" ]]; then
        server_pub=$(cat "$WG_DIR/$iface-server.key.pub")
    else
        local server_priv
        server_priv=$(wg genkey)
        server_pub=$(printf '%s' "$server_priv" | wg pubkey)
        printf '%s' "$server_priv" > "$WG_DIR/$iface-server.key"
        printf '%s' "$server_pub" > "$WG_DIR/$iface-server.key.pub"
    fi
    local count
    count=$(find "$WG_CLIENT_DIR" -maxdepth 1 -name '*.conf' | wc -l)
    local addr_octet=$((count + 2))
    local client_ip="10.8.0.${addr_octet}/32"
    local client_file="$WG_CLIENT_DIR/${name}.conf"
    cat > "$client_file" <<WG
[Interface]
PrivateKey = $priv
Address = $client_ip
DNS = 1.1.1.1

[Peer]
PublicKey = $server_pub
PresharedKey = $preshared
Endpoint = $SERVER_IP:${WIREGUARD_UDP:-51820}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WG
    fk_box 'WireGuard profile created' "Client: $name" "Path: $client_file" "Address: $client_ip"
    if command -v qrencode >/dev/null 2>&1; then
        local qr="$WG_CLIENT_DIR/${name}.png"
        qrencode -t PNG -o "$qr" < "$client_file"
        printf 'QR code saved to %s\n' "$qr"
    fi
    fk_print_post_action
}

show_wireguard_hint() {
    local client
    for client in "$WG_CLIENT_DIR"/*.conf; do
        [[ -e "$client" ]] || continue
        printf '%s\n' "$client"
    done
    fk_box 'WireGuard clients' "Listed above"
    fk_print_post_action
}

while true; do
    fk_banner
    cat <<'MENU'
VPN Menu
1) Create OpenVPN client profile
2) Create WireGuard client profile
3) List WireGuard clients
0) Back
MENU
    read -rp 'Select: ' opt
    case "$opt" in
        1) create_openvpn_client ;;
        2) create_wireguard_client ;;
        3) show_wireguard_hint ;;
        0) break ;;
        *) printf 'Invalid.\n' ;;
    esac
done
