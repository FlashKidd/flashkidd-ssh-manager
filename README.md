# Flashkidd SSH Manager

Flashkidd SSH Manager provides an interactive `fk-ssh` orchestration CLI along with helper scripts that streamline creating SSH and V2Ray accounts, managing payload artifacts, editing banners, tuning proxy ports, and scraping CDN diagnostics. The toolkit is tailored for operators who need to generate the raw connection details that power HTTP Injector or mobile tunneling clients while keeping secrets safe on-disk.

## Features

- Interactive menu-driven workflow for provisioning SSH or V2Ray (vmess/vless) accounts, managing ports, editing ANSI banners, generating payload fields, scraping CDN headers, and reviewing the last account summary.【F:bin/fk-ssh†L1-L139】
- Non-interactive subcommands for automation-friendly user creation, payload generation, and JSON exports suitable for piping into external tooling.【F:bin/fk-ssh†L417-L508】【F:bin/fk-payload.sh†L1-L90】
- Secure account registry stored in `/opt/flashkidd/conf/users/<username>.json` with atomic writes and `chmod 600`, plus an index file and audit logging that excludes secrets.【F:bin/fk-user.sh†L118-L206】
- Payload helpers that emit raw field data (not full client configs) for SSH, OpenVPN, V2Ray, Shadowsocks, HTTP proxy, and SOCKS5 flows, with vmess JSON + single-line imports when requested.【F:bin/fk-payload.sh†L92-L205】
- Squid port helpers that default to 8080/3128 and allow persistent reconfiguration via the Port Manager menu.【F:lib/squid.sh†L1-L57】【F:conf/defaults.json†L2-L14】
- Reliable server IP detection that prioritises the system routing table and falls back to ifconfig.co to keep all generated outputs hostname-free.【F:lib/server_info.sh†L1-L33】

## Requirements

- Bash 5+
- Python 3.8+
- `curl`, `iproute2`, and standard GNU coreutils
- Permission to create and write to:
  - `/opt/flashkidd/conf/`
  - `/opt/flashkidd/payloads/`
  - `/var/log/flashkidd-ssh-manager.log`

> **Tip:** Run the CLI as a privileged user (e.g. via `sudo`) so it can persist configuration, payload, and audit files in the required locations.

## Installation

1. Clone the repository on the target server:
   ```bash
   git clone https://github.com/flashkidd/flashkidd-ssh-manager.git
   cd flashkidd-ssh-manager
   ```
2. (Optional) Place the executables on your `PATH`:
   ```bash
   sudo install -m 0755 bin/fk-ssh /usr/local/bin/
   sudo install -m 0755 bin/fk-user.sh /usr/local/bin/
   sudo install -m 0755 bin/fk-payload.sh /usr/local/bin/
   ```
3. Ensure the configuration and payload directories exist with the right ownership:
   ```bash
   sudo mkdir -p /opt/flashkidd/conf /opt/flashkidd/payloads
   sudo chown $USER /opt/flashkidd/conf /opt/flashkidd/payloads
   ```
4. Verify defaults by inspecting `conf/defaults.json` and adjust only if necessary before first use.【F:conf/defaults.json†L1-L18】

## Usage

### Interactive mode

Launch the main menu:
```bash
fk-ssh
```

Choose from the numbered options to create accounts, manage ports, generate payload field snippets, edit the colorful banner saved in `conf/banner.txt`, run the CDN/link scraper, or view the last created account. Each account creation flow resolves the server IP, prints a human-friendly summary card, and writes a JSON record alongside any payload artifacts.【F:bin/fk-ssh†L140-L416】

### Non-interactive account creation

Automate provisioning without menus using subcommands:
```bash
fk-ssh user create \
  --user flashkidd \
  --services ssh,v2ray,squid \
  --expires $(date -d '+7 days' --iso-8601=seconds) \
  --port-map '{"ssh":22,"v2ray":443,"squid":[8080,3128]}' \
  --json-output /tmp/flashkidd.json
```
The CLI emits a compact success line, writes the JSON payload to `/tmp/flashkidd.json`, and still stores the canonical record under `/opt/flashkidd/conf/users/<username>.json`. Use `--help` on any subcommand to discover additional flags.【F:bin/fk-ssh†L417-L508】

### Generating payload field snippets

Use the dedicated helper to craft field-only payload data:
```bash
fk-payload.sh --proto vmess --user flashkidd --json
```
- When `--proto vmess` is selected, the script writes a vmess JSON file to `/opt/flashkidd/payloads/`, prints a one-line `vmess://` string, and returns machine-readable metadata when `--json` is used.【F:bin/fk-payload.sh†L92-L205】
- Other protocols (SSH, OpenVPN, Shadowsocks, HTTP proxy, SOCKS5) output structured fields describing the remote host, port, payload string, and credentials placeholders.【F:bin/fk-payload.sh†L92-L205】

### Managing ports

The Port Manager updates the persisted port state at `/opt/flashkidd/conf/ports.json` so subsequent sessions reuse your custom values. Squid helpers ensure safe writes and maintain the expected dual-port default of 8080 and 3128.【F:bin/fk-ssh†L24-L139】【F:lib/squid.sh†L1-L57】

### CDN / Link Scraper

From the menu, supply a target URL. The scraper fetches the page, extracts unique hosts, then issues HEAD requests capturing `Server`, `Via`, `X-Cache`, `CF-Ray`, and `X-Amz-Cf-Id` headers to help identify CDN-backed endpoints.【F:bin/fk-ssh†L309-L369】

## Data & Logging Layout

- **User records:** `/opt/flashkidd/conf/users/<username>.json` (0600) with metadata, vmess link (when applicable), and payload paths.【F:bin/fk-user.sh†L118-L206】
- **User index:** `/opt/flashkidd/conf/users.json` keeps a list of known accounts for quick lookup.【F:bin/fk-user.sh†L161-L206】
- **Payloads:** `/opt/flashkidd/payloads/` stores generated field files, including vmess JSON exports and optional OpenVPN stubs.【F:bin/fk-ssh†L202-L254】【F:bin/fk-payload.sh†L92-L205】
- **Audit log:** `/var/log/flashkidd-ssh-manager.log` receives metadata-only entries without plaintext secrets or full vmess URIs.【F:bin/fk-user.sh†L71-L117】

## Testing

Run the regression script to validate IP detection, summary formatting, payload metadata, and squid defaults:
```bash
./tests/test_all.sh
```
The tests execute isolated helper routines and confirm key behaviors expected by the CLI.【F:tests/test_all.sh†L1-L75】

## Troubleshooting

- **Server IP resolution fails:** Ensure `ip route` is available. The fallback uses `curl -s ifconfig.co`; confirm outbound internet access.【F:lib/server_info.sh†L5-L33】
- **Permission denied writing payloads or logs:** Re-run the CLI with elevated privileges or adjust ownership of `/opt/flashkidd` and `/var/log/flashkidd-ssh-manager.log`.
- **Missing vmess output:** Check that the payload directory exists and that `fk-payload.sh` can create JSON files with `chmod 600` permissions.【F:bin/fk-payload.sh†L92-L205】

