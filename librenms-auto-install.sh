#!/usr/bin/env bash
# librenms-auto-install.sh - Production-ready LibreNMS installer
# Installs LibreNMS via Docker Compose with secure defaults

set -euo pipefail
IFS=$'\n\t'

#-------------------------- Defaults ------------------------------------
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

#-------------------------- Logging -------------------------------------
LOG_FILE="/var/log/librenms-easydeploy.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

log() {
  local level="$1"
  shift
  local ts msg
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  msg="[$ts] [$level] $*"
  echo "$msg"
  if [[ -w "$LOG_FILE" ]] 2>/dev/null || [[ -w "$(dirname "$LOG_FILE")" ]] 2>/dev/null; then
    echo "$msg" >>"$LOG_FILE"
  fi
}
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
die() {
  log "ERROR" "$*"
  exit 1
}

#-------------------------- Password generation (pipefail-safe) ---------
gen_pass() {
  local len="${1:-32}" pass=""
  if command -v python3 &>/dev/null; then
    pass=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range($len)))
" 2>/dev/null || true)
  fi
  if [[ -z "$pass" ]] && command -v openssl &>/dev/null; then
    pass=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len" || true)
  fi
  if [[ -z "$pass" ]]; then
    pass=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | dd bs=1 count="$len" 2>/dev/null || true)
  fi
  [[ -n "$pass" ]] || die "Failed to generate secure password"
  echo "$pass"
}

#-------------------------- Validation helpers --------------------------
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

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Invalid email format: $email"
}

backup_file() {
  [[ -f "$1" ]] && cp -a "$1" "${1}.bak_${TIMESTAMP}" && info "Backed up $1"
}

#-------------------------- Help ----------------------------------------
print_help() {
  cat <<'EOF'
Usage: sudo ./librenms-auto-install.sh [OPTIONS]

LibreNMS Docker Compose Installer - Network monitoring with auto-discovery,
SNMP, topology maps, traffic analysis, and alerting.

Options:
  -h, --help                 Show this help
  -d, --dir PATH             Install directory (default: /opt/librenms-easydeploy)
  -u, --url URL              Base URL for LibreNMS (e.g., http://librenms.example.com)
  -t, --timezone TZ          Timezone (default: UTC)
  -p, --pollers N            Number of pollers (default: 16, range: 1-64)
  -s, --save-creds FILE      Save generated credentials to file (chmod 600)
  -n, --non-interactive      Run without prompts (requires --url)
  -f, --force                Skip pre-flight checks
  -D, --dry-run              Show actions without executing
  --no-firewall              Skip UFW firewall configuration
  --no-ssl                   Skip SSL (use with external reverse proxy)
  --le-email EMAIL           Email for Let's Encrypt (requires --url with https)
  --db-name NAME             Database name (default: librenms)
  --db-user USER             Database user (default: librenms)

Examples:
  sudo ./librenms-auto-install.sh                           # Interactive
  sudo ./librenms-auto-install.sh -u http://librenms.local -s creds.txt
  sudo ./librenms-auto-install.sh -n -u http://192.168.1.50 --no-ssl -s creds.txt
EOF
}

#-------------------------- Argument parsing ----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    print_help
    exit 0
    ;;
  -d | --dir)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --dir requires a directory path"
    INSTALL_DIR="$2"
    shift 2
    ;;
  -u | --url)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --url requires a URL"
    BASE_URL="$2"
    validate_url "$BASE_URL"
    shift 2
    ;;
  -t | --timezone)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --timezone requires a timezone"
    TZ="$2"
    validate_timezone "$TZ"
    shift 2
    ;;
  -p | --pollers)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --pollers requires a number"
    POLLERS="$2"
    shift 2
    ;;
  -s | --save-creds)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --save-creds requires a file path"
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
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --le-email requires an email"
    LE_EMAIL="$2"
    validate_email "$LE_EMAIL"
    shift 2
    ;;
  --db-name)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --db-name requires a name"
    DB_NAME="$2"
    shift 2
    ;;
  --db-user)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --db-user requires a user"
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

#-------------------------- Validation ----------------------------------
[[ "$NON_INTERACTIVE" == true && -z "$BASE_URL" ]] && die "Non-interactive mode requires --url"
if ! [[ "$POLLERS" =~ ^[0-9]+$ ]] || [ "$POLLERS" -lt 1 ] || [ "$POLLERS" -gt 64 ]; then
  die "Pollers must be 1-64"
fi

#-------------------------- Interactive prompts -------------------------
if [[ "$NON_INTERACTIVE" == false ]]; then
  [[ -z "$BASE_URL" ]] && {
    read -rp "Base URL (e.g., http://librenms.example.com): " BASE_URL
    validate_url "$BASE_URL"
  }
  read -rp "Timezone [$TZ]: " t && [[ -n "$t" ]] && {
    TZ="$t"
    validate_timezone "$TZ"
  }
  read -rp "Pollers [$POLLERS]: " p && [[ -n "$p" ]] && POLLERS="$p"
  if ! [[ "$POLLERS" =~ ^[0-9]+$ ]] || [ "$POLLERS" -lt 1 ] || [ "$POLLERS" -gt 64 ]; then
    die "Pollers must be 1-64"
  fi
fi

#-------------------------- Password generation -------------------------
DB_PASSWORD="${DB_PASSWORD:-$(gen_pass 32)}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(gen_pass 32)}"
ADMIN_PASS="${ADMIN_PASS:-$(gen_pass 16)}"
[[ -z "$ADMIN_EMAIL" ]] && {
  DOMAIN="${BASE_URL#*://}"
  DOMAIN="${DOMAIN%%/*}"
  DOMAIN="${DOMAIN%%:*}"
  ADMIN_EMAIL="admin@${DOMAIN:-librenms.local}"
}

#-------------------------- Dry-run (before root/filesystem ops) -------
if [[ "$DRY_RUN" == true ]]; then
  info "=== DRY-RUN MODE (no changes) ==="
  info "Install dir: $INSTALL_DIR"
  info "Base URL: $BASE_URL"
  info "Timezone: $TZ | Pollers: $POLLERS"
  info "Database: $DB_NAME / $DB_USER"
  info "Admin: admin / $ADMIN_PASS / $ADMIN_EMAIL"
  info "Firewall: $([ "$SKIP_FIREWALL" == true ] && echo skipped || echo configured)"
  info "SSL: $([ "$SKIP_SSL" == true ] && echo skipped || echo none \(HTTP only\))"
  info "Creds file: ${SAVE_CREDS:-<not saved>}"
  info "Would create: $INSTALL_DIR/{data,logs,config,rrd}"
  info "Would copy docker-compose.yml, create .env, start services"
  info "=== DRY-RUN COMPLETE ==="
  exit 0
fi

#-------------------------- Pre-flight checks --------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)"
command -v docker &>/dev/null || die "Docker is not installed. Install Docker first."
if docker compose version &>/dev/null; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  DOCKER_COMPOSE="docker-compose"
else
  die "Docker Compose v2 is not installed."
fi

#-------------------------- Install directory ---------------------------
mkdir -p "$INSTALL_DIR"/{data/{librenms,db,redis},logs/librenms,config/librenms,rrd}
cd "$INSTALL_DIR" || die "Cannot access $INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f docker-compose.yml ]] || cp "$SCRIPT_DIR/docker-compose.yml" .

#-------------------------- Environment file ----------------------------
[[ -f .env && "$FORCE" == false ]] && backup_file .env
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

#-------------------------- Save credentials ----------------------------
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

#-------------------------- Volume permissions --------------------------
info "Setting volume permissions (PUID=$PUID, PGID=$PGID)..."
chown -R "$PUID:$PGID" "$INSTALL_DIR"/data "$INSTALL_DIR"/logs "$INSTALL_DIR"/config "$INSTALL_DIR"/rrd 2>/dev/null || true

#-------------------------- Firewall ------------------------------------
if [[ "$SKIP_FIREWALL" == false ]] && command -v ufw &>/dev/null; then
  ufw allow 80/tcp comment 'LibreNMS HTTP'
  ufw allow 161/udp comment 'LibreNMS SNMP'
  ufw allow 514/udp comment 'LibreNMS Syslog'
  ufw allow 10050/tcp comment 'LibreNMS Agent'
  info "UFW rules added (run 'ufw enable' to activate)"
elif command -v ufw &>/dev/null; then
  info "Skipping firewall configuration as requested"
else
  warn "UFW not installed, skipping firewall config"
fi

#-------------------------- Services ------------------------------------
info "Starting Docker Compose services..."
info "NOTE: This deployment serves HTTP only. For HTTPS, place a reverse proxy"
info "(nginx, Traefik, Caddy) in front of the container on port 80."
$DOCKER_COMPOSE up -d

info "Waiting for database to be ready..."
for i in $(seq 1 60); do
  if $DOCKER_COMPOSE exec -T db mysqladmin ping -h"localhost" -u"root" -p"${DB_ROOT_PASSWORD}" &>/dev/null; then
    info "Database is ready"
    break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "Database did not become ready in time"
done

info "Waiting for LibreNMS web UI to be ready..."
for i in $(seq 1 60); do
  if $DOCKER_COMPOSE exec -T librenms curl -f http://localhost:8000 &>/dev/null; then
    info "LibreNMS web UI is ready"
    break
  fi
  sleep 3
  [[ $i -eq 60 ]] && die "LibreNMS did not become ready in time"
done

#-------------------------- Initialize ----------------------------------
info "Running database migrations..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan migrate --force || warn "Migration had warnings"
info "Seeding database..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan librenms:seed || warn "Seed had warnings"
info "Creating admin user..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan librenms:adduser \
  --name="admin" --pass="$ADMIN_PASS" --email="$ADMIN_EMAIL" --role=10 || warn "Admin user may already exist"

#-------------------------- Summary -------------------------------------
cat <<EOF

============================================================
LibreNMS deployment complete!

Web UI: ${BASE_URL:-http://$(hostname -I | awk '{print $1}')/}
Admin: admin / ${ADMIN_PASS}
Email: ${ADMIN_EMAIL}

Database credentials: .env (chmod 600)
Credential file: ${SAVE_CREDS:-<none>}
Log: ${LOG_FILE}

IMPORTANT NOTES:
1. HTTPS is NOT configured. This deployment serves plain HTTP.
   Place a reverse proxy (nginx, Caddy, Traefik) in front of the
   container to add TLS termination.
2. Change the admin password immediately via the web UI.
3. For SNMP auto-discovery, configure community strings on
   your network devices and point them to this host.
============================================================
EOF
exit 0
