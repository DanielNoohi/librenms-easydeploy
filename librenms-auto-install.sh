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

gen_pass() {
    tr -dc 'A-Za-z0-9!@#$%&*()-_=+' </dev/urandom | head -c 32; echo
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

# Parse arguments
ARGS=$(getopt -o hd:u:t:p:s:nfD --long help,dir:,url:,timezone:,pollers:,save-creds:,non-interactive,force,dry-run,no-firewall,no-ssl,le-email:,db-name:,db-user: -- "$@") || {
    print_help
    exit 1
}
eval set -- "$ARGS"
while true; do
    case "$1" in
        -h|--help) print_help; exit 0 ;;
        -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
        -u|--url) BASE_URL="$2"; shift 2 ;;
        -t|--timezone) TZ="$2"; shift 2 ;;
        -p|--pollers) POLLERS="$2"; shift 2 ;;
        -s|--save-creds) SAVE_CREDS="$2"; shift 2 ;;
        -n|--non-interactive) NON_INTERACTIVE=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -D|--dry-run) DRY_RUN=true; shift ;;
        --no-firewall) SKIP_FIREWALL=true; shift ;;
        --no-ssl) SKIP_SSL=true; shift ;;
        --le-email) LE_EMAIL="$2"; shift 2 ;;
        --db-name) DB_NAME="$2"; shift 2 ;;
        --db-user) DB_USER="$2"; shift 2 ;;
        --) shift; break ;;
    esac
done

# Pre-flight checks
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

if ! command -v docker-compose &> /dev/null && ! command -v docker &> /dev/null; then
    die "Docker Compose is not installed. Please install Docker and Docker Compose."
fi

# Determine docker-compose command
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    DOCKER_COMPOSE="docker compose"
fi

# Validate required options
if [[ "$NON_INTERACTIVE" == true && -z "$BASE_URL" ]]; then
    die "Non-interactive mode requires --url"
fi

# Generate passwords if not set
if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD=$(gen_pass)
fi
if [[ -z "$DB_ROOT_PASSWORD" ]]; then
    DB_ROOT_PASSWORD=$(gen_pass)
fi
# Generate admin credentials for LibreNMS
if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS=$(gen_pass)
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
    # Try to extract hostname from BASE_URL, default to localhost
    if [[ -n "$BASE_URL" ]]; then
        # Remove protocol and port
        ADMIN_EMAIL="admin@$(echo "$BASE_URL" | sed -e 's|^[^/]*//||' -e 's/:.*//')"
    else
        ADMIN_EMAIL="admin@localhost"
    fi
fi

# Export variables for docker-compose
export TZ PUID PGID BASE_URL DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD MEMCACHED_HOST REDIS_HOST POLLERS ENABLE_SYSLOG ENABLE_SNMPTRAP ADMIN_PASS ADMIN_EMAIL

# Create install directory
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || die "Cannot access $INSTALL_DIR"

# Copy docker-compose.yml from script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f docker-compose.yml ]]; then
    if [[ "$DRY_RUN" == false ]]; then
        cp "$SCRIPT_DIR/docker-compose.yml" .
        info "Copied docker-compose.yml to $INSTALL_DIR"
    else
        info "[DRY-RUN] Would copy docker-compose.yml to $INSTALL_DIR"
    fi
fi

# Backup existing .env if present
if [[ -f .env && "$FORCE" == false ]]; then
    backup_file .env
fi

# Create .env file from template or defaults
if [[ "$DRY_RUN" == false ]]; then
    cat > .env <<EOF
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
    info "Created .env file"
else
    info "[DRY-RUN] Would create .env file"
fi

# Save credentials if requested
if [[ -n "$SAVE_CREDS" ]]; then
    if [[ "$DRY_RUN" == false ]]; then
        {
            echo "# LibreNMS credentials generated on $(date)"
            echo "MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
            echo "MYSQL_DATABASE=${DB_NAME}"
            echo "MYSQL_USER=${DB_USER}"
            echo "MYSQL_PASSWORD=${DB_PASSWORD}"
            echo "BASE_URL=${BASE_URL}"
            echo "TZ=${TZ}"
        } > "$SAVE_CREDS"
        chmod 600 "$SAVE_CREDS"
        info "Credentials saved to $SAVE_CREDS (chmod 600)"
    else
        info "[DRY-RUN] Would save credentials to $SAVE_CREDS"
    fi
fi

# Firewall configuration
if [[ "$SKIP_FIREWALL" == false && "$DRY_RUN" == false ]]; then
    if command -v ufw &> /dev/null; then
        info "Configuring UFW firewall..."
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 161/udp
        ufw allow 162/udp
        ufw allow 514/udp   # syslog
        info "UFW rules updated"
    else
        warn "UFW not installed, skipping firewall configuration"
    fi
elif [[ "$SKIP_FIREWALL" == true ]]; then
    info "Skipping firewall configuration as requested"
fi

# SSL configuration placeholder (for future Let's Encrypt integration)
if [[ "$SKIP_SSL" == false && -n "$LE_EMAIL" ]]; then
    info "Let's Encrypt email provided: $LE_EMAIL. You can obtain certificates manually using certbot or similar."
elif [[ "$SKIP_SSL" == true ]]; then
    info "SSL configuration skipped SSL configuration as requested"
fi

# Start services
if [[ "$DRY_RUN" == false ]]; then
    info "Starting Docker Compose services..."
    $DOCKER_COMPOSE up -d
else
    info "[DRY-RUN] Would run: $DOCKER_COMPOSE up -d"
fi

# Wait for database to be healthy
if [[ "$DRY_RUN" == false ]]; then
    info "Waiting for database to be ready..."
    for i in {1..30}; do
        if $DOCKER_COMPOSE exec db mysqladmin ping -h"localhost" -u"root" -p"${DB_ROOT_PASSWORD}" &> /dev/null; then
            info "Database is ready"
            break
        fi
        sleep 2
        if [[ $i -eq 30 ]]; then
            warn "Database did not become ready in time; continuing anyway"
        fi
    done
else
    info "[DRY-RUN] Would wait for database to be ready"
fi

# Initialize LibreNMS (first-time setup)
if [[ "$DRY_RUN" == false ]]; then
    info "Initializing LibreNMS database..."
    # Wait a bit more for services to be ready
    sleep 5
    # Run initial database migration and setup
    $DOCKER_COMPOSE exec librenms php /opt/librenms/artisan migrate --force || true
    $DOCKER_COMPOSE exec librenms php /opt/librenms/artisan librenms:seed || true
    # Create initial admin user if not exists
    $DOCKER_COMPOSE exec librenms php /opt/librenms/artisan librenms:user:add --name="admin" --pass="$ADMIN_PASS" --email="$ADMIN_EMAIL" --role=10 || true
else
    info "[DRY-RUN] Would initialize LibreNMS"
fi

# Final summary
if [[ "$DRY_RUN" == false ]]; then
    info "Installation complete!"
    info "LibreNMS is accessible at: ${BASE_URL:-http://$(hostname -I | awk '{print $1}')}"
    info "Default admin credentials:"
    info "  Username: admin"
    info "  Password: $ADMIN_PASS"
    info "  Email: $ADMIN_EMAIL"
    info "Database credentials saved in .env (chmod 600)"
    if [[ -n "$SAVE_CREDS" ]]; then
        info "Credentials also saved to: $SAVE_CREDS"
    fi
    info "Log file: $LOG_FILE"
else
    info "[DRY-RUN] Dry run completed"
fi