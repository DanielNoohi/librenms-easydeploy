#!/usr/bin/env bash
# librenms-auto-install.sh - Production-ready LibreNMS installer
# Installs LibreNMS via Docker Compose with secure defaults

set -euo pipefail
IFS=$'\n\t'

# Defaults (all initialized)
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
ADMIN_PASS=""
ADMIN_EMAIL=""

# Logging
LOG_FILE="/var/log/librenms-easydeploy.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
die() {
  log "ERROR" "$*"
  exit 1
}

gen_pass() {
  tr -dc 'A-Za-z0-9!@#$%&*()-_=+' </dev/urandom | head -c 32
  echo
}

validate_url() {
  local url="$1"
  [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]] || die "Invalid URL format: $url (must be http://host or https://host)"
}

validate_timezone() {
  [[ -f "/usr/share/zoneinfo/$1" ]] || warn "Timezone '$1' may not be valid (not found in /usr/share/zoneinfo)"
}

validate_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    die "Invalid port: $port"
  fi
}

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

# Parse arguments without eval
while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    print_help
    exit 0
    ;;
  -d | --dir)
    INSTALL_DIR="$2"
    shift 2
    ;;
  -u | --url)
    BASE_URL="$2"
    shift 2
    ;;
  -t | --timezone)
    TZ="$2"
    shift 2
    ;;
  -p | --pollers)
    POLLERS="$2"
    shift 2
    ;;
  -s | --save-creds)
    SAVE_CREDS="$2"
    shift 2
    ;;
  -n | --non-interactive)
    NON_INTERACTIVE=true
    shift
    ;;
  -f | --force)
    FORCE=true
    shift
    ;;
  -D | --dry-run)
    DRY_RUN=true
    shift
    ;;
  --no-firewall)
    SKIP_FIREWALL=true
    shift
    ;;
  --no-ssl)
    SKIP_SSL=true
    shift
    ;;
  --le-email)
    LE_EMAIL="$2"
    shift 2
    ;;
  --db-name)
    DB_NAME="$2"
    shift 2
    ;;
  --db-user)
    DB_USER="$2"
    shift 2
    ;;
  --)
    shift
    break
    ;;
  *) die "Unknown option: $1 (use --help)" ;;
  esac
done

# Pre-flight checks
[[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)"

if ! command -v docker &>/dev/null; then
  die "Docker is not installed. Please install Docker first."
fi

# Determine docker-compose command
if docker compose version &>/dev/null; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  DOCKER_COMPOSE="docker-compose"
else
  die "Docker Compose is not installed. Please install Docker Compose v2."
fi

# Validate required options
[[ "$NON_INTERACTIVE" == true && -z "$BASE_URL" ]] && die "Non-interactive mode requires --url"
[[ -n "$BASE_URL" ]] && validate_url "$BASE_URL"
[[ -n "$TZ" ]] && validate_timezone "$TZ"
if ! [[ "$POLLERS" =~ ^[0-9]+$ ]] || [ "$POLLERS" -lt 1 ] || [ "$POLLERS" -gt 64 ]; then
  die "Pollers must be 1-64"
fi

# Interactive prompts
if [[ "$NON_INTERACTIVE" == false ]]; then
  [[ -z "$BASE_URL" ]] && {
    read -rp "Base URL (e.g., https://librenms.example.com): " BASE_URL
    validate_url "$BASE_URL"
  }
  read -rp "Timezone [$TZ]: " t
  [[ -n "$t" ]] && {
    TZ="$t"
    validate_timezone "$TZ"
  }
  read -rp "Pollers [$POLLERS]: " p
  [[ -n "$p" ]] && {
    POLLERS="$p"
    if ! [[ "$POLLERS" =~ ^[0-9]+$ ]] || [ "$POLLERS" -lt 1 ] || [ "$POLLERS" -gt 64 ]; then
      die "Pollers must be 1-64"
    fi
  }
fi

# Generate passwords
DB_PASSWORD="${DB_PASSWORD:-$(gen_pass)}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(gen_pass)}"
ADMIN_PASS="${ADMIN_PASS:-$(gen_pass)}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${BASE_URL#*://}}"
ADMIN_EMAIL="${ADMIN_EMAIL%%/*}" # Remove path if any
ADMIN_EMAIL="${ADMIN_EMAIL%%:*}" # Remove port if any

# Export variables for docker-compose
export TZ PUID PGID BASE_URL DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD MEMCACHED_HOST REDIS_HOST POLLERS ENABLE_SYSLOG ENABLE_SNMPTRAP

# Dry-run: show configuration and exit
if [[ "$DRY_RUN" == true ]]; then
  info "=== DRY-RUN MODE (no changes will be made) ==="
  info "Install directory: $INSTALL_DIR"
  info "Base URL: ${BASE_URL:-<not set>}"
  info "Timezone: $TZ"
  info "Pollers: $POLLERS"
  info "Database: $DB_NAME / $DB_USER"
  info "Admin user: admin"
  info "Admin pass: $ADMIN_PASS"
  info "Admin email: $ADMIN_EMAIL"
  info "Firewall: $([[ "$SKIP_FIREWALL" == true ]] && echo "skipped" || echo "configured")"
  info "SSL: $([[ "$SKIP_SSL" == true ]] && echo "skipped" || echo "enabled")"
  info "Credentials file: ${SAVE_CREDS:-<not saved>}"
  info "Log file: $LOG_FILE"
  info "Would create: $INSTALL_DIR/{data,logs,config,rrd}"
  info "Would copy: docker-compose.yml"
  info "Would create: .env (chmod 600)"
  info "Would start: $DOCKER_COMPOSE up -d"
  info "Would wait for database health"
  info "Would run migrations and create admin user"
  info "=== DRY-RUN COMPLETE ==="
  exit 0
fi

# Create install directory
mkdir -p "$INSTALL_DIR"/{data/{librenms,db,redis},logs/librenms,config/librenms,rrd}
cd "$INSTALL_DIR" || die "Cannot access $INSTALL_DIR"

# Copy docker-compose.yml from script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f docker-compose.yml ]] || {
  cp "$SCRIPT_DIR/docker-compose.yml" .
  info "Copied docker-compose.yml"
}

# Backup existing .env
[[ -f .env && "$FORCE" == false ]] && backup_file .env

# Create .env file
cat >.env <<EOF
# LibreNMS Docker Compose Environment
# Generated by librenms-auto-install.sh on $(date)

TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
BASE_URL=${BASE_URL}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
MEMCACHED_HOST=${MEMCACHED_HOST}
REDIS_HOST=${REDIS_HOST}
POLLERS=${POLLERS}
ENABLE_SYSLOG=${ENABLE_SYSLOG}
ENABLE_SNMPTRAP=${ENABLE_SNMPTRAP}
EOF
chmod 600 .env
info "Created .env file (chmod 600)"

# Save credentials if requested
if [[ -n "$SAVE_CREDS" ]]; then
  {
    echo "# LibreNMS credentials generated on $(date)"
    echo "MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
    echo "MYSQL_DATABASE=${DB_NAME}"
    echo "MYSQL_USER=${DB_USER}"
    echo "MYSQL_PASSWORD=${DB_PASSWORD}"
    echo "BASE_URL=${BASE_URL}"
    echo "TZ=${TZ}"
    echo "ADMIN_USER=admin"
    echo "ADMIN_PASSWORD=${ADMIN_PASS}"
    echo "ADMIN_EMAIL=${ADMIN_EMAIL}"
  } >"$SAVE_CREDS"
  chmod 600 "$SAVE_CREDS"
  info "Credentials saved to $SAVE_CREDS (chmod 600)"
fi

# Set correct volume permissions
info "Setting volume permissions (PUID=$PUID, PGID=$PGID)..."
chown -R "$PUID:$PGID" "$INSTALL_DIR"/data "$INSTALL_DIR"/logs "$INSTALL_DIR"/config "$INSTALL_DIR"/rrd 2>/dev/null || true

# Firewall configuration
if [[ "$SKIP_FIREWALL" == false ]]; then
  if command -v ufw &>/dev/null; then
    info "Configuring UFW firewall..."
    ufw allow 80/tcp comment 'LibreNMS HTTP'
    ufw allow 443/tcp comment 'LibreNMS HTTPS'
    ufw allow 161/udp comment 'LibreNMS SNMP'
    ufw allow 162/udp comment 'LibreNMS SNMP Trap'
    ufw allow 514/udp comment 'LibreNMS Syslog'
    info "UFW rules added (run 'ufw enable' to activate if not already)"
  else
    warn "UFW not installed, skipping firewall configuration"
  fi
else
  info "Skipping firewall configuration as requested"
fi

# SSL configuration placeholder
if [[ "$SKIP_SSL" == false && -n "$LE_EMAIL" ]]; then
  info "Let's Encrypt email provided: $LE_EMAIL (certbot integration not yet implemented)"
elif [[ "$SKIP_SSL" == true ]]; then
  info "SSL configuration skipped as requested (use external reverse proxy)"
fi

# Start services
info "Starting Docker Compose services..."
$DOCKER_COMPOSE up -d

# Wait for database to be healthy
info "Waiting for database to be ready..."
for i in {1..60}; do
  if $DOCKER_COMPOSE exec -T db mysqladmin ping -h"localhost" -u"root" -p"${DB_ROOT_PASSWORD}" &>/dev/null; then
    info "Database is ready"
    break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "Database did not become ready in time"
done

# Wait for librenms container to be healthy
info "Waiting for LibreNMS to be ready..."
for i in {1..60}; do
  if $DOCKER_COMPOSE exec -T librenms curl -f http://localhost:8000 &>/dev/null; then
    info "LibreNMS web UI is ready"
    break
  fi
  sleep 3
  [[ $i -eq 60 ]] && die "LibreNMS did not become ready in time"
done

# Initialize LibreNMS (first-time setup)
info "Initializing LibreNMS database..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan migrate --force
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan librenms:seed

# Create initial admin user
info "Creating admin user..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan librenms:user:add --name="admin" --pass="$ADMIN_PASS" --email="$ADMIN_EMAIL" --role=10

# Final summary
info "Installation complete!"
info "LibreNMS is accessible at: ${BASE_URL:-http://$(hostname -I | awk '{print $1}')}"
info "Default admin credentials:"
info "  Username: admin"
info "  Password: $ADMIN_PASS"
info "  Email: $ADMIN_EMAIL"
info "Database credentials saved in .env (chmod 600)"
[[ -n "$SAVE_CREDS" ]] && info "Credentials also saved to: $SAVE_CREDS"
info "Log file: $LOG_FILE"
info ""
info "Next steps:"
info "  1. Log in at ${BASE_URL:-http://<server-ip>} with admin / $ADMIN_PASS"
info "  2. Change the admin password immediately"
info "  3. Configure SNMP on network devices (community: public)"
info "  4. Enable auto-discovery in LibreNMS web UI"
info "  5. Set up alerting transports (email, Slack, etc.)"
