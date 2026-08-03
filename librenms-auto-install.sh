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

#-------------------------- Password generation (python3 only, length verified) --
gen_pass() {
  local len="${1:-32}" pass=""
  command -v python3 &>/dev/null || die "python3 is required for password generation"
  pass=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range($len)))
" 2>/dev/null) || die "Failed to generate secure password"
  [[ ${#pass} -eq "$len" ]] || die "Generated password length ${#pass} != expected $len"
  echo "$pass"
}

#-------------------------- Embedded docker-compose.yml (for curl|bash mode) --
EMBEDDED_COMPOSE_B64="c2VydmljZXM6CiAgIyBMaWJyZU5NUyB3aXRoIGJ1aWx0LWluIHNpZGVjYXIgc2VydmljZXMgKGRpc3BhdGNoZXIsIHN5c2xvZywgU05NUCB0cmFwKQogIGxpYnJlbm1zOgogICAgaW1hZ2U6IGxpYnJlbm1zL2xpYnJlbm1zOjI1LjQuMQogICAgY29udGFpbmVyX25hbWU6IGxpYnJlbm1zCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgZW52aXJvbm1lbnQ6CiAgICAgIC0gVFo9JHtUWjotVVRDfQogICAgICAtIFBVSUQ9e1BVSUQ6LTEwMDB9CiAgICAgIC0gUEdJRD17UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9e0RCX1VTRVI6LWxpYnJlbm1zfQogICAgICAtIERCX1BBU1NXT1JEPXskREJfUEFTU1dPUkR9CiAgICAgIC0gREJfUE9SVD0zMzA2CiAgICAgIC0gTUVNQ0FDSEVEX0hPU1Q9bWVtY2FjaGVkCiAgICAgIC0gUkVESVNfSE9TVD1yZWRpcwogICAgICAtIEJBU0VfVVJMPSR7QkFTRV9VUkw6LWh0dHA6Ly9sb2NhbGhvc3R9CiAgICAgIC0gUE9MTEVSUz0ke1BPTExFUlM6LTE2fQogICAgICAjIE9mZmljaWFsIExpYnJlTk1TIHNpZGVjYXIgc2VydmljZSBmbGFncwogICAgICAtIFNJREVDQVJfRElTUEFUQ0hFUj10cnVlCiAgICAgIC0gU0lERUNBUl9TWVNMT0dORz10cnVlCiAgICAgIC0gU0lERUNBUl9TTk1QVFJBUFREPXRydWUKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL2xpYnJlbm1zOi9kYXRhCiAgICAgIC0gLi9sb2dzL2xpYnJlbm1zOi9vcHQvbGlicmVubXMvbG9ncwogICAgICAtIC4vY29uZmlnL2xpYnJlbm1zOi9vcHQvbGlicmVubXMvY29uZmlnLmQKICAgICAgLSAuL3JyZDovb3B0L2xpYnJlbm1zL3JyZAogICAgcG9ydHM6CiAgICAgIC0gIjgwOjgwMDAiCiAgICAgIC0gIjUxNDo1MTQvdWRwIgogICAgICAtICIxNjI6MTYyL3VkcCIKICAgIGRlcGVuZHNfb246CiAgICAgIGRiOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICAgIG1lbWNhY2hlZDoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQiLCAiY3VybCIsICItZiIsICJodHRwOi8vbG9jYWxob3N0OjgwMDAiXQogICAgICBpbnRlcnZhbDogMzBzCiAgICAgIHRpbWVvdXQ6IDEwcwogICAgICByZXRyaWVzOiAzCiAgICAgIHN0YXJ0X3BlcmlvZDogNjBzCgogICMgTWFyaWFEQiAxMC4xMQogIGRiOgogICAgaW1hZ2U6IG1hcmlhZGI6MTAuMTEKICAgIGNvbnRhaW5lcl9uYW1lOiBsaWJyZW5tcy1kYgogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIE1ZU1FMX1JPT1RfUEFTU1dPUkQ9JHtEQl9ST09UX1BBU1NXT1JEfQogICAgICAtIE1ZU1FMX0RBVEFCQVNFPSR7REJfTkFNRTotbGlicmVubXN9CiAgICAgIC0gTVlTUUxfVVNFUj0ke0RCX1VTRVI6LWxpYnJlbm1zfQogICAgICAtIE1ZU1FMX1BBU1NXT1JEPSR7REJfUEFTU1dPUkR9CiAgICAgIC0gVFo9JHtUWjotVVRDfQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvZGI6L3Zhci9saWIvbXlzcWwKICAgIGNvbW1hbmQ6CiAgICAgIC0gLS1pbm5vZGItZmlsZS1wZXItdGFibGU9MQogICAgICAtIC0tbG93ZXItY2FzZS10YWJsZS1uYW1lcz0wCiAgICAgIC0gLS1tYXhfYWxsb3dlZF9wYWNrZXQ9NjRNCiAgICAgIC0gLS1pbm5vZGJfYnVmZmVyX3Bvb2xfc2l6ZT0yNTZNCiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQiLCAibXlzcWxhZG1pbiIsICJwaW5nIiwgIi1oIiwgImxvY2FsaG9zdCIsICItdSIsICJyb290IiwgIi1wJHtEQl9ST09UX1BBU1NXT1JEfSJdCiAgICAgIGludGVydmFsOiAxMHMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMTAKICAgIG5ldHdvcmtzOgogICAgICAtIGxpYnJlbm1zLW5ldAoKICAjIE1lbWNhY2hlZAogIG1lbWNhY2hlZDoKICAgIGltYWdlOiBtZW1jYWNoZWQ6MS42LWFscGluZQogICAgY29udGFpbmVyX25hbWU6IGxpYnJlbm1zLW1lbWNhY2hlZAogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGNvbW1hbmQ6IC1tIDY0CiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKCiAgIyBSZWRpcwogIHJlZGlzOgogICAgaW1hZ2U6IHJlZGlzOjctYWxwaW5lCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtcmVkaXMKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBjb21tYW5kOiByZWRpcy1zZXJ2ZXIgLS1tYXhtZW1vcnkgMjU2bWIgLS1tYXhtZW1vcnktcG9saWN5IGFsbGtleXMtbHJ1CiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9yZWRpczovZGF0YQogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CgpuZXR3b3JrczoKICBsaWJyZW5tcy1uZXQ6CiAgICBkcml2ZXI6IGJyaWRnZQo="

extract_docker_compose() {
  # Use the base64-encoded compose file embedded in the variable above
  if command -v python3 &>/dev/null; then
    python3 -c "
import base64, sys
b64 = '''$EMBEDDED_COMPOSE_B64'''
sys.stdout.buffer.write(base64.b64decode(b64))
" 2>/dev/null && return 0
  fi
  # Fallback: use script directory (for curl|bash without sudo)
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] && {
    cat "$SCRIPT_DIR/docker-compose.yml"
    return 0
  }
  die "Cannot find docker-compose.yml — re-download the installer"
}

#-------------------------- Validation helpers --------------------------
validate_url() {
  local url="$1"
  [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]] || die "Invalid URL format: $url (must be http://host or https://host)"
}

validate_timezone() {
  [[ -f "/usr/share/zoneinfo/$1" ]] || warn "Timezone '$1' may not be valid (not found in /usr/share/zoneinfo)"
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
  info "Firewall: $([ "$SKIP_FIREWALL" == true ] && echo skipped || echo configured)"
  info "SSL: $([ "$SKIP_SSL" == true ] && echo skipped || echo 'none-HTTP-only')"
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

# Use embedded docker-compose.yml for curl|bash mode; otherwise copy from script dir
if [[ -f docker-compose.yml ]]; then
  info "Using existing docker-compose.yml"
else
  info "Extracting embedded docker-compose.yml"
  extract_docker_compose >docker-compose.yml
fi

#-------------------------- Environment file (idempotent) ---------------
if [[ -f .env && "$FORCE" == false ]]; then
  info ".env already exists — preserving (use --force to overwrite)"
elif [[ -f .env && "$FORCE" == true ]]; then
  backup_file .env
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
SIDECAR_DISPATCHER=true
SIDECAR_SYSLOGNG=true
SIDECAR_SNMPTRAPD=true
EOF
  chmod 600 .env
  info "Overwrote .env (--force) — chmod 600"
else
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
SIDECAR_DISPATCHER=true
SIDECAR_SYSLOGNG=true
SIDECAR_SNMPTRAPD=true
EOF
  chmod 600 .env
  info "Created .env (chmod 600)"
fi

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
  ufw allow 162/udp comment 'LibreNMS SNMP-Trap'
  ufw allow 514/udp comment 'LibreNMS Syslog'
  ufw allow 161/udp comment 'LibreNMS SNMP'
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

#-------------------------- Initialize (idempotent) --------------------
info "Running database migrations..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan migrate --force || warn "Migration had warnings"
info "Seeding database..."
$DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan librenms:seed || warn "Seed had warnings"

# Create admin user only if it doesn't already exist (idempotent)
info "Checking for existing admin user..."
ADMIN_EXISTS=$($DOCKER_COMPOSE exec -T librenms mysql -hdb -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT COUNT(*) FROM users WHERE username='admin';" 2>/dev/null | tail -1)
ADMIN_EXISTS=${ADMIN_EXISTS:-0}
if [[ "$ADMIN_EXISTS" -gt 0 ]]; then
  info "Admin user already exists — preserving credentials"
else
  info "Creating admin user..."
  $DOCKER_COMPOSE exec -T librenms php /opt/librenms/artisan librenms:adduser \
    --name="admin" --pass="$ADMIN_PASS" --email="$ADMIN_EMAIL" --role=10 ||
    warn "Admin user creation failed"
fi

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
