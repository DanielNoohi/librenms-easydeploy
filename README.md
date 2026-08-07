# LibreNMS EasyDeploy

[![CI](https://github.com/DanielNoohi/librenms-easydeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielNoohi/librenms-easydeploy/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![LibreNMS](https://img.shields.io/badge/LibreNMS-26.7.0-0B3D2E)](https://www.librenms.org/)

```text
  ┌─────────────────────────────────────────────────────────┐
  │  one script  →  secrets  →  compose  →  admin ready     │
  │                                                         │
  │   librenms · dispatcher · mariadb · redis               │
  │   syslog · snmp traps · optional Caddy TLS · msmtpd     │
  └─────────────────────────────────────────────────────────┘
```

**Network monitoring without the wiring tax.**  
Drop a full LibreNMS stack on a single Linux host — auto-discovery, SNMP, topology, graphs, syslog, traps, and alerting — with credentials generated for you, optional HTTPS (Let's Encrypt or self-signed), optional SMTP relay, and CI that installs the real thing.

Built for labs, homelabs, and small single-node sites. Complements Zabbix (server/app metrics) and Lansweeper (endpoint inventory) with **network-centric visibility**.

---

## Why this exists

Official LibreNMS Docker is solid. The boring parts are still on you: secrets, Redis auth, sidecars, firewall holes, first-boot admin, TLS, mail. EasyDeploy wraps that into one reviewed installer that:

- Generates strong credentials and a locked-down `.env`
- Brings up app, dispatcher, MariaDB, Redis, syslog, and SNMP traps together
- Optionally terminates HTTPS with Caddy (Let's Encrypt or self-signed)
- Optionally relays alert mail through an `msmtpd` sidecar
- Creates the admin user and applies poller / syslog settings
- Survives reruns without wiping secrets
- Ships backup/restore/upgrade/health helpers and CI that runs the installer end-to-end

---

## Quick start

Prefer download-then-run so you can review the script first:

```bash
wget https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh
chmod +x librenms-auto-install.sh
sudo ./librenms-auto-install.sh
```

Or clone the repo (uses the local `docker-compose.yml` beside the installer):

```bash
git clone https://github.com/DanielNoohi/librenms-easydeploy.git
cd librenms-easydeploy
sudo ./librenms-auto-install.sh
```

HTTP (labs / LAN):

```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url http://librenms.example.com \
  --save-creds ~/librenms-creds.txt
```

HTTPS (public DNS + Let's Encrypt):

```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url https://nms.example.com \
  --le-email ops@example.com \
  --save-creds ~/librenms-creds.txt
```

HTTPS (labs / CI self-signed):

```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url https://localhost \
  --self-signed-tls
```

SMTP alert relay (optional):

```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url https://nms.example.com \
  --le-email ops@example.com \
  --smtp-host smtp.example.com \
  --smtp-user alerts \
  --smtp-password 'replace-me' \
  --smtp-from alerts@example.com
```

Dry-run preview:

```bash
sudo ./librenms-auto-install.sh --dry-run -n -u https://nms.example.com --le-email ops@example.com
```

When it finishes, open the URL you gave and sign in with the printed credentials.

<details>
<summary>One-liner (less reviewable)</summary>

```bash
curl -sSL https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh | sudo bash
```

</details>

---

## What you get

| Piece | Role |
|-------|------|
| **librenms** | Web UI & alerting (host `80` → `8000`, or loopback when TLS is on) |
| **dispatcher** | Distributed poller sidecar |
| **db** | MariaDB 10.11 |
| **redis** | Password-protected cache & queue |
| **syslogng** | Syslog ingest on TCP/UDP `514` |
| **snmptrapd** | Authorized SNMP traps on TCP/UDP `162` |
| **caddy** (profile `tls`) | HTTPS termination (ACME or self-signed) |
| **msmtpd** (profile `mail`) | SMTP relay for LibreNMS alert email |

Pinned image tags — no `:latest`. Memory limits on app/db/redis. Persistent data under `./data/`.

---

## Know before you install

| Topic | Reality |
|-------|---------|
| TLS | **HTTP by default.** HTTPS via Caddy when `--le-email` (public DNS + ACME) or `--self-signed-tls` (labs/CI). |
| Scope | Single-node Compose for labs / homelabs / small sites — not multi-node HA. |
| Email | Optional `msmtpd` profile via `--smtp-host`. Still configure alert rules/transports in the UI. |
| License | GPL-3.0 (LibreNMS and this repo). |

`--no-ssl` forces HTTP even if the URL is `https://`.

---

## Production posture

Checklist for a small single-node production-ish deploy:

1. Use `--url https://your.hostname --le-email you@example.com` (DNS A/AAAA must point here; ports 80/443 reachable).
2. Configure `--smtp-host` (and user/password/from) so alert mail can leave the box.
3. Enable the host firewall after reviewing rules: `sudo ufw enable`.
4. Optionally tighten Docker port publishing with [`scripts/docker-user-ufw.sh`](scripts/docker-user-ufw.sh) (`sudo ./scripts/docker-user-ufw.sh apply`).
5. Schedule [`scripts/backup.sh`](scripts/backup.sh); practice [`scripts/restore.sh`](scripts/restore.sh) on a spare host.
6. Install host log rotation: `sudo cp contrib/logrotate-librenms-easydeploy /etc/logrotate.d/librenms-easydeploy`
7. Change the admin password in the UI; keep `.env` mode `600`.
8. Prefer clone installs so you can review `docker-compose.yml` and pin upgrades deliberately.

Still not covered: multi-node HA, full CIS host hardening.

---

## Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show help |
| `-d`, `--dir` | Install directory (default: `/opt/librenms-easydeploy`) |
| `-u`, `--url` | Base URL (required for non-interactive) |
| `-t`, `--timezone` | Timezone (default: `UTC`) |
| `-p`, `--pollers` | Poller workers, 1–64 (default: `16`) |
| `-s`, `--save-creds` | Write credentials to a `chmod 600` file |
| `-n`, `--non-interactive` | No prompts (requires `--url`) |
| `-f`, `--force` | Rewrite `.env` after backup; loaded secrets are preserved |
| `-D`, `--dry-run` | Preview without changing the system |
| `--no-firewall` | Skip UFW rules |
| `--no-ssl` | Force HTTP-only (disable Caddy) |
| `--le-email EMAIL` | Enable TLS via Caddy + Let's Encrypt |
| `--self-signed-tls` | Enable TLS with Caddy internal/self-signed certs (labs/CI) |
| `--smtp-host HOST` | Enable mail profile; upstream SMTP host for msmtpd |
| `--smtp-port PORT` | Upstream SMTP port (default `587`) |
| `--smtp-user USER` | Upstream SMTP username |
| `--smtp-password PASS` | Upstream SMTP password |
| `--smtp-from EMAIL` | From address for outbound mail |
| `--emit-env FILE` | Write generated `.env` and exit (no Docker/root; for tests) |
| `--db-name` / `--db-user` | Database name/user (default: `librenms`) |

Generate an env file without installing:

```bash
./librenms-auto-install.sh -n -u http://example.com --emit-env /tmp/librenms.env
```

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │         Docker network (internal)      │
                    │                                        │
   :80/:443 ──────► │  caddy (tls profile) ──► librenms      │
   or :80 ────────► │  librenms ──► redis (auth)              │
                    │      │                                 │
   :514 ──────────► │  syslogng    dispatcher (pollers)      │
                    │      │                                 │
   :162 ──────────► │  snmptrapd ──► db (MariaDB)            │
                    └──────────────────────────────────────┘
```

When TLS is enabled, LibreNMS publishes only on loopback (`127.0.0.1:8000`) and Caddy serves `:80`/`:443`. SNMP traps and syslog remain cleartext protocols by nature.

Sidecars follow the [official LibreNMS Docker design](https://github.com/librenms/docker).

**Volumes**

| Path | Contents |
|------|----------|
| `./data/librenms` | Config, logs, plugins, RRD (`/data`) |
| `./data/db` | MariaDB |
| `./data/redis` | Redis persistence |
| `./data/caddy` | Caddyfile + ACME data (TLS installs) |

Local Compose tweaks belong in `docker-compose.override.yml`. After editing `docker-compose.yml` in this repo, refresh the embedded blob used by `curl|bash`:

```bash
python3 scripts/sync_embedded_compose.py
```

---

## Security posture

- Random passwords for DB root, DB user, Redis, and admin
- `.env` written atomically with mode `600`
- Redis requires a password on the internal network
- Optional Caddy TLS with Let's Encrypt; LibreNMS web bound to loopback when TLS is on
- SNMP trap authorization on; generated v2c/v3 credentials in `.env`
- MariaDB healthcheck via `mariadb-admin` (password via env, not process argv)
- Non-root app containers (`PUID`/`PGID` 1000)
- Compose memory limits on core services
- Reruns and `--force` keep existing secrets; config changes are backed up first
- Health checks on MariaDB, Redis, and LibreNMS

Point trap senders at `LIBRENMS_SNMP_COMMUNITY` or `SNMP_USER` / `SNMP_AUTH` / `SNMP_PRIV`. Unauthenticated trap acceptance stays off.

### Firewall

Unless you pass `--no-firewall`, the installer adds UFW allows for:

| Port | Purpose |
|------|---------|
| `80/tcp` | Web UI and/or ACME HTTP-01 |
| `443/tcp` | HTTPS (TLS installs only) |
| `162/tcp` + `162/udp` | SNMP traps |
| `514/tcp` + `514/udp` | Syslog |

It does **not** run `ufw enable` — do that yourself when ready:

```bash
sudo ufw enable
```

> Docker publishes ports through iptables and can bypass UFW. Use [`scripts/docker-user-ufw.sh`](scripts/docker-user-ufw.sh) or see [Docker and packet filtering](https://docs.docker.com/network/packet-filtering-firewalls/).

---

## Requirements

- Ubuntu 22.04 / 24.04 LTS (or any Docker-capable Linux)
- Docker Engine + Compose v2
- Python 3 and `flock` (`util-linux`)
- Root / sudo
- 4 GB RAM minimum (8 GB recommended above ~500 devices)
- Free host ports: `80/tcp` (and `443/tcp` for TLS), `162/tcp+udp`, `514/tcp+udp`
- For TLS: public DNS hostname pointing at this host

---

## Day-2 operations

### Update

```bash
cd /opt/librenms-easydeploy
sudo ./scripts/upgrade.sh
# or: sudo INSTALL_DIR=/opt/librenms-easydeploy /path/to/repo/scripts/upgrade.sh
```

The official image runs migrations on startup. With TLS/mail, `COMPOSE_PROFILES` in `.env` keeps optional sidecars included.

### Health check

```bash
cd /opt/librenms-easydeploy
sudo ./scripts/health-check.sh
```

### Backup

```bash
cd /opt/librenms-easydeploy
sudo ./scripts/backup.sh
# or: sudo INSTALL_DIR=/opt/librenms-easydeploy /path/to/repo/scripts/backup.sh
```

Creates timestamped `librenms_db_*.sql.gz` and `librenms_data_*.tar.gz` under `./backups/` (mode `700`).

### Restore

```bash
cd /opt/librenms-easydeploy
sudo ./scripts/restore.sh backups/librenms_db_YYYYMMDD_HHMMSS.sql.gz \
  backups/librenms_data_YYYYMMDD_HHMMSS.tar.gz
```

Requires typing `restore` to confirm. Stops the stack, replaces `data/`, reloads SQL, then brings services back up.

### Host log rotation

```bash
sudo cp contrib/logrotate-librenms-easydeploy /etc/logrotate.d/librenms-easydeploy
```

### Uninstall

```bash
cd /opt/librenms-easydeploy
docker compose down -v
rm -rf /opt/librenms-easydeploy
```

---

## Migrate from official LibreNMS Docker

If you already run the [official compose examples](https://github.com/librenms/docker):

1. **Backup first** — dump MariaDB and archive your LibreNMS `/data` volume.
2. **Stop the old stack** — `docker compose down` (keep volumes until you verify the new install).
3. **Install EasyDeploy** into a new directory (default `/opt/librenms-easydeploy`) with the same public URL you used before.
4. **Restore data** — copy RRD/config into `data/librenms` and import the SQL dump (or use `scripts/restore.sh` after placing archives in the expected layout).
5. **Secrets** — put the previous DB/Redis passwords into `.env` (or let the installer load them on a rerun after you place `.env`).
6. **TLS/mail** — re-apply with `--le-email` / `--smtp-host` as needed; EasyDeploy owns `docker-compose.yml` and writes Caddy/msmtpd config.
7. **Cut over DNS/firewall** only after `scripts/health-check.sh` passes.

Local Compose overrides still belong in `docker-compose.override.yml` so installer refreshes of the base file do not wipe your tweaks.

---

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Installer exits on first run at backup | Fixed in current tree (`backup_file` returns 0 if missing). Update the script. |
| `grep: .env: Permission denied` | `.env` is `root:600`. Use `sudo` or `source <(sudo cat .env)`. |
| Compose waits forever on MariaDB | Stack uses staged startup + `mariadb-admin ping`. Check `docker compose logs db`. |
| Web UI up but HTTPS fails (ACME) | Public DNS must point here; ports 80/443 open; not an IP/`localhost` (use `--self-signed-tls` for labs). |
| Self-signed browser warning | Expected with `--self-signed-tls`. Use `curl -k` or trust the local CA Caddy generated under `data/caddy/data`. |
| Alert email not sending | Ensure `--smtp-host` was used (`COMPOSE_PROFILES` includes `mail`), `msmtpd` is running, and LibreNMS alert transports are configured in the UI. Test with UI “send test mail”. |
| UFW enabled but ports still open | Docker can bypass UFW via iptables — run `scripts/docker-user-ufw.sh apply` or restrict `DOCKER-USER`. |
| Rerun changed secrets | Without `--force`, secrets are preserved. `--force` rewrites `.env` but keeps loaded secret values. |
| `validate.php` warnings in CI | Non-core FAILS (mail/DNS) are expected offline; CI only hard-fails on DB/Redis connectivity. |
| Need logs | `sudo docker compose logs --tail=200 librenms db redis caddy msmtpd` and `/var/log/librenms-easydeploy.log`. |

---

## Project layout

```
librenms-easydeploy/
├── docker-compose.yml           # Pinned services, limits, tls/mail profiles
├── librenms-auto-install.sh      # Installer (+ embedded compose for curl|bash)
├── scripts/
│   ├── sync_embedded_compose.py
│   ├── backup.sh / restore.sh
│   ├── upgrade.sh / health-check.sh
│   └── docker-user-ufw.sh
├── contrib/logrotate-librenms-easydeploy
├── test/test_args.bats
├── .github/workflows/ci.yml
├── .env.example
├── LICENSE
└── README.md
```

---

## Testing

```bash
sudo apt-get install -y bats shellcheck shfmt
bats test/
shellcheck librenms-auto-install.sh scripts/*.sh
shfmt -d -i 2 librenms-auto-install.sh
docker compose -f docker-compose.yml config --quiet   # needs env from .env.example
python3 scripts/sync_embedded_compose.py --check
```

CI on push and PR runs lint, Bats, Compose validation (default + `tls` + `mail` profiles), Caddyfile validate for self-signed, secret scanning, HTTP installer E2E, and a self-signed HTTPS E2E path.

---

## License

[GPL-3.0](LICENSE)

## Acknowledgments

- [LibreNMS](https://www.librenms.org/)
- [LibreNMS Docker](https://github.com/librenms/docker)
- [Caddy](https://caddyserver.com/)
- [crazy-max/docker-msmtpd](https://github.com/crazy-max/docker-msmtpd)
