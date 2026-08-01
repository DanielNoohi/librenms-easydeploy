#!/usr/bin/env bash
# librenms-auto-install.sh - Production-ready LibreNMS installer
# Installs LibreNMS via Docker Compose with secure defaults

set -euo pipefail
IFS=$'\n\t'

# Colors
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
INSTALL_DIR="/opt/librenms-easydeploy"
TZ="UTC"
PUID=1000
PGID=1000
BASE_URL=""
DB_NAME="librenms"
DB_USER="librenms"
DB_PASSWORD=""
DB_ROOT_PASSWORD=""
MEMCACHED_HOST="memcached"
REDIS_HOST="redis"
POLLERS=16
ENABLE_SYSLOG=true
ENABLE_SNMPTRAP=true
NON_INTERACTIVE=false
FORCE=false
DRY_RUN=false
SKIP_FIREWALL=false
SKIP_SSL=false
SAVE_CREDS=""
LE_EMAIL=""

# Logging
LOG_FILE="/var/log/librenms-easydeploy.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
die() { log "ERROR" "$*"; exit 1; }

gen_pass() { tr -dc 'A-Za-z0-9!@#$%&*()-_=+' </dev/urandom | head -c 32; echo; }

backup_file() {
    [[ -f "$1" ]] && cp -a "$1" "${1}.bak_${TIMESTAMP}" && info "Backed up $1"
}

print_help() {
    cat <<'EOF'
Usage: sudo ./librenms-auto-install.sh [OPTIONS]

LibreNMS Docker Compose Installer - Network monitoring with auto-discovery,
SNMP, topology maps, traffic analysis, and alerting.

Options:
  -h, --help                 Show this help
  -d, --dir PATH             Install directory (default: /opt/librenms-easydeploy)
  -u, --url URL              Base URL for LibreNMS (e.g., https://librenms.example.com)
  -t, --timezone TZ          Timezone (default: UTC)
  -p, --pollers N            Number of pollers (default: 16)
  -s, --save-creds FILE      Save generated credentials to file (chmod 600)
  -n, --non-interactive      Run without prompts (requires --url)
  -f, --force                Skip pre-flight checks
  -D, --dry-run              Show actions without executing
  --no-firewall              Skip UFW firewall configuration
  --no-ssl                   Skip SSL (use with external proxy)
  --le-email EMAIL           Email for Let's Encrypt (if using certbot later)
  --db-name NAME             Database name (default: librenms)
  --db-user USER             Database user (default: librenms)

Examples:
  sudo ./librenms-auto-install.sh                           # Interactive
  sudo ./librenms-auto-install.sh -u https://librenms.local -s creds.txt
  sudo ./librenms-auto-install.sh -n -u http://192.168.1.50 --no-ssl -s creds.txt
EOF
}

# Parse args
ARGS=$(getopt -o hd:u:t:p:s:nfD --long help,dir:,url:,timezone:,pollers:,save-creds:,non-interactive,force,dry-run,no-firewall,no-ssl,le-email:,db-name:,db-user: -- "$@") || { print_help; exit 2; }
eval set -- "$ARGS"
while true; do
    case "$1" in
        -h|--help) print_help; exit 0;;
        -d|--dir) INSTALL_DIR="$2"; shift 2;;
        -u|--url) BASE_URL="$2"; shift 2;;
        -t|--timezone) TZ="$2"; shift 2;;
        -p|--pollers) POLLERS="$2"; shift 2;;
        -s|--save-creds) SAVE_CREDS="$2"; shift 2;;
        -n|--non-interactive) NON_INTERACTIVE=true; shift;;
        -f|--force) FORCE=true; shift;;
        -D|--dry-run) DRY_RUN=true; shift;;
        --no-firewall) SKIP_FIREWALL=true; shift;;
        --no-ssl) SKIP_SSL=true; shift;;
        --le-email) LE_EMAIL="$2"; shift 2;;
        --db-name) DB_NAME="$2"; shift 2;;
        --db-user) DB_USER="$2"; shift 2;;
        --) shift; break;;
        *) die "Unknown option: $1";;
    esac
done

# Validate
[[ $EUID -ne 0 ]] && die "Run as root (sudo)"
$NON_INTERACTIVE && [[ -z "$BASE_URL" ]] && die "Non-interactive mode requires --url"

run_cmd() {
    local cmd="$*"
    if $DRY_RUN; then info "DRY-RUN: $cmd"; else info "Running: $cmd"; eval "$cmd"; fi
}

# Pre-flight
if ! $FORCE; then
    for port in 80 443 161 162; do
        ss -tuln | grep -q ":$port " && warn "Port $port in use"
    done
    docker compose version >/dev/null 2>&1 || die "Docker Compose not installed"
fi

# Interactive prompts
if ! $NON_INTERACTIVE; then
    [[ -z "$BASE_URL" ]] && read -rp "Base URL (e.g., https://librenms.example.com): " BASE_URL
    read -rp "Timezone [$TZ]: " t; [[ -n "$t" ]] && TZ="$t"
    read -rp "Pollers [$POLLERS]: " p; [[ -n "$p" ]] && POLLERS="$p"
fi

# Generate passwords
DB_PASSWORD=$(gen_pass)
DB_ROOT_PASSWORD=$(gen_pass)
ADMIN_USER="admin"
ADMIN_PASS=$(gen_pass)
ADMIN_EMAIL="${LE_EMAIL:-admin@${BASE_URL#*://}}"

info "Installing to $INSTALL_DIR"
run_cmd "mkdir -p $INSTALL_DIR/{data/{librenms,db,redis},logs/librenms,config/librenms,rrd}"
run_cmd "cd $INSTALL_DIR"

# Create .env
cat > "$INSTALL_DIR/.env" <<EOF
TZ=$TZ
PUID=$PUID
PGID=$PGID
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
BASE_URL=$BASE_URL
POLLERS=$POLLERS
ENABLE_SYSLOG=$ENABLE_SYSLOG
ENABLE_SNMPTRAP=$ENABLE_SNMPTRAP
EOF
run_cmd "chmod 600 $INSTALL_DIR/.env"

# Copy docker-compose.yml
cp "$(dirname "$0")/docker-compose.yml" "$INSTALL_DIR/"

# Start services
run_cmd "cd $INSTALL_DIR && docker compose up -d"

# Wait for DB
info "Waiting for database..."
for i in {1..30}; do
    if run_cmd "cd $INSTALL_DIR && docker compose exec -T db mysqladmin ping -h localhost -u root -p\$DB_ROOT_PASSWORD --silent" 2>/dev/null; then break; fi
    sleep 2
done

# Initialize LibreNMS (create admin user)
info "Creating admin user..."
run_cmd "cd $INSTALL_DIR && docker compose exec -T librenms php artisan librenms:user:add --name=\"$ADMIN_USER\" --password=\"$ADMIN_PASS\" --email=\"$ADMIN_EMAIL\" --role=admin 2>/dev/null || true"

# Firewall
if ! $SKIP_FIREWALL && command -v ufw >/dev/null 2>&1; then
    run_cmd "ufw allow 80/tcp comment 'LibreNMS HTTP'"
    run_cmd "ufw allow 443/tcp comment 'LibreNMS HTTPS'"
    run_cmd "ufw allow 161/udp comment 'LibreNMS SNMP'"
    run_cmd "ufw allow 162/udp comment 'LibreNMS SNMP Trap'"
    info "UFW rules added (run 'ufw enable' to activate)"
fi

# Save credentials
if [[ -n "$SAVE_CREDS" ]]; then
    cat > "$SAVE_CREDS" <<EOF
# LibreNMS Credentials - $(date)
LibreNMS URL: $BASE_URL
Admin User: $ADMIN_USER
Admin Pass: $ADMIN_PASS

Database: $DB_NAME
DB User: $DB_USER
DB Pass: $DB_PASSWORD
DB Root: $DB_ROOT_PASSWORD
EOF
    chmod 600 "$SAVE_CREDS"
    info "Credentials saved to $SAVE_CREDS"
fi

# Summary
cat <<EOF

===================================================================
LibreNMS Installation Complete!
URL: $BASE_URL
Admin: $ADMIN_USER / $ADMIN_PASS
Database: $DB_NAME / $DB_USER / $DB_PASSWORD
===================================================================
EOF

exit 0