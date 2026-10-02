#!/usr/bin/env bash
#
# deploy.sh — provision dcrmapper on a fresh Debian 13 / Ubuntu 24.04 LTS VPS.
#
# Installs Go, Caddy (automatic HTTPS), builds the app, and runs it as a
# hardened systemd service behind Caddy. Safe to re-run: every step is
# idempotent, so this doubles as an updater.
#
# Usage (run as root or with sudo):
#   sudo ./deploy.sh --domain map.example.com
#   sudo ./deploy.sh --domain map.example.com --testnet
#   sudo ./deploy.sh --http                 # no domain: serve plain HTTP on :80
#
# Options:
#   --domain <host>   Domain to serve (Caddy provisions a TLS cert for it).
#   --http            Serve plain HTTP on :80 instead of HTTPS (for testing).
#   --testnet         Crawl testnet instead of mainnet.
#   --no-onion        Disable Tor support (skip building/running arti).
#   --onion-seed <l>  Comma-separated v3 .onion bootstrap peers to probe.
#   --go-version <v>  Go toolchain version to install   (default: 1.27.1).
#   --repo <url>      Git repository to deploy.
#   --listen <addr>   Internal listen address           (default: 127.0.0.1:8111).
#   -h, --help        Show this help.
#
# Onion support is ON by default: the script builds arti (the Tor Project's Rust
# client) and runs it as a local SOCKS proxy so the crawler can reach v3 .onion
# peers. Use --no-onion to skip it.
#
set -euo pipefail

# ---- Configuration --------------------------------------------------------

GO_VERSION="1.27.1"
REPO_URL="https://github.com/jzbz/dcrmapper"
SERVICE_USER="dcrmapper"
APP_HOME="/opt/dcrmapper"
APP_DIR="${APP_HOME}/app"
LISTEN="127.0.0.1:8111"
DOMAIN=""
HTTP_ONLY=0
TESTNET=0
ONION=1
ONION_SEED=""
# Loopback SOCKS5 endpoint arti listens on and dcrmapper dials for onion peers.
ARTI_SOCKS="127.0.0.1:9150"
# Where the Rust toolchain used to build arti is kept (out of /root).
RUST_HOME="/opt/rust"

# ---- Logging --------------------------------------------------------------

if [[ -t 1 ]]; then
  C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
else
  C_BLUE=""; C_GREEN=""; C_RED=""; C_DIM=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Print the header comment block (everything after the shebang up to the first
# non-comment line) as usage text.
usage() {
  local line
  while IFS= read -r line; do
    case "$line" in
      '#!'*) continue ;;
      '# '*) printf '%s\n' "${line#'# '}" ;;
      '#')   printf '\n' ;;
      '#'*)  printf '%s\n' "${line#'#'}" ;;
      *)     break ;;
    esac
  done < "$0"
  exit "${1:-0}"
}

# ---- Argument parsing -----------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    --http)       HTTP_ONLY=1; shift ;;
    --testnet)    TESTNET=1; shift ;;
    --no-onion)   ONION=0; shift ;;
    --onion-seed) ONION_SEED="${2:?--onion-seed needs a value}"; shift 2 ;;
    --go-version) GO_VERSION="${2:?--go-version needs a value}"; shift 2 ;;
    --repo)       REPO_URL="${2:?--repo needs a value}"; shift 2 ;;
    --listen)     LISTEN="${2:?--listen needs a value}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *)            warn "unknown option: $1"; usage 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 ...)"
if [[ $HTTP_ONLY -eq 0 && -z "$DOMAIN" ]]; then
  die "provide --domain <host>, or --http to serve plain HTTP for testing"
fi

# Cookie domain for the theme switcher; harmless when serving plain HTTP.
COOKIE_DOMAIN="${DOMAIN:-localhost}"
NETWORK="mainnet"; [[ $TESTNET -eq 1 ]] && NETWORK="testnet"

# ---- 1. Base packages -----------------------------------------------------

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git ufw curl gnupg ca-certificates >/dev/null
ok "git, ufw, curl, gnupg installed"

# ---- 2. Firewall ----------------------------------------------------------

log "Configuring firewall (ufw)"
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ok "SSH, 80/tcp and 443/tcp allowed"

# ---- 3. Go toolchain ------------------------------------------------------

case "$(uname -m)" in
  x86_64|amd64)  GO_ARCH="amd64" ;;
  aarch64|arm64) GO_ARCH="arm64" ;;
  *)             die "unsupported CPU architecture: $(uname -m)" ;;
esac

if /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
  ok "Go ${GO_VERSION} already installed"
else
  log "Installing Go ${GO_VERSION} (${GO_ARCH})"
  tmp="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "${tmp}/go.tar.gz"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmp}/go.tar.gz"
  rm -rf "$tmp"
  # $PATH must stay literal so it expands at login, not now.
  # shellcheck disable=SC2016
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
  ok "Go installed: $(/usr/local/go/bin/go version)"
fi
GO=/usr/local/go/bin/go

# ---- 4. Caddy -------------------------------------------------------------

if command -v caddy >/dev/null 2>&1; then
  ok "Caddy already installed ($(caddy version | head -1))"
else
  log "Installing Caddy from the official apt repository"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  ok "Caddy installed ($(caddy version | head -1))"
fi

# ---- 5. Tor proxy (arti) --------------------------------------------------
#
# arti is the Tor Project's Rust client. We run it as a loopback SOCKS5 proxy so
# the crawler can reach v3 .onion peers; it only makes outbound Tor connections
# and exposes nothing to the internet. arti has no official prebuilt packages
# yet, so it is compiled from source with a Rust toolchain — the heaviest step
# of this script. Skipped entirely with --no-onion.

if [[ $ONION -eq 1 ]]; then
  if [[ -x /usr/local/bin/arti ]]; then
    ok "arti already installed ($(/usr/local/bin/arti --version 2>/dev/null | head -1))"
  else
    log "Installing build dependencies for arti"
    # libssl-dev: arti's default native-tls backend links the system OpenSSL
    # via openssl-sys, which needs the dev headers and openssl.pc.
    apt-get install -y -qq build-essential pkg-config libssl-dev libsqlite3-dev >/dev/null
    ok "build-essential, pkg-config, libssl-dev, libsqlite3-dev installed"

    log "Installing Rust toolchain (to build arti)"
    export RUSTUP_HOME="${RUST_HOME}/rustup"
    export CARGO_HOME="${RUST_HOME}/cargo"
    if [[ ! -x "${CARGO_HOME}/bin/cargo" ]]; then
      curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --no-modify-path
    fi
    ok "Rust ready ($(${CARGO_HOME}/bin/cargo --version))"

    # Cap build parallelism on low-memory hosts so the compile does not OOM.
    # arti pulls in hundreds of crates; on 1 GB a single job is the safe choice.
    MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    if [[ "${MEM_KB:-0}" -lt 2097152 ]]; then
      export CARGO_BUILD_JOBS=1
      warn "Under 2 GB RAM: building arti single-threaded (slow). Add swap if it stalls."
    fi

    log "Building arti from source — this can take several minutes"
    "${CARGO_HOME}/bin/cargo" install --locked --root /usr/local arti
    ok "arti installed ($(/usr/local/bin/arti --version | head -1))"
  fi

  if id arti >/dev/null 2>&1; then
    ok "arti service user exists"
  else
    useradd --system --home-dir /var/lib/arti --shell /usr/sbin/nologin arti
    ok "created arti service user"
  fi

  log "Writing arti systemd unit"
  cat > /etc/systemd/system/arti.service <<EOF
[Unit]
Description=arti - Tor client (SOCKS proxy for onion crawling)
After=network-online.target
Wants=network-online.target

[Service]
User=arti
Group=arti
# StateDirectory grants writable /var/lib/arti; HOME points arti's state and
# cache there (its XDG dirs land under \$HOME).
Environment=HOME=/var/lib/arti
StateDirectory=arti
ExecStart=/usr/local/bin/arti proxy -p ${ARTI_SOCKS##*:}
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable arti >/dev/null 2>&1 || true
  systemctl restart arti
  ok "arti running (SOCKS5 on ${ARTI_SOCKS}); first Tor bootstrap takes ~30-60s"
else
  log "Onion support disabled (--no-onion); skipping arti"
fi

# ---- 6. Service user ------------------------------------------------------

if id "$SERVICE_USER" >/dev/null 2>&1; then
  ok "Service user '${SERVICE_USER}' exists"
else
  log "Creating service user '${SERVICE_USER}'"
  useradd --system --create-home --home-dir "$APP_HOME" \
    --shell /usr/sbin/nologin "$SERVICE_USER"
  ok "Created ${SERVICE_USER} (home: ${APP_HOME})"
fi

# ---- 7. Fetch & build -----------------------------------------------------

if [[ -d "${APP_DIR}/.git" ]]; then
  ACTION="upgrade"
  log "Updating existing checkout (force-syncing to remote; local edits to tracked files are discarded)"
  sudo -u "$SERVICE_USER" git -C "$APP_DIR" fetch --depth 1 origin
  sudo -u "$SERVICE_USER" git -C "$APP_DIR" reset --hard '@{u}'
else
  ACTION="install"
  log "Cloning ${REPO_URL}"
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$APP_HOME"
fi

# Build into a temporary file next to the live binary. It is swapped into place
# atomically in the next step, *after* a successful build — so a broken build
# can never take down a running service, and the swap has no partial-file window
# (rename(2) on the same filesystem is atomic).
#
# -buildvcs=false: the build runs as root while the checkout is owned by the
# service user, so Go's VCS stamping would invoke git in a repo git considers
# "dubiously owned" and fail. We don't need the revision stamped into the binary.
log "Building dcrmapper"
( cd "$APP_DIR" && GOTOOLCHAIN=local "$GO" build -buildvcs=false -o "${APP_DIR}/dcrmapper.new" . )
chown "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}/dcrmapper.new"
ok "Build succeeded"

# ---- 8. systemd service ---------------------------------------------------

log "Writing systemd unit"
EXEC="${APP_DIR}/dcrmapper -listen ${LISTEN} -domain ${COOKIE_DOMAIN}"
[[ $TESTNET -eq 1 ]] && EXEC="${EXEC} -testnet"

# When onion support is on, point the crawler at arti's SOCKS proxy and make the
# unit prefer (but not require) arti so it starts first. The crawl still works if
# arti is down — only onion dials need it.
ARTI_UNIT_DEPS=""
if [[ $ONION -eq 1 ]]; then
  EXEC="${EXEC} -proxy ${ARTI_SOCKS}"
  [[ -n "$ONION_SEED" ]] && EXEC="${EXEC} -onion-seed ${ONION_SEED}"
  ARTI_UNIT_DEPS=$'After=arti.service\nWants=arti.service'
fi

cat > /etc/systemd/system/dcrmapper.service <<EOF
[Unit]
Description=dcrmapper - Decred network world map
After=network-online.target
Wants=network-online.target
${ARTI_UNIT_DEPS}

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${EXEC}
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${APP_HOME}

[Install]
WantedBy=multi-user.target
EOF

# Atomically swap in the new binary, then (re)start. mv is a rename(2) within the
# same directory, so it replaces the file even while the old binary is executing;
# the running process keeps the old inode until the restart execs the new one.
mv -f "${APP_DIR}/dcrmapper.new" "${APP_DIR}/dcrmapper"

systemctl daemon-reload
systemctl enable dcrmapper >/dev/null 2>&1 || true
systemctl restart dcrmapper
ok "dcrmapper service running (network: ${NETWORK})"

# ---- 9. Caddy reverse proxy ----------------------------------------------

log "Writing Caddyfile"
if [[ $HTTP_ONLY -eq 1 ]]; then
  SITE=":80"
else
  SITE="$DOMAIN"
fi

# Tabs are required for Caddyfile block indentation.
cat > /etc/caddy/Caddyfile <<EOF
${SITE} {
	encode zstd gzip
	reverse_proxy ${LISTEN}

	@assets path /public/*
	header @assets Cache-Control "public, max-age=604800"
}
EOF

caddy validate --config /etc/caddy/Caddyfile >/dev/null
systemctl reload caddy
ok "Caddy configured for ${SITE}"

# ---- Done -----------------------------------------------------------------

echo
if [[ "$ACTION" == "upgrade" ]]; then
  ok "Upgrade complete — dcrmapper rebuilt and restarted."
else
  ok "Deployment complete."
fi
if [[ $HTTP_ONLY -eq 1 ]]; then
  IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || echo '<server-ip>')"
  echo "   ${C_DIM}Site:${C_OFF}  http://${IP}/"
else
  echo "   ${C_DIM}Site:${C_OFF}  https://${DOMAIN}/   ${C_DIM}(TLS provisions on first request)${C_OFF}"
fi
cat <<EOF
   ${C_DIM}Logs:${C_OFF}  journalctl -u dcrmapper -f
   ${C_DIM}Caddy:${C_OFF} journalctl -u caddy -f
EOF
[[ $ONION -eq 1 ]] && printf '   %sarti:%s  journalctl -u arti -f\n' "$C_DIM" "$C_OFF"
cat <<EOF

The map fills in over the first few minutes as nodes are crawled and geolocated.
EOF
