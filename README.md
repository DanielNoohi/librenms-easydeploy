# 🌐 LibreNMS EasyDeploy

**Production-ready LibreNMS deployment via Docker Compose** - Network monitoring with auto-discovery, SNMP monitoring, topology maps, traffic analysis, alerting, and asset insights. Complements Zabbix and Lansweeper by focusing on **network-centric visibility**.

---

## 🎯 Why LibreNMS?

| Feature | LibreNMS | Zabbix | Lansweeper |
|---------|----------|--------|------------|
| **Auto-discovery** | ✅ Excellent (CDP, LLDP, ARP, OSPF, BGP) | Basic | Agent-based |
| **Network Topology Maps** | ✅ Native (Graphviz, geo) | Limited | ❌ |
| **Traffic Analysis (NetFlow/sFlow/IPFIX)** | ✅ Native | Via plugins | ❌ |
| **SNMP Monitoring** | ✅ First-class (MIB auto-load) | ✅ Good | Basic |
| **Config Management** | ✅ Oxidized integration | ❌ | ✅ |
| **Alerting** | ✅ Flexible (email, Slack, PagerDuty, etc.) | ✅ Excellent | Basic |
| **Asset/Inventory** | ✅ Network device focus | Server/app focus | ✅ Endpoint focus |

**Perfect complement** to your stack:
- **Zabbix** → Server/app/infrastructure metrics
- **Lansweeper** → Endpoint inventory, software, compliance
- **LibreNMS** → Network devices, topology, traffic, config backups

---

## 🚀 Quick Install

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

## 🎮 Advanced Usage

### Interactive (guided)
```bash
sudo ./librenms-auto-install.sh
```

### Non-interactive (CI/CD, automation)
```bash
sudo ./librenms-auto-install.sh \
  --non-interactive \
  --url https://librenms.example.com \
  --save-creds ~/librenms-creds.txt
```

### With Let's Encrypt email (for future certbot integration)
```bash
sudo ./librenms-auto-install.sh \
  -n -u https://librenms.example.com \
  --le-email admin@example.com \
  -s creds.txt
```

### Skip SSL (behind external reverse proxy)
```bash
sudo ./librenms-auto-install.sh -n -u http://192.168.1.50 --no-ssl -s creds.txt
```

### Dry run (preview actions)
```bash
sudo ./librenms-auto-install.sh --dry-run -n -u https://librenms.example.com
```

---

## 🔧 All Options

| Flag | Long | Description |
|------|------|-------------|
| `-h` | `--help` | Show help |
| `-d` | `--dir` | Install directory (default: `/opt/librenms-easydeploy`) |
| `-u` | `--url` | Base URL (required for non-interactive) |
| `-t` | `--timezone` | Timezone (default: `UTC`) |
| `-p` | `--pollers` | Poller processes (default: `16`, range: 1-64) |
| `-s` | `--save-creds` | Save credentials to file (`chmod 600`) |
| `-n` | `--non-interactive` | No prompts (requires `--url`) |
| `-f` | `--force` | Skip pre-flight checks |
| `-D` | `--dry-run` | Preview without executing |
| | `--no-firewall` | Skip UFW rules |
| | `--no-ssl` | Skip SSL (use external proxy) |
| | `--le-email` | Email for Let's Encrypt |
| | `--db-name` | Database name (default: `librenms`) |
| | `--db-user` | Database user (default: `librenms`) |

---

## 🔐 Security Features

- **Strong 32-char passwords** for DB root, DB user, and admin user
- **Credentials never on command line** - passed via Docker Compose `.env` (chmod 600)
- **Non-root containers** - runs as PUID/PGID 1000
- **UFW firewall rules** for ports 80, 443, 161/udp, 162/udp, 514/udp
- **No interference** with existing Zabbix (ports 10050/10051) or Lansweeper
- **Data persistence** - all data in `./data/` survives container updates
- **Volume permissions** automatically set to PUID:PGID
- **Pinned Docker images** - no `:latest` tags
- **Health checks** on all services

---

## 📋 Requirements

- Ubuntu 22.04 / 24.04 LTS (or any Docker-compatible Linux)
- Docker Engine + Docker Compose v2 (`docker compose`)
- Root/sudo access
- 4 GB RAM minimum (8 GB recommended for >500 devices)
- Ports 80, 443, 161/udp, 162/udp, 514/udp available

---

## 🌐 Post-Install Access

After installation:

| Item | Value |
|------|-------|
| **Web UI** | `https://your-domain` (or `http://IP` if `--no-ssl`) |
| **Admin User** | `admin` |
| **Admin Password** | Generated 32-char string (shown once, saved to `--save-creds` file) |
| **SNMP Community** | Configure in UI → Devices → Add Device |

### Enable SNMP on Network Devices
```bash
# Cisco example
snmp-server community public RO
snmp-server enable traps
snmp-server host <librenms-ip> version 2c public
```

### Auto-Discovery
LibreNMS automatically discovers via:
- **CDP/LLDP** (neighbors)
- **ARP/NDP** (Layer 2)
- **OSPF/BGP** (routing peers)
- **NetFlow/sFlow** (traffic sources)

---

## 🐳 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Docker Network                        │
├─────────────┬──────────┬────────────┬───────────────────────┤
│  librenms   │    db    │  memcached │         redis         │
│  (app)      │ (MariaDB)│  (cache)   │     (cache/queue)     │
│  Port 8000  │  Port 3306│  Port 11211│      Port 6379        │
├─────────────┼──────────┼────────────┼───────────────────────┤
│ dispatcher  │  syslog  │  snmptrap  │   traefik (optional)  │
│ (polling)   │  (UDP 514)│  (UDP 162) │    (HTTPS/Let's Enc)  │
└─────────────┴──────────┴────────────┴───────────────────────┘
```

**Services:**
- **librenms** - Main web UI, polling, alerting
- **dispatcher** - Distributed polling for large deployments
- **syslog** - Network device syslog ingestion (UDP 514)
- **snmptrap** - SNMP trap receiver (UDP 162)
- **db** - MariaDB 10.11 database
- **memcached** - Caching layer
- **redis** - Queue/cache backend
- **traefik** - Optional reverse proxy with Let's Encrypt (commented out)

**Volumes** (persisted in `$INSTALL_DIR`):
- `./data/librenms` - LibreNMS data, configs, RRD files
- `./data/db` - MariaDB database
- `./data/redis` - Redis persistence
- `./logs/librenms` - Application logs
- `./config/librenms` - Custom config overrides
- `./rrd` - RRD graphs

---

## 🔄 Updates & Maintenance

### Update LibreNMS
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
# Remove UFW rules manually if needed
```

---

## 📁 Project Structure

```
librenms-easydeploy/
├── docker-compose.yml          # Service definitions (pinned images, healthchecks)
├── librenms-auto-install.sh    # Main installer (validated, secure)
├── .env.example                # Template for .env
├── test/
│   └── test_args.bats          # Bats argument tests
├── .github/
│   └── workflows/ci.yml        # GitHub Actions CI (ShellCheck, shfmt, Bats, Compose)
├── .gitignore
├── LICENSE
└── README.md
```

---

## 🧪 Testing

```bash
# Install test deps (Ubuntu/Debian)
sudo apt-get install -y bats shellcheck shfmt

# Run tests
bats test/
shellcheck librenms-auto-install.sh
shfmt -d librenms-auto-install.sh
```

CI runs automatically on push/PR:
- **ShellCheck** - Static analysis for shell scripts
- **shfmt** - Formatting validation
- **Bats** - Unit tests for argument parsing
- **Docker Compose** - Config validation, no `:latest` tags
- **Security** - Secret scanning

---

## 📄 License

MIT License - see [LICENSE](LICENSE)

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `bats test/ && shellcheck *.sh`
5. Submit a PR

---

## 🙏 Acknowledgments

- [LibreNMS](https://www.librenms.org/) - The amazing network monitoring platform
- [LibreNMS Docker](https://github.com/librenms/docker) - Official Docker images

---

**Made with ❤️ for network engineers by [DanielNoohi](https://github.com/DanielNoohi)**