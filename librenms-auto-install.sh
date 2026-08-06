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
REDIS_PASSWORD=""
POLLERS=16
NON_INTERACTIVE=false
FORCE=false
DRY_RUN=false
SKIP_FIREWALL=false
SKIP_SSL=false
SAVE_CREDS=""
EMIT_ENV=""
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
EMBEDDED_COMPOSE_B64="c2VydmljZXM6CiAgIyBMaWJyZU5NUyB3ZWIgYXBwbGljYXRpb24gKyBhbGVydGluZwogIGxpYnJlbm1zOgogICAgaW1hZ2U6IGxpYnJlbm1zL2xpYnJlbm1zOjI2LjcuMAogICAgY29udGFpbmVyX25hbWU6IGxpYnJlbm1zCiAgICBob3N0bmFtZTogbGlicmVubXMKICAgIGNhcF9hZGQ6CiAgICAgIC0gTkVUX0FETUlOCiAgICAgIC0gTkVUX1JBVwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIFRaPSR7VFo6LVVUQ30KICAgICAgLSBQVUlEPSR7UFVJRDotMTAwMH0KICAgICAgLSBQR0lEPSR7UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9JHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgLSBEQl9QQVNTV09SRD0ke0RCX1BBU1NXT1JEfQogICAgICAtIERCX1BPUlQ9MzMwNgogICAgICAtIERCX1RJTUVPVVQ9NjAKICAgICAgLSBNRU1DQUNIRURfSE9TVD0ke01FTUNBQ0hFRF9IT1NUOi1tZW1jYWNoZWR9CiAgICAgIC0gUkVESVNfSE9TVD0ke1JFRElTX0hPU1Q6LXJlZGlzfQogICAgICAtIFJFRElTX1BBU1NXT1JEPSR7UkVESVNfUEFTU1dPUkR9CiAgICAgIC0gQ0FDSEVfRFJJVkVSPSR7Q0FDSEVfRFJJVkVSOi1yZWRpc30KICAgICAgLSBTRVNTSU9OX0RSSVZFUj0ke1NFU1NJT05fRFJJVkVSOi1yZWRpc30KICAgICAgLSBCQVNFX1VSTD0ke0JBU0VfVVJMOi1odHRwOi8vbG9jYWxob3N0fQogICAgICAtIFBPTExFUlM9JHtQT0xMRVJTOi0xNn0KICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL2xpYnJlbm1zOi9kYXRhCiAgICAgIC0gLi9sb2dzL2xpYnJlbm1zOi9vcHQvbGlicmVubXMvbG9ncwogICAgICAtIC4vY29uZmlnL2xpYnJlbm1zOi9vcHQvbGlicmVubXMvY29uZmlnLmQKICAgICAgLSAuL3JyZDovb3B0L2xpYnJlbm1zL3JyZAogICAgcG9ydHM6CiAgICAgIC0gIjgwOjgwMDAiCiAgICBkZXBlbmRzX29uOgogICAgICBkYjoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgICBtZW1jYWNoZWQ6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX2hlYWx0aHkKICAgICAgcmVkaXM6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX2hlYWx0aHkKICAgIG5ldHdvcmtzOgogICAgICAtIGxpYnJlbm1zLW5ldAogICAgaGVhbHRoY2hlY2s6CiAgICAgIHRlc3Q6IFsiQ01ELVNIRUxMIiwgIm5jIC16IGxvY2FsaG9zdCA4MDAwIHx8IGV4aXQgMSJdCiAgICAgIGludGVydmFsOiAzMHMKICAgICAgdGltZW91dDogMTBzCiAgICAgIHJldHJpZXM6IDMKICAgICAgc3RhcnRfcGVyaW9kOiA2MHMKCiAgIyBEaXN0cmlidXRlZCBwb2xsZXIgKG9mZmljaWFsIHNpZGVjYXIg4oCUIFNJREVDQVJfRElTUEFUQ0hFUj0xKQogIGRpc3BhdGNoZXI6CiAgICBpbWFnZTogbGlicmVubXMvbGlicmVubXM6MjYuNy4wCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtZGlzcGF0Y2hlcgogICAgaG9zdG5hbWU6IGxpYnJlbm1zLWRpc3BhdGNoZXIKICAgIGNhcF9hZGQ6CiAgICAgIC0gTkVUX0FETUlOCiAgICAgIC0gTkVUX1JBVwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIFRaPSR7VFo6LVVUQ30KICAgICAgLSBQVUlEPSR7UFVJRDotMTAwMH0KICAgICAgLSBQR0lEPSR7UEdJRDotMTAwMH0KICAgICAgLSBEQl9IT1NUPWRiCiAgICAgIC0gREJfTkFNRT0ke0RCX05BTUU6LWxpYnJlbm1zfQogICAgICAtIERCX1VTRVI9JHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgLSBEQl9QQVNTV09SRD0ke0RCX1BBU1NXT1JEfQogICAgICAtIERCX1BPUlQ9MzMwNgogICAgICAtIERCX1RJTUVPVVQ9NjAKICAgICAgLSBSRURJU19IT1NUPSR7UkVESVNfSE9TVDotcmVkaXN9CiAgICAgIC0gUkVESVNfUEFTU1dPUkQ9JHtSRURJU19QQVNTV09SRH0KICAgICAgLSBTSURFQ0FSX0RJU1BBVENIRVI9MQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvbGlicmVubXM6L2RhdGEKICAgICAgLSAuL2xvZ3MvbGlicmVubXM6L29wdC9saWJyZW5tcy9sb2dzCiAgICBkZXBlbmRzX29uOgogICAgICBsaWJyZW5tczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CgogICMgU3lzbG9nLW5nIHNpZGVjYXIgKG9mZmljaWFsIOKAlCBTSURFQ0FSX1NZU0xPR05HPTEsIFVEUCA1MTQpCiAgc3lzbG9nbmc6CiAgICBpbWFnZTogbGlicmVubXMvbGlicmVubXM6MjYuNy4wCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtc3lzbG9nbmcKICAgIGhvc3RuYW1lOiBsaWJyZW5tcy1zeXNsb2duZwogICAgY2FwX2FkZDoKICAgICAgLSBORVRfQURNSU4KICAgICAgLSBORVRfUkFXCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgZW52aXJvbm1lbnQ6CiAgICAgIC0gVFo9JHtUWjotVVRDfQogICAgICAtIFBVSUQ9JHtQVUlEOi0xMDAwfQogICAgICAtIFBHSUQ9JHtQR0lEOi0xMDAwfQogICAgICAtIERCX0hPU1Q9ZGIKICAgICAgLSBEQl9OQU1FPSR7REJfTkFNRTotbGlicmVubXN9CiAgICAgIC0gREJfVVNFUj0ke0RCX1VTRVI6LWxpYnJlbm1zfQogICAgICAtIERCX1BBU1NXT1JEPSR7REJfUEFTU1dPUkR9CiAgICAgIC0gREJfUE9SVD0zMzA2CiAgICAgIC0gREJfVElNRU9VVD02MAogICAgICAtIFJFRElTX0hPU1Q9JHtSRURJU19IT1NUOi1yZWRpc30KICAgICAgLSBSRURJU19QQVNTV09SRD0ke1JFRElTX1BBU1NXT1JEfQogICAgICAtIFNJREVDQVJfU1lTTE9HTkc9MQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvbGlicmVubXM6L2RhdGEKICAgICAgLSAuL2xvZ3MvbGlicmVubXM6L29wdC9saWJyZW5tcy9sb2dzCiAgICBwb3J0czoKICAgICAgLSAiNTE0OjUxNC91ZHAiCiAgICBkZXBlbmRzX29uOgogICAgICBsaWJyZW5tczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICBkYjoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CgogICMgU05NUCB0cmFwIHJlY2VpdmVyIChvZmZpY2lhbCDigJQgU0lERUNBUl9TTk1QVFJBUEQ9MSwgVURQIDE2MikKICBzbm1wdHJhcGQ6CiAgICBpbWFnZTogbGlicmVubXMvbGlicmVubXM6MjYuNy4wCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtc25tcHRyYXBkCiAgICBob3N0bmFtZTogbGlicmVubXMtc25tcHRyYXBkCiAgICBjYXBfYWRkOgogICAgICAtIE5FVF9BRE1JTgogICAgICAtIE5FVF9SQVcKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBUWj0ke1RaOi1VVEN9CiAgICAgIC0gUFVJRD0ke1BVSUQ6LTEwMDB9CiAgICAgIC0gUEdJRD0ke1BHSUQ6LTEwMDB9CiAgICAgIC0gREJfSE9TVD1kYgogICAgICAtIERCX05BTUU9JHtEQl9OQU1FOi1saWJyZW5tc30KICAgICAgLSBEQl9VU0VSPSR7REJfVVNFUjotbGlicmVubXN9CiAgICAgIC0gREJfUEFTU1dPUkQ9JHtEQl9QQVNTV09SRH0KICAgICAgLSBEQl9QT1JUPTMzMDYKICAgICAgLSBEQl9USU1FT1VUPTYwCiAgICAgIC0gUkVESVNfSE9TVD0ke1JFRElTX0hPU1Q6LXJlZGlzfQogICAgICAtIFJFRElTX1BBU1NXT1JEPSR7UkVESVNfUEFTU1dPUkR9CiAgICAgIC0gU0lERUNBUl9TTk1QVFJBUEQ9MQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvbGlicmVubXM6L2RhdGEKICAgICAgLSAuL2xvZ3MvbGlicmVubXM6L29wdC9saWJyZW5tcy9sb2dzCiAgICBwb3J0czoKICAgICAgLSAiMTYyOjE2Mi91ZHAiCiAgICBkZXBlbmRzX29uOgogICAgICBsaWJyZW5tczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICBkYjoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CgogICMgTWFyaWFEQiAxMC4xMQogIGRiOgogICAgaW1hZ2U6IG1hcmlhZGI6MTAuMTEKICAgIGNvbnRhaW5lcl9uYW1lOiBsaWJyZW5tcy1kYgogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIGVudmlyb25tZW50OgogICAgICAtIE1ZU1FMX1JPT1RfUEFTU1dPUkQ9JHtEQl9ST09UX1BBU1NXT1JEfQogICAgICAtIE1ZU1FMX0RBVEFCQVNFPSR7REJfTkFNRTotbGlicmVubXN9CiAgICAgIC0gTVlTUUxfVVNFUj0ke0RCX1VTRVI6LWxpYnJlbm1zfQogICAgICAtIE1ZU1FMX1BBU1NXT1JEPSR7REJfUEFTU1dPUkR9CiAgICAgIC0gVFo9JHtUWjotVVRDfQogICAgdm9sdW1lczoKICAgICAgLSAuL2RhdGEvZGI6L3Zhci9saWIvbXlzcWwKICAgIGNvbW1hbmQ6CiAgICAgIC0gLS1pbm5vZGItZmlsZS1wZXItdGFibGU9MQogICAgICAtIC0tbG93ZXItY2FzZS10YWJsZS1uYW1lcz0wCiAgICAgIC0gLS1jaGFyYWN0ZXItc2V0LXNlcnZlcj11dGY4bWI0CiAgICAgIC0gLS1jb2xsYXRpb24tc2VydmVyPXV0ZjhtYjRfdW5pY29kZV9jaQogICAgICAtIC0tbWF4X2FsbG93ZWRfcGFja2V0PTY0TQogICAgICAtIC0taW5ub2RiX2J1ZmZlcl9wb29sX3NpemU9MjU2TQogICAgaGVhbHRoY2hlY2s6CiAgICAgICMgT2ZmaWNpYWwgTWFyaWFEQiBpbWFnZSBoZWxwZXIg4oCUIG5vIHBhc3N3b3JkIG9uIHByb2Nlc3MgYXJndgogICAgICB0ZXN0OiBbIkNNRCIsICJoZWFsdGhjaGVjay5zaCIsICItLWNvbm5lY3QiLCAiLS1pbm5vZGJfaW5pdGlhbGl6ZWQiXQogICAgICBpbnRlcnZhbDogMTBzCiAgICAgIHRpbWVvdXQ6IDVzCiAgICAgIHJldHJpZXM6IDEwCiAgICAgIHN0YXJ0X3BlcmlvZDogMzBzCiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKCiAgIyBNZW1jYWNoZWQgKGNhY2hlIGJhY2tlbmQpCiAgbWVtY2FjaGVkOgogICAgaW1hZ2U6IG1lbWNhY2hlZDoxLjYtYWxwaW5lCiAgICBjb250YWluZXJfbmFtZTogbGlicmVubXMtbWVtY2FjaGVkCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgY29tbWFuZDogLW0gNjQKICAgIG5ldHdvcmtzOgogICAgICAtIGxpYnJlbm1zLW5ldAogICAgaGVhbHRoY2hlY2s6CiAgICAgIHRlc3Q6IFsiQ01ELVNIRUxMIiwgImVjaG8gdmVyc2lvbiB8IG5jIDEyNy4wLjAuMSAxMTIxMSB8IGdyZXAgLXEgVkVSU0lPTiJdCiAgICAgIGludGVydmFsOiAxNXMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMwogICAgICBzdGFydF9wZXJpb2Q6IDEwcwoKICAjIFJlZGlzIChjYWNoZSArIHF1ZXVlIGJhY2tlbmQpIOKAlCBwYXNzd29yZCByZXF1aXJlZCBvbiB0aGUgYnJpZGdlIG5ldHdvcmsKICByZWRpczoKICAgIGltYWdlOiByZWRpczo3LWFscGluZQogICAgY29udGFpbmVyX25hbWU6IGxpYnJlbm1zLXJlZGlzCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgZW52aXJvbm1lbnQ6CiAgICAgIC0gUkVESVNfUEFTU1dPUkQ9JHtSRURJU19QQVNTV09SRH0KICAgIGNvbW1hbmQ6CiAgICAgIC0gc2gKICAgICAgLSAtYwogICAgICAtIHJlZGlzLXNlcnZlciAtLXJlcXVpcmVwYXNzICIkJFJFRElTX1BBU1NXT1JEIiAtLW1heG1lbW9yeSAyNTZtYiAtLW1heG1lbW9yeS1wb2xpY3kgYWxsa2V5cy1scnUKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL3JlZGlzOi9kYXRhCiAgICBuZXR3b3JrczoKICAgICAgLSBsaWJyZW5tcy1uZXQKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNNRC1TSEVMTCIsICJyZWRpcy1jbGkgLWEgXCIkJFJFRElTX1BBU1NXT1JEXCIgcGluZyB8IGdyZXAgLXEgUE9ORyJdCiAgICAgIGludGVydmFsOiAxNXMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMwogICAgICBzdGFydF9wZXJpb2Q6IDEwcwoKbmV0d29ya3M6CiAgbGlicmVubXMtbmV0OgogICAgZHJpdmVyOiBicmlkZ2UK"

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
      MEMCACHED_HOST | REDIS_HOST | REDIS_PASSWORD | POLLERS | CACHE_DRIVER | SESSION_DRIVER | \
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
  -f, --force                Overwrite existing .env (backs up first; regenerates secrets)
  -D, --dry-run              Show actions without executing
  --no-firewall              Skip UFW firewall configuration
  --no-ssl                   Accepted for compatibility; stack is always HTTP-only
  --emit-env FILE            Write generated .env to FILE and exit (no Docker/root)
  --db-name NAME             Database name (default: librenms)
  --db-user USER             Database user (default: librenms)

TLS is not configured by this installer. Put nginx, Caddy, or Traefik in front.

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
  --emit-env)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --emit-env requires a file path"
    EMIT_ENV="$2"
    shift 2
    ;;
  --le-email)
    die "TLS/Let's Encrypt is not built into this installer. Place a reverse proxy in front (see README)."
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
REDIS_PASSWORD="${REDIS_PASSWORD:-$(gen_pass 32)}"
ADMIN_PASS="${ADMIN_PASS:-$(gen_pass 16)}"
[[ -z "$ADMIN_EMAIL" ]] && {
  DOMAIN="${BASE_URL#*://}"
  DOMAIN="${DOMAIN%%/*}"
  DOMAIN="${DOMAIN%%:*}"
  ADMIN_EMAIL="admin@${DOMAIN:-librenms.local}"
}

#-------------------------- Write .env helper (no printf %s traps) -------
write_env_file() {
  local dest="$1"
  cat >"$dest" <<EOF
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
REDIS_PASSWORD=${REDIS_PASSWORD}
POLLERS=${POLLERS}
CACHE_DRIVER=${CACHE_DRIVER:-redis}
SESSION_DRIVER=${SESSION_DRIVER:-redis}
ADMIN_PASS=${ADMIN_PASS}
ADMIN_EMAIL=${ADMIN_EMAIL}
EOF
}

# Test/CI helper: emit .env without root or Docker
if [[ -n "$EMIT_ENV" ]]; then
  write_env_file "$EMIT_ENV"
  chmod 600 "$EMIT_ENV" 2>/dev/null || true
  info "Wrote environment file to $EMIT_ENV"
  exit 0
fi

#-------------------------- Dry-run (before root/filesystem ops) -------
if [[ "$DRY_RUN" == true ]]; then
  info "=== DRY-RUN MODE (no changes) ==="
  info "Install dir: $INSTALL_DIR"
  info "Base URL: $BASE_URL"
  info "Timezone: $TZ | Pollers: $POLLERS"
  info "Firewall: $([ "$SKIP_FIREWALL" == true ] && echo skipped || echo configured)"
  if [[ "$SKIP_SSL" == true ]]; then
    info "SSL: always HTTP-only (--no-ssl noted)"
  else
    info "SSL: always HTTP-only"
  fi
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
if [[ -f .env && "$FORCE" == true ]]; then
  backup_file .env
  write_env_file .env
  chmod 600 .env
  info "Overwrote .env (--force) — chmod 600"
elif [[ -f .env && "$FORCE" == false ]]; then
  # Preserve existing .env; append any missing keys (e.g., REDIS_PASSWORD
  # from a pre-hardening install)
  for key in CACHE_DRIVER SESSION_DRIVER ADMIN_PASS ADMIN_EMAIL REDIS_PASSWORD; do
    grep -q "^${key}=" .env 2>/dev/null || echo "${key}=${!key}" >>.env
  done
  chmod 600 .env
  info ".env already exists — preserving (use --force to overwrite)"
else
  write_env_file .env
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
  # SNMP polling is outbound from this host; no inbound 161/udp rule needed
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
  if $DOCKER_COMPOSE exec -T -e MYSQL_PWD="${DB_ROOT_PASSWORD}" db mysqladmin ping -h"localhost" -u"root" &>/dev/null; then
    info "Database is ready"
    break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "Database did not become ready in time"
done

info "Waiting for Redis to be ready..."
for i in $(seq 1 30); do
  if $DOCKER_COMPOSE exec -T -e REDISCLI_AUTH="${REDIS_PASSWORD}" redis redis-cli ping 2>/dev/null | grep -q PONG; then
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
ADMIN_EXISTS=$($DOCKER_COMPOSE exec -T -e MYSQL_PWD="$DB_PASSWORD" librenms mysql -hdb -u"$DB_USER" "$DB_NAME" -e "SELECT COUNT(*) FROM users WHERE username='admin';" 2>/dev/null | tail -1)
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
