# path: install.sh
#!/usr/bin/env bash
# FlashKidd SSH Manager — Installer
# Safe, idempotent, and works when piped via curl | bash or run from a cloned repo.

set -euo pipefail

# ------------------------- Safe script path handling -------------------------
# When run via stdin (curl | bash), BASH_SOURCE[0] may be unset with `set -u`.
: "${BASH_SOURCE[0]:=${0:-}}"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ -n "${SCRIPT_SOURCE}" && "${SCRIPT_SOURCE}" != "-" && -f "${SCRIPT_SOURCE}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${SCRIPT_SOURCE}")" >/dev/null 2>&1 && pwd -P)"
else
  # stdin mode: start in current directory, may download archive later
  REPO_ROOT="$(pwd -P)"
fi

# ------------------------------- Defaults -----------------------------------
CONFIG_DIR="/etc/fk-ssh"
LOG_DIR="${CONFIG_DIR}/logs"
BACKUP_DIR="${CONFIG_DIR}/backups"
SYMLINK_DIR="/usr/local/bin"

DRY_RUN=0
AUTO_MODE=0
CHANNEL="stable"

# When run outside a repo, we fetch the repo tarball. These can be overridden
# by env if you later pin to a specific commit + checksum.
ARCHIVE_REF="${FK_INSTALL_REF:-main}"
ARCHIVE_SHA256="${FK_INSTALL_SHA256:-}"  # optional; if set, will be verified

# ------------------------------- Helpers ------------------------------------
print_step(){ printf '==> %s\n' "$1"; }
print_warn(){ printf 'WARN: %s\n' "$1" >&2; }
die(){ printf 'ERROR: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
FlashKidd SSH Manager — installer

Usage: install.sh [--auto] [--dry-run] [--channel <name>] [--help]

Options:
  --auto           Non-interactive; accept defaults (still prompts for ports if missing)
  --dry-run        Show actions without changing the system
  --channel NAME   Persist FK_CHANNEL=NAME in /etc/fk-ssh/settings.env (default: stable)
  --help           Show this help
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)    AUTO_MODE=1; shift;;
      --dry-run) DRY_RUN=1; shift;;
      --channel) CHANNEL="${2:-}"; [[ -n "$CHANNEL" ]] || die "--channel requires a value"; shift 2;;
      --help|-h) usage; exit 0;;
      *) usage; die "Unknown option: $1";;
    esac
  done
}

run_or_echo() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    eval "$@"
  fi
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This installer must be run as root (use sudo)."
  fi
}

# --------------------------- Repo acquisition -------------------------------
TEMP_ARCHIVE_DIR=""
cleanup_temp(){ [[ -n "$TEMP_ARCHIVE_DIR" ]] && [[ -d "$TEMP_ARCHIVE_DIR" ]] && rm -rf "$TEMP_ARCHIVE_DIR"; }
download_repo_archive() {
  TEMP_ARCHIVE_DIR="$(mktemp -d)"
  trap cleanup_temp EXIT

  local url="https://github.com/FlashKidd/flashkidd-ssh-manager/archive/${ARCHIVE_REF}.tar.gz"
  local archive="${TEMP_ARCHIVE_DIR}/repo.tar.gz"

  print_step "Fetching repository (${ARCHIVE_REF})"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] curl -fsSL %q -o %q\n' "$url" "$archive"
    [[ -n "$ARCHIVE_SHA256" ]] && printf '[dry-run] echo "%s  %s" | sha256sum -c -\n' "$ARCHIVE_SHA256" "$archive"
    printf '[dry-run] tar -xzf %q -C %q\n' "$archive" "$TEMP_ARCHIVE_DIR"
    REPO_ROOT="${TEMP_ARCHIVE_DIR}/flashkidd-ssh-manager-${ARCHIVE_REF}"
    return
  fi

  curl -fsSL "$url" -o "$archive" || die "Download failed: $url"

  if [[ -n "$ARCHIVE_SHA256" ]]; then
    echo "${ARCHIVE_SHA256}  ${archive}" | sha256sum -c - >/dev/null 2>&1 || die "Archive checksum verification failed"
  fi

  tar -xzf "$archive" -C "$TEMP_ARCHIVE_DIR" || die "Failed to extract archive"
  local extracted
  extracted="$(find "$TEMP_ARCHIVE_DIR" -maxdepth 1 -mindepth 1 -type d -name 'flashkidd-ssh-manager*' | head -n1)"
  [[ -n "$extracted" ]] || die "Extracted repo directory not found"
  REPO_ROOT="$extracted"
}

ensure_repo_root() {
  # If bin/ exists here, assume we are in the repo; otherwise fetch.
  if [[ -d "${REPO_ROOT}/bin" ]]; then
    return
  fi
  download_repo_archive
}

# ----------------------------- System changes -------------------------------
install_packages() {
  local pkgs=(
    openssh-server curl jq coreutils iproute2 nftables iptables ufw
    openvpn wireguard-tools nginx openssl tar xz-utils dnsutils netcat-openbsd
    qrencode
  )
  print_step "Installing dependencies (apt)"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] apt-get update -y"
    echo "[dry-run] DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]}"
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  else
    print_warn "apt-get not found; please install dependencies manually."
  fi
}

create_dirs_and_init() {
  print_step "Preparing directories under ${CONFIG_DIR}"
  local d
  for d in "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "${CONFIG_DIR}/templates"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '[dry-run] mkdir -p %s\n' "$d"
    else
      mkdir -p "$d"
    fi
  done

  # Copy *.example to live (if missing)
  local ex dest
  for ex in "ports.env" "settings.env"; do
    local src="${REPO_ROOT}/etc/fk-ssh/${ex}.example"
    dest="${CONFIG_DIR}/${ex}"
    if [[ -f "$dest" ]]; then
      continue
    fi
    if [[ -f "$src" ]]; then
      print_step "Initializing ${dest}"
      if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] cp %s %s && chmod 600 %s\n' "$src" "$dest" "$dest"
      else
        cp "$src" "$dest"
        chmod 600 "$dest"
      fi
    else
      print_warn "Missing example file in repo: $src"
    fi
  done

  # Template docs example
  local tsrc="${REPO_ROOT}/etc/fk-ssh/templates/detect-docs.md.example"
  if [[ -f "$tsrc" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '[dry-run] cp %s %s/\n' "$tsrc" "${CONFIG_DIR}/templates"
    else
      cp "$tsrc" "${CONFIG_DIR}/templates/"
    fi
  fi
}

write_channel() {
  local dest="${CONFIG_DIR}/settings.env"
  print_step "Setting FK_CHANNEL=${CHANNEL}"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] ensure FK_CHANNEL in %s\n' "$dest"
    return
  fi
  touch "$dest"
  if grep -q '^FK_CHANNEL=' "$dest" 2>/dev/null; then
    sed -i "s/^FK_CHANNEL=.*/FK_CHANNEL=${CHANNEL}/" "$dest"
  else
    printf '\nFK_CHANNEL=%s\n' "$CHANNEL" >> "$dest"
  fi
  chmod 600 "$dest"
}

port_in_use() {
  local port="$1"
  ss -lntup 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -qx "$port"
}

prompt_ports_if_needed() {
  local ports_file="${CONFIG_DIR}/ports.env"
  if [[ -s "$ports_file" ]]; then
    return
  fi

  print_step "Configuring service ports (press Enter to accept defaults)"

  declare -A defaults=(
    [SSH_PORT_PRIMARY]=22
    [SSH_PORT_SECONDARY]=80
    [SSH_TLS_PORT]=443
    [SQUID_PORTS]='8080 3128 90'
    [V2RAY_VMESS_TCP]=10086
    [V2RAY_VMESS_WS]=80
    [V2RAY_VMESS_TLS]=443
    [V2RAY_VLESS_TLS]=443
    [OPENVPN_UDP]=1194
    [OPENVPN_TCP]=443
    [WIREGUARD_UDP]=51820
    [WEBSOCKET_SSH_PORTS]='80 443'
  )

  if [[ $DRY_RUN -eq 1 ]]; then
    for k in "${!defaults[@]}"; do
      printf '[dry-run] would set %s="%s"\n' "$k" "${defaults[$k]}"
    done
    return
  fi

  : > "$ports_file"
  for k in "${!defaults[@]}"; do
    local def="${defaults[$k]}" val
    if [[ $AUTO_MODE -eq 1 ]]; then
      val="$def"
    else
      read -rp "$k [$def]: " val || true
      val="${val:-$def}"
    fi

    # Validate numeric single ports (not space lists)
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      if port_in_use "$val"; then
        print_warn "Port $val appears to be in use. Choose another."
        read -rp "$k [choose another]: " val || true
        [[ -z "$val" ]] && val="$def"
      fi
    fi

    printf '%s="%s"\n' "$k" "$val" >> "$ports_file"
  done
  chmod 600 "$ports_file"
}

create_symlinks() {
  print_step "Linking executables to ${SYMLINK_DIR}"
  local bin_dir="${REPO_ROOT}/bin"
  if [[ ! -d "$bin_dir" ]]; then
    print_warn "Repository bin/ not found at ${bin_dir}; skipping symlinks."
    return
  fi

  local script name dest
  for script in "${bin_dir}"/fk-*; do
    [[ -f "$script" ]] || continue
    name="$(basename "$script")"
    dest="${SYMLINK_DIR}/${name}"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '[dry-run] ln -sf %s %s && chmod +x %s\n' "$script" "$dest" "$script"
      continue
    fi
    ln -sf "$script" "$dest"
    chmod +x "$script"
  done
}

# ------------------------------- Main flow ----------------------------------
main() {
  parse_args "$@"
  ensure_root

  # Make sure we have the repo contents
  ensure_repo_root

  create_dirs_and_init
  write_channel
  prompt_ports_if_needed
  install_packages
  create_symlinks

  print_step "Installation complete."
  # REQUIRED exact final line:
  echo 'Run: fk-ssh'
}

main "$@"
