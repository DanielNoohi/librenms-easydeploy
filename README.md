# LibreNMS EasyDeploy

**Docker Compose deployment for LibreNMS** — a network monitoring platform with auto-discovery, SNMP, topology maps, traffic analysis, and alerting. Complements Zabbix (server/app metrics) and Lansweeper (endpoint inventory) by focusing on **network-centric visibility**.

---

## Caveats

- **HTTP only, no HTTPS.** The container exposes port 80 internally on 8000. For HTTPS, place a reverse proxy (nginx, Caddy, Traefik) in front.
- **Not production-hardened.** This is a single-node Docker Compose stack intended for labs, homelabs, and small deployments. For production, add monitoring backups, and a proper backup strategy.
- **Licensed under GPL-3.0.** LibreNMS itself is GPL-3.0; any scripts and config files in this repository are also GPL-3.0.

---

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh | sudo bash
```

Or download and run:

```bash
wget https://raw.githubusercontent.com/DanielNoohi/librenms-easydeploy/main/librenms-auto-install.sh
chmod +x librenms-auto-install.sh
sudo ./librenms-auto-install.sh
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

### Skip SSL (external reverse proxy)

```bash
sudo ./librenms-auto-install.sh -n -u http://192.168.1.50 --no-ssl -s creds.txt
```

### Dry run (preview)

```bash
sudo ./librenms-auto-install.sh --dry-run -n -u http://librenms.example.com
```

---

## Options

| Flag | Long | Description |
|------|------|-------------|
| `-h` | `--help` | Show this help |
| `-d` | `--dir` | Install directory (default: `/opt/librenms-easydeploy`) |
| `-u` | `--url` | Base URL (required for non-interactive) |
| `-t` | `--timezone` | Timezone (default: `UTC`) |
| `-p` | `--pollers` | Poller processes (1–64, default: `16`) |
| `-s` | `--save-creds` | Save credentials to `chmod 600` file |
| `-n` | `--non-interactive` | No prompts (requires `--url`) |
| `-f` | `--force` | Skip pre-flight checks |
| `-D` | `--dry-run` | Preview without executing |
| | `--no-firewall` | Skip UFW rules |
| | `--no-ssl` | Skip SSL (use external proxy) |
| | `--le-email` | Email for Let's Encrypt (reverse proxy setup) |
| | `--db-name` | Database name (default: `librenms`) |
| | `--db-user` | Database user (default: `librenms`) |

---

## Security

- Strong 32-char passwords for DB root, DB user, and admin user
- Credentials never on command line — passed via `.env` (`chmod 600`)
- Non-root containers (PUID/PGID 1000)
- UFW firewall rules added by the installer:
  - `80/tcp` — LibreNMS web UI (HTTP)
  - `161/udp` — SNMP (device polling from this host)
  - `162/udp` — SNMP traps (snmptrapd sidecar)
  - `514/udp` — Syslog ingestion (syslogng sidecar)
- Reruns are idempotent: existing `.env` credentials (DB and admin) are
  loaded and reused; nothing is regenerated or overwritten without `--force`
- No interference with existing Zabbix (ports 10050/10051) or Lansweeper
- Data persistence — all data in `./data/` survives container updates
- Pinned Docker images — no `:latest` tags
- Health checks on all services (db, redis, memcached, librenms)

---

## Requirements

- Ubuntu 22.04 / 24.04 LTS (or any Docker-compatible Linux)
- Docker Engine + Docker Compose v2
- Root/sudo access
- 4 GB RAM minimum (8 GB recommended for >500 devices)
- Ports 80/tcp, 161/udp, 162/udp, 514/udp available

---

## Firewall

The installer adds UFW rules automatically (unless `--no-firewall`):

| Port | Protocol | Purpose |
|------|----------|---------|
| 80   | TCP      | LibreNMS web UI |
| 161  | UDP      | SNMP polling (outbound from this host) |
| 162  | UDP      | SNMP trap receiver (snmptrapd sidecar) |
| 514  | UDP      | Syslog receiver (syslogng sidecar) |

It does **not** run `ufw enable` — you must enable the firewall yourself:

```bash
sudo ufw enable
```

> **Note:** The installer's UFW rules only protect the host. Docker
> publishes container ports (`80/tcp`, `162/udp`, `514/udp`) through
> iptables, which **bypasses UFW**. If you need to restrict access to
> these ports, configure them in the `DOCKER-USER` chain instead:
>
> ```bash
> # Example: block all except your management subnet (10.0.0.0/8)
> sudo iptables -I DOCKER-USER -p tcp --dport 80 ! -s 10.0.0.0/8 -j DROP
> sudo iptables -I DOCKER-USER -p udp --dport 162 ! -s 10.0.0.0/8 -j DROP
> sudo iptables -I DOCKER-USER -p udp --dport 514 ! -s 10.0.0.0/8 -j DROP
> ```
>
> See the Docker documentation on
> [Docker and UFW](https://docs.docker.com/network/packet-filtering-firewalls/)
> for details.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Internal docker network                  │
├──────────────┬───────────┬────────────┬────────────────────┤
│  librenms    │    db     │  memcached │      redis         │
│  (app)       │ (MariaDB) │  (cache)   │  (cache/queue)     │
│  Port 8000   │ Port 3306 │ Port 11211 │    Port 6379       │
├──────────────┼───────────┼────────────┼────────────────────┤
│  dispatcher  │ syslogng  │ snmptrapd  │                    │
│  (polling)   │ (UDP 514) │ (UDP 162)  │                    │
└──────────────┴───────────┴────────────┴────────────────────┘
```

**Services:**
- **librenms** — Main web UI, alerting (port 80 → 8000)
- **dispatcher** — Distributed poller (sidecar, `SIDECAR_DISPATCHER=1`)
- **syslogng** — Syslog ingestion (sidecar, `SIDECAR_SYSLOGNG=1`, UDP 514)
- **snmptrapd** — SNMP trap receiver (sidecar, `SIDECAR_SNMPTRAPD=1`, UDP 162)
- **db** — MariaDB 10.11
- **memcached** — Cache backend
- **redis** — Cache/queue backend

The dispatcher, syslogng, and snmptrapd sidecars follow the
[official LibreNMS Docker design](https://github.com/librenms/docker):
each is a separate container running the same image with the matching
`SIDECAR_*` flag set to `1` (not the main container). This keeps
polling, syslog, and trap ingestion isolated and independently
restartable.

**Volumes:**
- `./data/librenms` — LibreNMS data, configs, RRD files
- `./data/db` — MariaDB database
- `./data/redis` — Redis persistence
- `./logs/librenms` — Application logs
- `./config/librenms` — Custom config overrides
- `./rrd` — RRD graphs

---

## Updates & Maintenance

### Update

```bash
cd /opt/librenms-easydeploy
docker compose pull
docker compose up -d
docker compose exec librenms php artisan migrate --force
docker compose exec librenms php artisan librenms:snmp-scan --force
```

### Backup

```bash
cd /opt/librenms-easydeploy
docker compose exec db mysqldump -u root -p"$DB_ROOT_PASSWORD" librenms > backup_$(date +%F).sql
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
├── docker-compose.yml          # Service definitions (pinned images, healthchecks)
├── librenms-auto-install.sh    # Installer
├── test/
│   └── test_args.bats          # Bats argument tests
├── .github/
│   └── workflows/ci.yml        # GitHub Actions (ShellCheck, shfmt, Bats, Compose, security)
├── .gitignore
├── LICENSE
└── README.md
```

---

## Testing

```bash
sudo apt-get install -y bats shellcheck shfmt
bats test/
shellcheck librenms-auto-install.sh
shfmt -d librenms-auto-install.sh
```

CI runs automatically on push/PR:
- ShellCheck — static analysis
- shfmt — formatting validation
- Bats — argument parsing tests
- Docker Compose — config validation, no `:latest` tags
- Secret scanning

---

## License

GPL-3.0 — see [LICENSE](LICENSE).

LibreNMS itself is GPL-3.0 licensed. This repository ships convenience scripts and a Docker Compose configuration around the official LibreNMS Docker image; they are also GPL-3.0.

---

## Acknowledgments

- [LibreNMS](https://www.librenms.org/) — The network monitoring platform
- [LibreNMS Docker](https://github.com/librenms/docker) — Official Docker images
