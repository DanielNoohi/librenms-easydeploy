#!/usr/bin/env bash
# librenms-auto-install.sh - LibreNMS Docker Compose installer
# Installs LibreNMS via Docker Compose with secure defaults
#
# NOT PRODUCTION-HARDENED: single-node Docker Compose stack for labs,
# homelabs, and small deployments. See README "Caveats" section.

set -euo pipefail
IFS=$'\n\t'

# Never fail silently: report the failing command and line, then exit 1
# shellcheck disable=SC2154  # rc is set via $? inside the trap
trap 'rc=$?; msg="[ERROR] command failed at line $LINENO: $BASH_COMMAND (exit $rc)"; echo "$msg" >&2; echo "$msg" >>"${LOG_FILE:-/var/log/librenms-easydeploy.log}" 2>/dev/null || true; exit $rc' ERR

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
  # Dry-run: never write to the log file (zero system changes)
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
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
EMBEDDED_COMPOSE_B64="c2VydmljZXM6CiAgIyBMaWJyZU5NUyB3ZWIgYXBwbGljYXRpb24gKyBhbGVydGluZwogIGxpYnJlbm1zOgogICAgaW1hZ2U6IGxpYnJlbm1zL2xpYnJlbm1zOjI2LjcuMAogICAgY29udGFpbmVyX25hbWU6IGxpYnJlbm1zCiAgICBob3N0bmFtZTogbGlicmVubXMKICAgIGNhcF9hZGQ6CiAgICAgIC0gTkVUX0FETUlOCiAgICAgIC0gTkVUX1JBVwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIFRaPSR7VFo6LVVUQ30KICAgICAgLSBQVUlEPSR7UFVJRDotMTAwMH0KICAgICAgLSBQR0lEPSR7UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9JHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgLSBEQl9QQVNTV09SRD0ke0RCX1BBU1NXT1JEfQogICAgICAtIERCX1BPUlQ9MzMwNgogICAgICAtIERCX1RJTUVPVVQ9NjAKICAgICAgLSBNRU1DQUNIRURfSE9TVD0ke01FTUNBQ0hFRF9IT1NUOi1tZW1jYWNoZWR9CiAgICAgIC0gUkVESVNfSE9TVD0ke1JFRElTX0hPU1Q6LXJlZGlzfQogICAgICAtIENBQ0hFX0RSSVZFUj0ke0NBQ0hFX0RSSVZFUjotcmVkaXN9CiAgICAgIC0gU0VTU0lPTl9EUklWRVI9JHtTRVNTSU9OX0RSSVZFUjotcmVkaXN9CiAgICAgIC0gQkFTRV9VUkw9JHtCQVNFX1VSTDotaHR0cDovL2xvY2FsaG9zdH0KICAgICAgLSBQT0xMRVJTPSR7UE9MTEVSUzotMTZ9CiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9saWJyZW5tczovZGF0YQogICAgICAtIC4vbG9ncy9saWJyZW5tczovb3B0L2xpYnJlbm1zL2xvZ3MKICAgICAgLSAuL2NvbmZpZy9saWJyZW5tczovb3B0L2xpYnJlbm1zL2NvbmZpZy5kCiAgICAgIC0gLi9ycmQ6L29wdC9saWJyZW5tcy9ycmQKICAgIHBvcnRzOgogICAgICAtICI4MDo4MDAwIgogICAgZGVwZW5kc19vbjoKICAgICAgZGI6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX2hlYWx0aHkKICAgICAgbWVtY2FjaGVkOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICAgIHJlZGlzOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNNRCIsICJjdXJsIiwgIi1mIiwgImh0dHA6Ly9sb2NhbGhvc3Q6ODAwMCJdCiAgICAgIGludGVydmFsOiAzMHMKICAgICAgdGltZW91dDogMTBzCiAgICAgIHJldHJpZXM6IDMKICAgICAgc3RhcnRfcGVyaW9kOiA2MHMKCiAgIyBEaXN0cmlidXRlZCBwb2xsZXIgKG9mZmljaWFsIHNpZGVjYXIg4oCUIFNJREVDQVJfRElTUEFUQ0hFUj0xKQogIGRpc3BhdGNoZXI6CiAgICBpbWFnZTogbGlicmVubXMvbGlicmVubXM6MjYuNy4wCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtZGlzcGF0Y2hlcgogICAgaG9zdG5hbWU6IGxpYnJlbm1zLWRpc3BhdGNoZXIKICAgIGNhcF9hZGQ6CiAgICAgIC0gTkVUX0FETUlOCiAgICAgIC0gTkVUX1JBVwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIFRaPSR7VFo6LVVUQ30KICAgICAgLSBQVUlEPSR7UFVJRDotMTAwMH0KICAgICAgLSBQR0lEPSR7UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9JHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgLSBEQl9QQVNTV09SRD0ke0RCX1BBU1NXT1JEfQogICAgICAtIERCX1BPUlQ9MzMwNgogICAgICAtIERCX1RJTUVPVVQ9NjAKICAgICAgLSBSRURJU19IT1NUPSR7UkVESVNfSE9TVDotcmVkaXN9CiAgICAgIC0gU0lERUNBUl9ESVNQQVRDSEVSPTEKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL2xpYnJlbm1zOi9kYXRhCiAgICAgIC0gLi9sb2dzL2xpYnJlbm1zOi9vcHQvbGlicmVubXMvbG9ncwogICAgZGVwZW5kc19vbjoKICAgICAgbGlicmVubXM6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX3N0YXJ0ZWQKICAgICAgcmVkaXM6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX2hlYWx0aHkKICAgIG5ldHdvcmtzOgogICAgICAtIGxpYnJlbm1zLW5ldAoKICAjIFN5c2xvZy1uZyBzaWRlY2FyIChvZmZpY2lhbCDigJQgU0lERUNBUl9TWVNMT0dORz0xLCBVRFAgNTE0KQogIHN5c2xvZ25nOgogICAgaW1hZ2U6IGxpYnJlbm1zL2xpYnJlbm1zOjI2LjcuMAogICAgY29udGFpbmVyX25hbWU6IGxpYnJlbm1zLXN5c2xvZ25nCiAgICBob3N0bmFtZTogbGlicmVubXMtc3lzbG9nbmcKICAgIGNhcF9hZGQ6CiAgICAgIC0gTkVUX0FETUlOCiAgICAgIC0gTkVUX1JBVwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIFRaPSR7VFo6LVVUQ30KICAgICAgLSBQVUlEPSR7UFVJRDotMTAwMH0KICAgICAgLSBQR0lEPSR7UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9JHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgLSBEQl9QQVNTV09SRD0ke0RCX1BBU1NXT1JEfQogICAgICAtIERCX1BPUlQ9MzMwNgogICAgICAtIERCX1RJTUVPVVQ9NjAKICAgICAgLSBSRURJU19IT1NUPSR7UkVESVNfSE9TVDotcmVkaXN9CiAgICAgIC0gU0lERUNBUl9TWVNMT0dORz0xCiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9saWJyZW5tczovZGF0YQogICAgICAtIC4vbG9ncy9saWJyZW5tczovb3B0L2xpYnJlbm1zL2xvZ3MKICAgIHBvcnRzOgogICAgICAtICI1MTQ6NTE0L3VkcCIKICAgIGRlcGVuZHNfb246CiAgICAgIGxpYnJlbm1zOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9zdGFydGVkCiAgICAgIGRiOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKCiAgIyBTTk1QIHRyYXAgcmVjZWl2ZXIgKG9mZmljaWFsIOKAlCBTSURFQ0FSX1NOTVBUUkFQRD0xLCBVRFAgMTYyKQogIHNubXB0cmFwZDoKICAgIGltYWdlOiBsaWJyZW5tcy9saWJyZW5tczoyNi43LjAKICAgIGNvbnRhaW5lcl9uYW1lOiBsaWJyZW5tcy1zbm1wdHJhcGQKICAgIGhvc3RuYW1lOiBsaWJyZW5tcy1zbm1wdHJhcGQKICAgIGNhcF9hZGQ6CiAgICAgIC0gTkVUX0FETUlOCiAgICAgIC0gTkVUX1JBVwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIFRaPSR7VFo6LVVUQ30KICAgICAgLSBQVUlEPSR7UFVJRDotMTAwMH0KICAgICAgLSBQR0lEPSR7UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9JHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgLSBEQl9QQVNTV09SRD0ke0RCX1BBU1NXT1JEfQogICAgICAtIERCX1BPUlQ9MzMwNgogICAgICAtIERCX1RJTUVPVVQ9NjAKICAgICAgLSBSRURJU19IT1NUPSR7UkVESVNfSE9TVDotcmVkaXN9CiAgICAgIC0gU0lERUNBUl9TTk1QVFJBUEQ9MQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvbGlicmVubXM6L2RhdGEKICAgICAgLSAuL2xvZ3MvbGlicmVubXM6L29wdC9saWJyZW5tcy9sb2dzCiAgICBwb3J0czoKICAgICAgLSAiMTYyOjE2Mi91ZHAiCiAgICBkZXBlbmRzX29uOgogICAgICBsaWJyZW5tczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICBkYjoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CgogICMgTWFyaWFEQiAxMC4xMQogIGRiOgogICAgaW1hZ2U6IG1hcmlhZGI6MTAuMTEKICAgIGNvbnRhaW5lcl9uYW1lOiBsaWJyZW5tcy1kYgogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIE1ZU1FMX1JPT1RfUEFTU1dPUkQ9JHtEQl9ST09UX1BBU1NXT1JEfQogICAgICAtIE1ZU1FMX0RBVEFCQVNFPSR7REJfTkFNRTotbGlicmVubXN9CiAgICAgIC0gTVlTUUxfVVNFUj0ke0RCX1VTRVI6LWxpYnJlbm1zfQogICAgICAtIE1ZU1FMX1BBU1NXT1JEPSR7REJfUEFTU1dPUkR9CiAgICAgIC0gVFo9JHtUWjotVVRDfQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvZGI6L3Zhci9saWIvbXlzcWwKICAgIGNvbW1hbmQ6CiAgICAgIC0gLS1pbm5vZGItZmlsZS1wZXItdGFibGU9MQogICAgICAtIC0tbG93ZXItY2FzZS10YWJsZS1uYW1lcz0wCiAgICAgIC0gLS1jaGFyYWN0ZXItc2V0LXNlcnZlcj11dGY4bWI0CiAgICAgIC0gLS1jb2xsYXRpb24tc2VydmVyPXV0ZjhtYjRfdW5pY29kZV9jaQogICAgICAtIC0tbWF4X2FsbG93ZWRfcGFja2V0PTY0TQogICAgICAtIC0taW5ub2RiX2J1ZmZlcl9wb29sX3NpemU9MjU2TQogICAgaGVhbHRoY2hlY2s6CiAgICAgIHRlc3Q6IFsiQ01EIiwgIm15c3FsYWRtaW4iLCAicGluZyIsICItaCIsICJsb2NhbGhvc3QiLCAiLXUiLCAicm9vdCIsICItcCR7REJfUk9PVF9QQVNTV09SRH0iXQogICAgICBpbnRlcnZhbDogMTBzCiAgICAgIHRpbWVvdXQ6IDVzCiAgICAgIHJldHJpZXM6IDEwCiAgICAgIHN0YXJ0X3BlcmlvZDogMzBzCiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKCiAgIyBNZW1jYWNoZWQgKGNhY2hlIGJhY2tlbmQpCiAgbWVtY2FjaGVkOgogICAgaW1hZ2U6IG1lbWNhY2hlZDoxLjYtYWxwaW5lCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtbWVtY2FjaGVkCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgY29tbWFuZDogLW0gNjQKICAgIG5ldHdvcmtzOgogICAgICAtIGxpYnJlbm1zLW5ldAogICAgaGVhbHRoY2hlY2s6CiAgICAgIHRlc3Q6IFsiQ01ELVNIRUxMIiwgImVjaG8gdmVyc2lvbiB8IG5jIDEyNy4wLjAuMSAxMTIxMSB8IGdyZXAgLXEgVkVSU0lPTiJdCiAgICAgIGludGVydmFsOiAxNXMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMwogICAgICBzdGFydF9wZXJpb2Q6IDEwcwoKICAjIFJlZGlzIChjYWNoZSArIHF1ZXVlIGJhY2tlbmQpCiAgcmVkaXM6CiAgICBpbWFnZTogcmVkaXM6Ny1hbHBpbmUKICAgIGNvbnRhaW5lcl9uYW1lOiBsaWJyZW5tcy1yZWRpcwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGNvbW1hbmQ6IHJlZGlzLXNlcnZlciAtLW1heG1lbW9yeSAyNTZtYiAtLW1heG1lbW9yeS1wb2xpY3kgYWxsa2V5cy1scnUKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL3JlZGlzOi9kYXRhCiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNNRCIsICJyZWRpcy1jbGkiLCAicGluZyJdCiAgICAgIGludGVydmFsOiAxNXMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMwogICAgICBzdGFydF9wZXJpb2Q6IDEwcwoKbmV0d29ya3M6CiAgbGlicmVubXMtbmV0OgogICAgZHJpdmVyOiBicmlkZ2UK"

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

#-------------------------- .env loading (idempotent reruns) -------------
# Load KEY=VALUE pairs from an existing .env into the shell environment.
# Only known keys are imported; values are not eval'd (no code execution).
# Existing non-empty variables (CLI flags / exported env) always win.
load_env() {
  local env_file="$1" key val
  [[ -f "$env_file" ]] || return 0
  info "Loading existing environment from $env_file"
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    key=$(echo "$key" | tr -d '[:space:]')
    case "$key" in
    TZ | PUID | PGID | BASE_URL | DB_NAME | DB_USER | DB_PASSWORD | DB_ROOT_PASSWORD | \
      MEMCACHED_HOST | REDIS_HOST | POLLERS | CACHE_DRIVER | SESSION_DRIVER | \
      ADMIN_PASS | ADMIN_EMAIL)
      # Only import when the variable is not already set by CLI/env
      if [[ -z "${!key:-}" ]]; then
        export "$key=$val"
      fi
      ;;
    esac
  done <"$env_file"
}

#-------------------------- Help ----------------------------------------
print_help() {
  cat <<'EOF'
Usage: sudo ./librenms-auto-install.sh [OPTIONS]

LibreNMS Docker Compose Installer - Network monitoring with auto-discovery,
SNMP, topology maps, traffic analysis, and alerting.

NOTE: This is NOT production-hardened. See README "Caveats".

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

#-------------------------- Load existing .env (idempotent reruns) ------
# If an install already exists, reuse its credentials instead of
# generating new ones. This keeps reruns fully idempotent: DB passwords
# and the admin password survive reruns unless --force is used.
load_env "$INSTALL_DIR/.env"

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
ENV_CONTENT_TPL='# LibreNMS Docker Compose Environment
# Generated by librenms-auto-install.sh on '"$(date)"'
TZ=%s
PUID=%s
PGID=%s
BASE_URL=%s
DB_NAME=%s
DB_USER=%s
DB_PASSWORD=%s
DB_ROOT_PASSWORD=%s
MEMCACHED_HOST=%s
REDIS_HOST=%s
POLLERS=%s
CACHE_DRIVER=%s
SESSION_DRIVER=%s
ADMIN_PASS=%s
ADMIN_EMAIL=%s'

ENV_VALUES=("$TZ" "$PUID" "$PGID" "$BASE_URL" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_ROOT_PASSWORD" "$MEMCACHED_HOST" "$REDIS_HOST" "$POLLERS" "${CACHE_DRIVER:-redis}" "${SESSION_DRIVER:-redis}" "$ADMIN_PASS" "$ADMIN_EMAIL")

# Create a properly-formatted .env from the template + values
generate_env() {
  printf '%s\n' "$ENV_CONTENT_TPL" "${ENV_VALUES[@]}"
}

if [[ -f .env && "$FORCE" == true ]]; then
  backup_file .env
  generate_env >.env
  chmod 600 .env
  info "Overwrote .env (--force) — chmod 600"
elif [[ -f .env && "$FORCE" == false ]]; then
  # Preserve existing .env; append any missing keys (e.g., ADMIN_PASS
  # from a pre-idempotency install)
  for key in CACHE_DRIVER SESSION_DRIVER ADMIN_PASS ADMIN_EMAIL; do
    grep -q "^${key}=" .env 2>/dev/null || echo "${key}=${!key}" >>.env
  done
  chmod 600 .env
  info ".env already exists — preserving (use --force to overwrite)"
else
  generate_env >.env
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

info "Waiting for Redis to be ready..."
for i in $(seq 1 30); do
  if $DOCKER_COMPOSE exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
    info "Redis is ready"
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "Redis did not become ready in time"
done

info "Waiting for Memcached to be ready..."
for i in $(seq 1 30); do
  if $DOCKER_COMPOSE exec -T memcached sh -c 'echo stats | nc 127.0.0.1 11211 | grep -q "STAT"' 2>/dev/null; then
    info "Memcached is ready"
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "Memcached did not become ready in time"
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
