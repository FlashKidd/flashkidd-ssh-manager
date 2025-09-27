# FlashKidd SSH Manager

![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg) ![Shell](https://img.shields.io/badge/Shell-Bash%20POSIX-green.svg)

FlashKidd SSH Manager is a production-ready automation toolkit that provisions secure SSH, VPN, and proxy services on any modern Debian/Ubuntu host. It wraps best-practice hardening, service management, payload generation, and reconnaissance tooling into a cohesive command line experience.

## Features
- Interactive `fk-ssh` control center with 16 operational modules.
- Idempotent installer that bootstraps dependencies, firewall rules, and configuration scaffolding.
- Full SSH lifecycle management (create, trial, renew, delete) with compliance-grade logging.
- Automated OpenVPN and WireGuard profile generators with PKI handling and QR support.
- V2Ray VMess/VLESS/WebSocket manager with systemd integration and client link exports.
- Per-user bandwidth throttling using `tc` + iptables marks, persisted through a systemd unit.
- Safe port management with collision detection, firewall reconciliation, and rollback.
- Reconnaissance suite (port scan, subdomain sweep, HTTP scraper, and fronting detector).
- Backup/restore automation, banner customization, system dashboards, and log viewers.
- FlashKidd fronting detector with JSON parsing, DNS/TLS/HTTP heuristics, and CSV exports.

## Quick Start
1. `apt update -y`
2. `curl -fsSL https://raw.githubusercontent.com/FlashKidd/flashkidd-ssh-manager/main/install.sh | sudo bash`
3. Run: `fk-ssh`

The installer creates `/etc/fk-ssh/`, copies example configuration files, installs dependencies, and symlinks the `fk-*` toolchain into `/usr/local/bin/`.

## Default Ports
| Service | Variable | Default |
|---------|----------|---------|
| OpenSSH | `SSH_PORT_PRIMARY` | 22 |
| OpenSSH (secondary) | `SSH_PORT_SECONDARY` | 80 |
| SSH over TLS | `SSH_TLS_PORT` | 443 |
| Squid/HTTP Proxy | `SQUID_PORTS` | 8080 3128 90 |
| V2Ray VMess TCP | `V2RAY_VMESS_TCP` | 10086 |
| V2Ray VMess WebSocket | `V2RAY_VMESS_WS` | 80 |
| V2Ray VMess TLS-WS | `V2RAY_VMESS_TLS` | 443 |
| V2Ray VLESS TLS | `V2RAY_VLESS_TLS` | 443 |
| OpenVPN UDP | `OPENVPN_UDP` | 1194 |
| OpenVPN TCP | `OPENVPN_TCP` | 443 |
| WireGuard UDP | `WIREGUARD_UDP` | 51820 |

To change a value edit `/etc/fk-ssh/ports.env` or use the Port Manager module from `fk-ssh`. Every change validates port availability, updates firewall rules, and logs the operation.

## Copy-Ready Examples

### Create SSH User
```
+----------------- Account Created ------------------+
 Server IP   : 203.0.113.15
 Username    : alice
 Password    : p@ssw0rd!
 Expires     : 2024-12-31  (30 days)
 SSH Port(s) : 22 80
-----------------------------------------------------
 Copy/paste ready SSH:
 ssh alice@203.0.113.15 -p 22
+----------------------------------------------------+
```

### Create Trial User
```
+----------------- Trial Account Created ------------------+
 Server IP   : 203.0.113.15
 Username    : trial3kp9 (Trial)
 Password    : 2nrb3qhq
 Expires     : 2024-07-05  (3 days)
 SSH Port(s) : 22 80
-----------------------------------------------------
 Copy/paste ready SSH:
 ssh trial3kp9@203.0.113.15 -p 22
+----------------------------------------------------+
```

### V2Ray VMess Link
```
VMess client created
Name : premium-01
UUID : 12345678-90ab-cdef-1234-567890abcdef
Expires : 2024-12-31
Link : vmess://eyJ2IjoiMiIsInBzIjoicHJlbWl1bS0wMSIsImFkZCI6ImNkbi5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjEyMzQ1Njc4LTkwYWItY2RlZi0xMjM0LTU2Nzg5MGFiY2RlZiIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0Ijoib3JpZ2luLmV4YW1wbGUuY29tIiwicGF0aCI6Ii9mbGFzaGtpZGQiLCJ0bHMiOiJ0bHMifQ==
```

### Port Change with Rollback Safety
```
+------------------------------------------------+
| Port updated                                    |
| Key: SSH_PORT_PRIMARY                           |
| New port(s): 2222                               |
| Firewall refreshed                              |
+------------------------------------------------+
```

### Fronting Detector Sample Output
```
FlashKidd Fronting Detector
Legal notice: perform only on targets you control or have permission to test.
DNS Resolution
 SNI  : cdn.example.com -> 203.0.113.10
 Host : origin.example.com -> 203.0.113.10
TLS Certificate
 CN     : origin.example.com
 SAN    : origin.example.com
 Issuer : FlashKidd CA
 Valid  : Jan  1 00:00:00 2024 GMT -> Jan  1 00:00:00 2025 GMT
HTTP fingerprints
 Control bytes : 5120
 Alternate     : 5120
 CDN headers    : cf-ray:12345
Heuristics
 Verdict : WARN
 Reasons : alt_host_served san_mismatch cdn_detected
 Headers : cf-ray:12345
 Saved headers -> /etc/fk-ssh/logs/fronting-20240101-120000-203.0.113.10.headers
```

## FlashKidd Fronting Detector
The detector (`fk-detect-fronting.sh`) analyses potential CDN/SNI fronting scenarios:

1. Parses optional JSON (V2Ray/XRay) to auto-populate IP, SNI, and WebSocket host/path.
2. Resolves DNS for the SNI and HTTP host, highlighting mismatches.
3. Extracts TLS metadata with `openssl s_client` (CN, SAN, issuer, validity window).
4. Performs dual HTTP requests using `curl --resolve` to compare host headers.
5. Flags CDN fingerprints (`cf-ray`, `x-cache`, `via`, `akamai`, `fastly`, `x-sucuri-id`).
6. Generates colored verdicts (OK/WARN/FAIL), reason codes, and optional CSV rows.
7. Saves raw headers to `/etc/fk-ssh/logs/fronting-<timestamp>-<ip>.headers`.

**CLI shortcuts**
```
fk-detect-fronting.sh --json /etc/v2ray/config.json --ip 203.0.113.10 \
  --sni cdn.example.com --host origin.example.com --path /flashkidd \
  --out /root/fronting.csv
```

The detector honours `FK_COLOR`, `--color`, and `--no-color` flags and rate-limits scans to three per minute (overrideable by editing `/tmp/fk-fronting-history`). Exit code `2` signals a confirmed fronting vulnerability.

## Settings & Pinning
All configuration is stored under `/etc/fk-ssh/`:

- `ports.env` – service port definitions read by every module.
- `settings.env` – runtime flags, binary pinning (`FK_PIN_*`), update channels.
- `throttle.rules` – bandwidth shaping rules applied at boot (`fk-throttle.service`).
- `logs/` – consolidated log output, recon transcripts, detector headers.
- `backups/` – archive location for `fk-backup.sh` outputs.

Use the Settings/Security module (option 16) to toggle remote-fetch guard, manage pinning, and display firewall summaries.

## Firewall Management
FlashKidd detects `ufw`, `nftables`, or `iptables` and maintains a dedicated rule set for declared service ports. The Port Manager rewrites `/etc/fk-ssh/ports.env`, revalidates availability, applies rules, and prints a summary.

## Backup & Restore
- `fk-backup.sh` creates archives (`/etc/fk-ssh/backups/fk-ssh-<timestamp>.tar.gz`) including ports, settings, V2Ray/OpenVPN/WireGuard state, and banners.
- `fk-restore.sh` restores from an archive, reloads systemd units, and restarts SSH/V2Ray/OpenVPN/WireGuard with safeguards.

## Uninstall
```
systemctl disable --now fk-throttle.service fk-v2ray.service
rm -f /usr/local/bin/fk-*
rm -rf /etc/fk-ssh /etc/v2ray /etc/openvpn /etc/wireguard
# Optionally remove generated PKI, backups, and logs
```

## Security Notes
- Change default ports via the Port Manager and restrict access using the built-in firewall reconciliation.
- Set `FK_DISABLE_REMOTE_FETCH=1` to block remote downloads in scripted environments.
- Pin third-party binaries (`FK_PIN_V2RAY_VERSION`, `FK_PIN_V2RAY_SHA256`) before enabling service updates.
- Disable password authentication once SSH keys are deployed (`/etc/ssh/sshd_config`).
- Verify checksums of any downloaded artifacts using the Settings module (`Verify binary checksums`).

## Appendix – Legal Warning
The FlashKidd Fronting Detector performs active network requests that may be interpreted as probing. Only use it on systems and domains you own or where you have explicit authorization. The authors and maintainers assume no liability for misuse.

## License
Licensed under the [GNU General Public License v3.0 or later](LICENSE).
