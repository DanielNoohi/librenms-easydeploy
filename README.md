# LibreNMS EasyDeploy

**Docker Compose deployment for LibreNMS** — network monitoring with auto-discovery, SNMP, topology maps, traffic analysis, and alerting. Aimed at labs, homelabs, and small single-node installs. Complements Zabbix (server/app metrics) and Lansweeper (endpoint inventory) with **network-centric visibility**.

---

## Caveats

- **HTTP only, no HTTPS.** Port `80` on the host maps to container `8000`. For HTTPS, put a reverse proxy (nginx, Caddy, Traefik) in front — this installer does **not** configure Let's Encrypt.
- **Not production-hardened.** Single-node Compose for labs/homelabs/small sites. For production, add TLS, backups, monitoring of the monitor, and harden Docker/UFW properly.
- **SMTP is not bundled.** Configure LibreNMS with your SMTP server before using email alerts.
- **Licensed under GPL-3.0.** LibreNMS itself is GPL-3.0; scripts and config in this repo are also GPL-3.0.

---

## Quick Install

Prefer download-then-run (review the script before `sudo`):

```bash
wget https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh
chmod +x librenms-auto-install.sh
sudo ./librenms-auto-install.sh
```

Or clone the repo (keeps `docker-compose.yml` next to the installer):

```bash
git clone https://github.com/DanielNoohi/librenms-easydeploy.git
cd librenms-easydeploy
sudo ./librenms-auto-install.sh
```

One-liner (less reviewable):

```bash
curl -sSL https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh | sudo bash
```

---

## Advanced Usage

### Interactive

```bash
sudo ./librenms-auto-install.sh
```

### Non-interactive (CI/CD)

```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url http://librenms.example.com \
  --save-creds ~/librenms-creds.txt
```

### Behind an external reverse proxy

```bash
sudo ./librenms-auto-install.sh -n -u http://192.168.1.50 --no-ssl -s creds.txt
```

(`--no-ssl` is accepted for compatibility; the stack is always HTTP-only.)

### Dry run (preview)

```bash
sudo ./librenms-auto-install.sh --dry-run -n -u http://librenms.example.com
```

---

## Options

| Flag | Long | Description |
|------|------|-------------|
| `-h` | `--help` | Show help |
| `-d` | `--dir` | Install directory (default: `/opt/librenms-easydeploy`) |
| `-u` | `--url` | Base URL (required for non-interactive) |
| `-t` | `--timezone` | Timezone (default: `UTC`) |
| `-p` | `--pollers` | Poller processes (1–64, default: `16`) |
| `-s` | `--save-creds` | Save credentials to `chmod 600` file |
| `-n` | `--non-interactive` | No prompts (requires `--url`) |
| `-f` | `--force` | Rewrite existing `.env` after backup; loaded secrets are preserved |
| `-D` | `--dry-run` | Preview without executing |
| | `--no-firewall` | Skip UFW rules |
| | `--no-ssl` | Compatibility flag; stack remains HTTP-only |
| | `--emit-env` | Write generated `.env` to a file and exit (no Docker/root; for tests) |
| | `--db-name` | Database name (default: `librenms`) |
| | `--db-user` | Database user (default: `librenms`) |

Legacy `--le-email` usage is rejected with an explanation because TLS is not
implemented here. For test tooling, an environment file can be generated
without root or Docker:

```bash
./librenms-auto-install.sh -n -u http://example.com --emit-env /tmp/librenms.env
```

---

## Security

- Strong random passwords for DB root, DB user, Redis, and admin
- Credentials in `.env` with `chmod 600` (not passed on the installer argv for wait loops where avoidable)
- Redis requires a password on the internal Docker network
- SNMP trap authorization is enabled with generated v2c/v3 credentials
- MariaDB healthcheck uses the image `healthcheck.sh` (no password on process argv)
- Non-root app containers (PUID/PGID 1000)
- UFW rules added by the installer (unless `--no-firewall`):
  - `80/tcp` — LibreNMS web UI (HTTP)
  - `162/tcp` and `162/udp` — SNMP traps (snmptrapd sidecar)
  - `514/tcp` and `514/udp` — Syslog ingestion (syslogng sidecar)
  - SNMP **polling** is outbound; no inbound `161/udp` rule is opened
- Reruns and `--force` preserve existing credentials; supported CLI config changes are backed up and applied
- Data under `./data/` survives container updates
- Pinned LibreNMS image tag — no `:latest`
- Health checks on MariaDB, Redis, and LibreNMS

Generated SNMP v2c/v3 trap credentials are stored in `.env`. Configure trap
senders with `LIBRENMS_SNMP_COMMUNITY` or the `SNMP_USER`/`SNMP_AUTH`/`SNMP_PRIV`
values; default unauthenticated trap acceptance is disabled.

---

## Requirements

- Ubuntu 22.04 / 24.04 LTS (or any Docker-compatible Linux)
- Docker Engine + Docker Compose v2
- Python 3 and `flock` (`util-linux`, included by default on Ubuntu)
- Root/sudo access
- 4 GB RAM minimum (8 GB recommended for >500 devices)
- Ports `80/tcp`, `162/tcp+udp`, and `514/tcp+udp` available on the host

---

## Firewall

The installer adds UFW rules automatically (unless `--no-firewall`):

| Port | Protocol | Purpose |
|------|----------|---------|
| 80   | TCP      | LibreNMS web UI |
| 162  | TCP/UDP  | SNMP trap receiver (snmptrapd sidecar) |
| 514  | TCP/UDP  | Syslog receiver (syslogng sidecar) |

It does **not** run `ufw enable` — enable it yourself:

```bash
sudo ufw enable
```

> **Note:** UFW rules only protect the host. Docker publishes container ports through
> iptables, which **bypasses UFW**. Restrict access with the `DOCKER-USER` chain if needed:
>
> ```bash
> sudo iptables -I DOCKER-USER -p tcp --dport 80 ! -s 10.0.0.0/8 -j DROP
> sudo iptables -I DOCKER-USER -p udp --dport 162 ! -s 10.0.0.0/8 -j DROP
> sudo iptables -I DOCKER-USER -p udp --dport 514 ! -s 10.0.0.0/8 -j DROP
> ```
>
> See [Docker and UFW](https://docs.docker.com/network/packet-filtering-firewalls/).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Internal docker network                  │
├──────────────┬───────────┬────────────┬────────────────────┤
│  librenms    │      db       │       redis                 │
│  (app)       │  (MariaDB)    │   (cache/queue)             │
│  Port 8000   │  Port 3306    │     Port 6379               │
├──────────────┼───────────────┼─────────────────────────────┤
│  dispatcher  │   syslogng    │      snmptrapd              │
│  (polling)   │ (TCP/UDP 514) │    (TCP/UDP 162)            │
└──────────────┴───────────────┴─────────────────────────────┘
```

**Services:**
- **librenms** — Main web UI, alerting (host `80` → `8000`)
- **dispatcher** — Distributed poller (`SIDECAR_DISPATCHER=1`)
- **syslogng** — Syslog ingestion (`SIDECAR_SYSLOGNG=1`, TCP/UDP 514)
- **snmptrapd** — Authorized SNMP trap receiver (`SIDECAR_SNMPTRAPD=1`, TCP/UDP 162)
- **db** — MariaDB 10.11
- **redis** — Cache/queue backend (password required)

Sidecars follow the [official LibreNMS Docker design](https://github.com/librenms/docker).

**Volumes:**
- `./data/librenms` — LibreNMS configuration, logs, plugins, and RRD files (`/data`)
- `./data/db` — MariaDB database
- `./data/redis` — Redis persistence

---

## Updates & Maintenance

### Update

```bash
cd /opt/librenms-easydeploy
docker compose pull
docker compose up -d
```

The official LibreNMS container runs migrations and seeding during startup.

### Backup

```bash
cd /opt/librenms-easydeploy
set -a; source .env; set +a
docker compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" db mariadb-dump -u root "$DB_NAME" > backup_$(date +%F).sql
tar -czf librenms_data_$(date +%F).tar.gz data/
```

### Uninstall

```bash
cd /opt/librenms-easydeploy
docker compose down -v
rm -rf /opt/librenms-easydeploy
```

---

## Project Structure

```
librenms-easydeploy/
├── docker-compose.yml              # Services (pinned LibreNMS tag, healthchecks)
├── librenms-auto-install.sh        # Installer (+ embedded compose for curl|bash)
├── scripts/sync_embedded_compose.py
├── test/test_args.bats             # CLI + .env generation + embed drift tests
├── .github/workflows/ci.yml
├── .env.example
├── LICENSE
└── README.md
```

After changing `docker-compose.yml`, sync the installer blob:

```bash
python3 scripts/sync_embedded_compose.py
```

The installer manages `docker-compose.yml` and backs up older versions during
upgrades. Put local Compose customizations in `docker-compose.override.yml`.

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

CI on push/PR:
- ShellCheck + shfmt
- Bats (args, `.env` emit, embedded compose drift)
- Compose validation, no `:latest`, service list, embed sync
- Secret scanning
- Full installer E2E: file permissions, all services, HTTP, admin creation,
  LibreNMS validation, idempotent rerun, config update, and safe `--force`

---

## License

GPL-3.0 — see [LICENSE](LICENSE).

---

## Acknowledgments

- [LibreNMS](https://www.librenms.org/)
- [LibreNMS Docker](https://github.com/librenms/docker)
