# Deploying dcrmapper on a VPS

This guide walks through a production deployment on a fresh Linux VPS
(Ubuntu 24.04 LTS "Noble" or Debian 13 "Trixie"). The app runs as a plain Go
binary behind [Caddy](https://caddyserver.com/), which reverse-proxies it and
provisions TLS automatically.

**Architecture**

```
            (TLS, auto)            (HTTP, loopback)
Internet ───────────►  Caddy  ──────────────────►  dcrmapper
:443                   :443                         127.0.0.1:8111
                                                        │ outbound
                                                        ├──► Decred P2P (clearnet crawl)
                                                        ├──► ip-api.com (geolocation)
                                                        │
                                                        ▼ onion peers
                                                   arti  (SOCKS5 127.0.0.1:9150)
                                                        │
                                                        ▼
                                                   Decred P2P over Tor (v3 .onion)
```

The crawler makes many outbound TCP connections to peers on the Decred P2P port
(9108 mainnet / 19108 testnet) and HTTP requests to `ip-api.com`. To reach peers
that are only reachable as Tor **v3 .onion** services, it dials through a local
[arti](https://gitlab.torproject.org/tpo/core/arti) SOCKS5 proxy (the Tor
Project's Rust client), which `deploy.sh` installs and runs by default. arti
makes only outbound Tor connections; like the rest of the crawler it needs no
inbound access. The site itself only needs inbound `80`/`443`.

Why Caddy: HTTPS is automatic — it obtains and renews Let's Encrypt certificates
on its own, redirects HTTP→HTTPS, and enables HTTP/2 and modern TLS defaults
with a two-line config. No certbot, no cron, no manual renewal.

---

## Quick start (automated)

The repository ships a [`deploy.sh`](deploy.sh) that performs every step in this
guide. On a fresh VPS, as root:

```sh
git clone https://github.com/jzbz/map.dcr.pw
sudo ./map.dcr.pw/deploy.sh --domain map.example.com
```

It installs Go and Caddy, builds the app, and starts it as a hardened systemd
service behind Caddy with automatic HTTPS. The script is idempotent, so **running
it again upgrades an existing install**: it force-syncs the checkout to the
latest remote commit, rebuilds, and only swaps the new binary into place if the
build succeeds — a broken build never takes down the running service. (The
force-sync discards any local edits to tracked files in the checkout.) Useful
flags:

| Flag | Effect |
| --- | --- |
| `--domain <host>` | Domain to serve; Caddy provisions a TLS certificate for it. |
| `--http` | Serve plain HTTP on `:80` (no domain needed) — handy for testing. |
| `--testnet` | Crawl testnet instead of mainnet. |
| `--no-onion` | Disable Tor support (skip building and running arti). |
| `--onion-seed <list>` | Comma-separated v3 `.onion` bootstrap peers to probe. |
| `--go-version <v>` | Override the Go toolchain version (default `1.27.1`). |

**Onion support is on by default.** The script builds [arti](https://gitlab.torproject.org/tpo/core/arti)
and runs it as a local SOCKS proxy so the crawler can reach Tor v3 `.onion`
peers. Compiling arti from source is the one heavy step — it pulls in a Rust
toolchain and wants headroom to build (see [§1](#1-provision-the-server)). If you
don't need onion crawling, pass `--no-onion` to skip it entirely.

Run `./deploy.sh --help` for the full list. The rest of this document explains
what the script does, for manual setups or customization.

---

## 1. Provision the server

A small instance is plenty to **run** the app: **1 vCPU / 1 GB RAM / 10 GB
disk**. Note that **building arti** (for onion support, on by default) is
memory-hungry — on a 1 GB box `deploy.sh` drops to a single build job and the
compile is slow, and very small instances may need swap to finish it. If that's
a concern, build on a **2 GB** instance, or deploy with `--no-onion`. The arti
*runtime* itself is light. Point your domain's `A`/`AAAA` DNS records at the VPS
before starting (Caddy needs them resolving to issue a certificate).

SSH in as a sudo-capable user and update the base system:

```sh
sudo apt update && sudo apt upgrade -y
sudo apt install -y git ufw curl gnupg
```

Configure a basic firewall (allow SSH + web):

```sh
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

---

## 2. Install Go

dcrmapper targets the Go version in `go.mod` (currently **1.27.x**). Distro
packages are often older, so install the official toolchain:

```sh
GO_VERSION=1.27.1
curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
export PATH=$PATH:/usr/local/go/bin
go version
```

> On `arm64` hosts swap `linux-amd64` for `linux-arm64`.

---

## 3. Install Caddy

Install from the official Cloudsmith apt repository so it stays up to date and
ships with a ready-made systemd service:

```sh
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

This installs and starts a `caddy` systemd service that reads
`/etc/caddy/Caddyfile`. We configure it in [§8](#8-reverse-proxy--automatic-https-with-caddy).

---

## 4. Create a service user

Run the app as an unprivileged, no-login system user. Its home directory is
where the crawler persists its node cache (`~/.dcrmapper/<network>/nodes.json`).

```sh
sudo useradd --system --create-home --home-dir /opt/dcrmapper --shell /usr/sbin/nologin dcrmapper
```

---

## 5. Build the application

Clone and compile into the service user's directory:

```sh
sudo git clone https://github.com/jzbz/map.dcr.pw /opt/dcrmapper/app
cd /opt/dcrmapper/app
sudo /usr/local/go/bin/go build -o /opt/dcrmapper/app/dcrmapper .
sudo chown -R dcrmapper:dcrmapper /opt/dcrmapper
```

The templates and static assets are **embedded into the binary** at build time
(`go:embed`), so the compiled `dcrmapper` is self-contained and can run from any
working directory. (The systemd unit below still sets `WorkingDirectory`, which
is harmless.)

The UI uses a single hand-authored stylesheet (`public/css/app.css`) — no CSS
framework and **no build step of any kind** beyond `go build`. The whole deploy
is just compiling the Go binary.

---

## 6. Build and run arti (Tor proxy)

Onion support relies on a local Tor client exposing a SOCKS5 proxy. We use
[arti](https://gitlab.torproject.org/tpo/core/arti), the Tor Project's Rust
implementation. It has no official prebuilt packages yet, so build it from
source. *(Skip this whole section if you don't want onion crawling.)*

Install a Rust toolchain and the build dependencies, then compile arti:

```sh
# libssl-dev is required: arti's default native-tls backend links system OpenSSL.
sudo apt install -y build-essential pkg-config libssl-dev libsqlite3-dev
# Rust toolchain, kept out of /root so it can be reused on upgrades.
export RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --no-modify-path
# On a 1 GB host, cap the build to one job so it doesn't run out of memory.
export CARGO_BUILD_JOBS=1
/opt/rust/cargo/bin/cargo install --locked --root /usr/local arti
arti --version
```

This compiles many crates and can take several minutes (longer single-threaded).
The result is `/usr/local/bin/arti`.

Run arti as its own hardened, no-login service. It keeps Tor state under
`/var/lib/arti` and listens for SOCKS only on loopback:

```sh
sudo useradd --system --home-dir /var/lib/arti --shell /usr/sbin/nologin arti
sudo tee /etc/systemd/system/arti.service >/dev/null <<'EOF'
[Unit]
Description=arti - Tor client (SOCKS proxy for onion crawling)
After=network-online.target
Wants=network-online.target

[Service]
User=arti
Group=arti
Environment=HOME=/var/lib/arti
StateDirectory=arti
ExecStart=/usr/local/bin/arti proxy -p 9150
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

sudo systemctl daemon-reload
sudo systemctl enable --now arti
journalctl -u arti -f      # watch the first Tor bootstrap (~30-60s)
```

arti now offers a SOCKS5 proxy at `127.0.0.1:9150`. The crawler is pointed at it
with `-proxy 127.0.0.1:9150` in the next step; onion peers are dialed through it
while clearnet peers keep being dialed directly.

---

## 7. Run it as a systemd service

Create the unit file:

```sh
sudo tee /etc/systemd/system/dcrmapper.service >/dev/null <<'EOF'
[Unit]
Description=dcrmapper - Decred network world map
After=network-online.target
Wants=network-online.target
# Prefer (but don't require) arti so it starts first; the crawl still runs if
# arti is down — only onion dials need it. Omit these two lines with --no-onion.
After=arti.service
Wants=arti.service

[Service]
User=dcrmapper
Group=dcrmapper
WorkingDirectory=/opt/dcrmapper/app
ExecStart=/opt/dcrmapper/app/dcrmapper -listen 127.0.0.1:8111 -domain map.example.com -proxy 127.0.0.1:9150
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
# Allow writing only the node cache under the service user's home.
ReadWritePaths=/opt/dcrmapper

[Install]
WantedBy=multi-user.target
EOF
```

Replace `map.example.com` with your domain (the `-domain` flag sets the cookie
domain used by the theme switcher). Add `-testnet` to `ExecStart` to crawl
testnet instead of mainnet.

The `-proxy 127.0.0.1:9150` flag points the crawler at arti (from
[§6](#6-build-and-run-arti-tor-proxy)) for onion peers. To bootstrap specific
onion nodes to probe, append `-onion-seed <addr1>,<addr2>` (each a v3 `.onion`,
optionally with `:port`). If you skipped arti, drop `-proxy` from `ExecStart`
and the two `arti.service` lines from `[Unit]`.

Enable and start:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now dcrmapper
sudo systemctl status dcrmapper
journalctl -u dcrmapper -f      # watch the crawl logs
```

You should see lines like `Listening on 127.0.0.1:8111` and
`Done checking N addresses, M good`. The web server starts immediately; the map
fills in over the first few minutes as nodes are contacted and geolocated.

---

## 8. Reverse proxy + automatic HTTPS with Caddy

Replace the default Caddyfile with one that proxies your domain to the app.
Caddy obtains and renews the TLS certificate automatically the first time it
serves the site:

```sh
sudo tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
map.example.com {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8111

	# Cache the static assets aggressively.
	@assets path /public/*
	header @assets Cache-Control "public, max-age=604800"
}
EOF
```

> Caddyfiles use **tabs** for indentation. The heredoc above preserves them.

Replace `map.example.com` with your domain, then validate and reload:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
journalctl -u caddy -f      # watch certificate issuance
```

Within a few seconds Caddy provisions a Let's Encrypt certificate and your site
is live at `https://map.example.com`, with HTTP automatically redirecting to
HTTPS. Renewal is handled in the background for as long as the service runs —
there is nothing else to schedule.

> **For a quick test without a domain**, replace the first line of the Caddyfile
> with `:80` (plain HTTP, no TLS) and browse to the server's IP.

---

## 9. Updating to a new version

```sh
cd /opt/dcrmapper/app
sudo -u dcrmapper git pull
sudo /usr/local/go/bin/go build -o /opt/dcrmapper/app/dcrmapper .
sudo systemctl restart dcrmapper
```

The node cache in `/opt/dcrmapper/.dcrmapper/` persists across restarts, so the
map repopulates almost instantly after an update. arti is independent and keeps
running across dcrmapper updates; it only needs attention if you want a newer
arti (`cargo install --locked --root /usr/local arti` again, then
`sudo systemctl restart arti`).

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `502 Bad Gateway` | Is the app up? `systemctl status dcrmapper`. Is it listening on `127.0.0.1:8111`? `ss -ltnp \| grep 8111`. |
| TLS certificate not issued | DNS must resolve to this host and ports 80+443 must be open. Watch `journalctl -u caddy -f` for ACME errors. |
| Blank page / missing styles | The app must run with `WorkingDirectory=/opt/dcrmapper/app` so `templates/` and `public/` resolve. |
| Map never populates | The crawler needs **outbound** network access. Confirm the host can reach peers and `ip-api.com`; watch `journalctl -u dcrmapper`. |
| `Hit ip-api rate limit` in logs | Normal — the free ip-api tier is rate-limited; the crawler backs off and retries automatically. |
| Theme switcher doesn't persist | Make sure `-domain` matches the domain you serve from. |
| arti build fails / killed (OOM) | The Rust compile needs RAM. Add swap, build on a 2 GB instance, or deploy with `--no-onion`. On 1 GB `deploy.sh` already limits it to one job. |
| arti build: `openssl-sys` / "Could not find openssl" | Install the OpenSSL dev package: `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL). `deploy.sh` installs `libssl-dev` automatically; this only bites manual builds. |
| Onion dials time out in logs | arti is probably still bootstrapping (first run takes ~30-60s) or not running. `systemctl status arti`; confirm SOCKS is up: `ss -ltnp \| grep 9150`. Clearnet crawling is unaffected. |
| No onion nodes ever appear | Expected for now: the crawler can only *probe* onion peers you seed with `-onion-seed`, and few/none exist publicly yet. Automatic discovery needs a Decred protocol upgrade (addrv2) that isn't in released nodes. Verify arti with `journalctl -u arti`. |
