# LibreNMS EasyDeploy

[![CI](https://github.com/DanielNoohi/librenms-easydeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielNoohi/librenms-easydeploy/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![LibreNMS](https://img.shields.io/badge/LibreNMS-26.7.0-0B3D2E)](https://www.librenms.org/)

**One command. Full LibreNMS stack.**  
Docker Compose deployment for network monitoring — auto-discovery, SNMP, topology, traffic graphs, syslog, traps, and alerting — tuned for labs, homelabs, and small single-node sites.

Complements Zabbix (server/app metrics) and Lansweeper (endpoint inventory) with **network-centric visibility**.

---

## Why this exists

Official LibreNMS Docker is solid but still leaves you wiring secrets, Redis auth, sidecars, firewall holes, and first-boot admin yourself. EasyDeploy wraps that into a reviewed installer that:

- Generates strong credentials and a locked-down `.env`
- Brings up app, dispatcher, MariaDB, Redis, syslog, and SNMP traps together
- Creates the admin user and applies poller/syslog settings
- Survives reruns without wiping your secrets
- Ships with CI that actually installs the stack end-to-end

---

## Quick start

Prefer download-then-run so you can review the script first:

```bash
wget https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh
chmod +x librenms-auto-install.sh
sudo ./librenms-auto-install.sh
```

Or clone the repo (keeps `docker-compose.yml` beside the installer):

```bash
git clone https://github.com/DanielNoohi/librenms-easydeploy.git
cd librenms-easydeploy
sudo ./librenms-auto-install.sh
```

Non-interactive (CI / automation):

```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url http://librenms.example.com \
  --save-creds ~/librenms-creds.txt
```

Dry-run preview:

```bash
sudo ./librenms-auto-install.sh --dry-run -n -u http://librenms.example.com
```

When it finishes, open the URL you gave (HTTP on port 80) and sign in with the printed credentials.

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
| **librenms** | Web UI & alerting (host `80` → container `8000`) |
| **dispatcher** | Distributed poller sidecar |
| **db** | MariaDB 10.11 |
| **redis** | Password-protected cache & queue |
| **syslogng** | Syslog ingest on TCP/UDP `514` |
| **snmptrapd** | Authorized SNMP traps on TCP/UDP `162` |

Pinned image tag (`librenms/librenms:26.7.0`) — no `:latest`. Persistent data under `./data/`.

---

## Know before you install

| Topic | Reality |
|-------|---------|
| TLS | **HTTP only.** Put nginx, Caddy, or Traefik in front for HTTPS. This installer does not configure Let's Encrypt. |
| Scope | Single-node Compose for labs / homelabs / small sites — **not** a full production hardening kit. |
| Email | SMTP is not bundled; configure LibreNMS before relying on email alerts. |
| License | GPL-3.0 (LibreNMS and this repo). |

`--no-ssl` is accepted for compatibility; the stack remains HTTP-only either way. Legacy `--le-email` is rejected on purpose.

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
| `--no-ssl` | Compatibility flag; stack stays HTTP-only |
| `--emit-env FILE` | Write generated `.env` and exit (no Docker/root; for tests) |
| `--db-name` / `--db-user` | Database name/user (default: `librenms`) |

Generate an env file without installing:

```bash
./librenms-auto-install.sh -n -u http://example.com --emit-env /tmp/librenms.env
```

Behind an existing reverse proxy, point `--url` at the public HTTP origin (or internal IP) the UI will use.

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │         Docker network (internal)      │
                    │                                        │
   :80 ───────────► │  librenms ──► redis (auth)             │
                    │      │                                 │
   :514 ──────────► │  syslogng    dispatcher (pollers)      │
                    │      │                                 │
   :162 ──────────► │  snmptrapd ──► db (MariaDB)            │
                    └──────────────────────────────────────┘
```

Sidecars follow the [official LibreNMS Docker design](https://github.com/librenms/docker).

**Volumes**

| Path | Contents |
|------|----------|
| `./data/librenms` | Config, logs, plugins, RRD (`/data`) |
| `./data/db` | MariaDB |
| `./data/redis` | Redis persistence |

Local Compose tweaks belong in `docker-compose.override.yml`. After editing `docker-compose.yml` in this repo, refresh the embedded blob:

```bash
python3 scripts/sync_embedded_compose.py
```

---

## Security posture

- Random passwords for DB root, DB user, Redis, and admin
- `.env` written atomically with mode `600`
- Redis requires a password on the internal network
- SNMP trap authorization on; generated v2c/v3 credentials in `.env`
- MariaDB healthcheck via `healthcheck.sh` (no password on process argv)
- Non-root app containers (`PUID`/`PGID` 1000)
- Reruns and `--force` keep existing secrets; config changes are backed up first
- Health checks on MariaDB, Redis, and LibreNMS

Point trap senders at `LIBRENMS_SNMP_COMMUNITY` or `SNMP_USER` / `SNMP_AUTH` / `SNMP_PRIV`. Unauthenticated trap acceptance stays off.

### Firewall

Unless you pass `--no-firewall`, the installer adds UFW allows for:

| Port | Purpose |
|------|---------|
| `80/tcp` | Web UI |
| `162/tcp` + `162/udp` | SNMP traps |
| `514/tcp` + `514/udp` | Syslog |

It does **not** run `ufw enable` — do that yourself when ready:

```bash
sudo ufw enable
```

> Docker publishes ports through iptables and can bypass UFW. Restrict exposure with the `DOCKER-USER` chain when needed — see [Docker and packet filtering](https://docs.docker.com/network/packet-filtering-firewalls/).

---

## Requirements

- Ubuntu 22.04 / 24.04 LTS (or any Docker-capable Linux)
- Docker Engine + Compose v2
- Python 3 and `flock` (`util-linux`)
- Root / sudo
- 4 GB RAM minimum (8 GB recommended above ~500 devices)
- Free host ports: `80/tcp`, `162/tcp+udp`, `514/tcp+udp`

---

## Day-2 operations

### Update

```bash
cd /opt/librenms-easydeploy
docker compose pull
docker compose up -d
```

The official image runs migrations on startup.

### Backup

```bash
cd /opt/librenms-easydeploy
set -a; source .env; set +a
docker compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
  mariadb-dump -u root "$DB_NAME" > "backup_$(date +%F).sql"
tar -czf "librenms_data_$(date +%F).tar.gz" data/
```

### Uninstall

```bash
cd /opt/librenms-easydeploy
docker compose down -v
rm -rf /opt/librenms-easydeploy
```

---

## Project layout

```
librenms-easydeploy/
├── docker-compose.yml           # Pinned services + healthchecks
├── librenms-auto-install.sh     # Installer (+ embedded compose for curl|bash)
├── scripts/sync_embedded_compose.py
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
shellcheck librenms-auto-install.sh
shfmt -d -i 2 librenms-auto-install.sh
docker compose -f docker-compose.yml config --quiet
python3 scripts/sync_embedded_compose.py --check
```

CI on push and PR runs lint, Bats, Compose validation, secret scanning, and a full installer E2E (permissions, services, HTTP, admin, `validate.php`, idempotent rerun, and safe `--force`).

---

## License

[GPL-3.0](LICENSE)

## Acknowledgments

- [LibreNMS](https://www.librenms.org/)
- [LibreNMS Docker](https://github.com/librenms/docker)
