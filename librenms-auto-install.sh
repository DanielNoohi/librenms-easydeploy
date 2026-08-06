#!/usr/bin/env bash
# librenms-auto-install.sh - LibreNMS Docker Compose installer
# Installs LibreNMS via Docker Compose with secure defaults
#
# NOT PRODUCTION-HARDENED: single-node Docker Compose stack for labs,
# homelabs, and small deployments. See README "Know before you install".

set -euo pipefail
IFS=$'\n\t'

# Never fail silently. Do not log BASH_COMMAND because it may contain secrets.
# shellcheck disable=SC2154  # rc is set via $? inside the trap
trap 'rc=$?; msg="[ERROR] command failed at line $LINENO (exit $rc)"; echo "$msg" >&2; echo "$msg" >>"${LOG_FILE:-/var/log/librenms-easydeploy.log}" 2>/dev/null || true; exit $rc' ERR

#-------------------------- Inputs / defaults ---------------------------
# Keep configurable values empty until after argument parsing and load_env().
# This gives the intended precedence: CLI/exported env > existing .env > default.
INSTALL_DIR="${INSTALL_DIR:-/opt/librenms-easydeploy}"
TZ="${TZ:-}"
PUID="${PUID:-}"
PGID="${PGID:-}"
BASE_URL="${BASE_URL:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
REDIS_HOST="${REDIS_HOST:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
POLLERS="${POLLERS:-}"
CACHE_DRIVER="${CACHE_DRIVER:-}"
SESSION_DRIVER="${SESSION_DRIVER:-}"
LIBRENMS_SNMP_COMMUNITY="${LIBRENMS_SNMP_COMMUNITY:-}"
SNMP_USER="${SNMP_USER:-}"
SNMP_AUTH="${SNMP_AUTH:-}"
SNMP_PRIV="${SNMP_PRIV:-}"
SNMP_ENGINEID="${SNMP_ENGINEID:-}"
NON_INTERACTIVE=false
FORCE=false
DRY_RUN=false
SKIP_FIREWALL=false
SKIP_SSL=false
SAVE_CREDS=""
EMIT_ENV=""
ADMIN_PASS="${ADMIN_PASS:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
DIR_SET=false
URL_SET=false
TZ_SET=false
POLLERS_SET=false
DB_NAME_SET=false
DB_USER_SET=false

#-------------------------- Logging -------------------------------------
LOG_FILE="/var/log/librenms-easydeploy.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)_$$"

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

gen_hex() {
  local bytes="${1:-10}"
  command -v python3 &>/dev/null || die "python3 is required for secret generation"
  python3 -c "import secrets; print(secrets.token_hex($bytes))" ||
    die "Failed to generate hexadecimal secret"
}

#-------------------------- Embedded docker-compose.yml (for curl|bash mode) --
EMBEDDED_COMPOSE_B64="bmFtZTogbGlicmVubXMtZWFzeWRlcGxveQoKeC1saWJyZW5tcy1lbnZpcm9ubWVudDogJmxpYnJlbm1zLWVudmlyb25tZW50CiAgVFo6ICR7VFo6LVVUQ30KICBQVUlEOiAke1BVSUQ6LTEwMDB9CiAgUEdJRDogJHtQR0lEOi0xMDAwfQogIERCX0hPU1Q6IGRiCiAgREJfTkFNRTogJHtEQl9OQU1FOi1saWJyZW5tc30KICBEQl9VU0VSOiAke0RCX1VTRVI6LWxpYnJlbm1zfQogIERCX1BBU1NXT1JEOiAke0RCX1BBU1NXT1JEOj9EQl9QQVNTV09SRCBpcyByZXF1aXJlZH0KICBEQl9QT1JUOiAiMzMwNiIKICBEQl9USU1FT1VUOiAiNjAiCiAgUkVESVNfSE9TVDogJHtSRURJU19IT1NUOi1yZWRpc30KICBSRURJU19QQVNTV09SRDogJHtSRURJU19QQVNTV09SRDo/UkVESVNfUEFTU1dPUkQgaXMgcmVxdWlyZWR9CiAgQ0FDSEVfRFJJVkVSOiAke0NBQ0hFX0RSSVZFUjotcmVkaXN9CiAgU0VTU0lPTl9EUklWRVI6ICR7U0VTU0lPTl9EUklWRVI6LXJlZGlzfQogIExJQlJFTk1TX1NOTVBfQ09NTVVOSVRZOiAke0xJQlJFTk1TX1NOTVBfQ09NTVVOSVRZOj9MSUJSRU5NU19TTk1QX0NPTU1VTklUWSBpcyByZXF1aXJlZH0KCngtbGlicmVubXMtc2VydmljZTogJmxpYnJlbm1zLXNlcnZpY2UKICBpbWFnZTogbGlicmVubXMvbGlicmVubXM6MjYuNy4wCiAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICBjYXBfYWRkOgogICAgLSBORVRfQURNSU4KICAgIC0gTkVUX1JBVwogIHZvbHVtZXM6CiAgICAtIC4vZGF0YS9saWJyZW5tczovZGF0YQogIG5ldHdvcmtzOgogICAgLSBsaWJyZW5tcy1uZXQKICBsb2dnaW5nOgogICAgZHJpdmVyOiBqc29uLWZpbGUKICAgIG9wdGlvbnM6CiAgICAgIG1heC1zaXplOiAxMG0KICAgICAgbWF4LWZpbGU6ICIzIgoKc2VydmljZXM6CiAgbGlicmVubXM6CiAgICA8PDogKmxpYnJlbm1zLXNlcnZpY2UKICAgIGhvc3RuYW1lOiBsaWJyZW5tcwogICAgZW52aXJvbm1lbnQ6CiAgICAgIDw8OiAqbGlicmVubXMtZW52aXJvbm1lbnQKICAgICAgTElCUkVOTVNfQkFTRV9VUkw6ICR7TElCUkVOTVNfQkFTRV9VUkw6LS99CiAgICBwb3J0czoKICAgICAgLSAiODA6ODAwMCIKICAgIGRlcGVuZHNfb246CiAgICAgIGRiOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICAgIHJlZGlzOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQiLCAiY3VybCIsICItZnNTIiwgImh0dHA6Ly9sb2NhbGhvc3Q6ODAwMC8iXQogICAgICBpbnRlcnZhbDogMTVzCiAgICAgIHRpbWVvdXQ6IDVzCiAgICAgIHJldHJpZXM6IDEyCiAgICAgIHN0YXJ0X3BlcmlvZDogOTBzCgogIGRpc3BhdGNoZXI6CiAgICA8PDogKmxpYnJlbm1zLXNlcnZpY2UKICAgIGhvc3RuYW1lOiBsaWJyZW5tcy1kaXNwYXRjaGVyCiAgICBlbnZpcm9ubWVudDoKICAgICAgPDw6ICpsaWJyZW5tcy1lbnZpcm9ubWVudAogICAgICBESVNQQVRDSEVSX05PREVfSUQ6IGRpc3BhdGNoZXIxCiAgICAgIFNJREVDQVJfRElTUEFUQ0hFUjogIjEiCiAgICBkZXBlbmRzX29uOgogICAgICBsaWJyZW5tczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQoKICBzeXNsb2duZzoKICAgIDw8OiAqbGlicmVubXMtc2VydmljZQogICAgaG9zdG5hbWU6IGxpYnJlbm1zLXN5c2xvZ25nCiAgICBlbnZpcm9ubWVudDoKICAgICAgPDw6ICpsaWJyZW5tcy1lbnZpcm9ubWVudAogICAgICBTSURFQ0FSX1NZU0xPR05HOiAiMSIKICAgIHBvcnRzOgogICAgICAtICI1MTQ6NTE0L3RjcCIKICAgICAgLSAiNTE0OjUxNC91ZHAiCiAgICBkZXBlbmRzX29uOgogICAgICBsaWJyZW5tczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQoKICBzbm1wdHJhcGQ6CiAgICA8PDogKmxpYnJlbm1zLXNlcnZpY2UKICAgIGhvc3RuYW1lOiBsaWJyZW5tcy1zbm1wdHJhcGQKICAgIGVudmlyb25tZW50OgogICAgICA8PDogKmxpYnJlbm1zLWVudmlyb25tZW50CiAgICAgIFNJREVDQVJfU05NUFRSQVBEOiAiMSIKICAgICAgU05NUF9VU0VSOiAke1NOTVBfVVNFUjotbGlicmVubXNfdXNlcn0KICAgICAgU05NUF9BVVRIOiAke1NOTVBfQVVUSDo/U05NUF9BVVRIIGlzIHJlcXVpcmVkfQogICAgICBTTk1QX1BSSVY6ICR7U05NUF9QUklWOj9TTk1QX1BSSVYgaXMgcmVxdWlyZWR9CiAgICAgIFNOTVBfRU5HSU5FSUQ6ICR7U05NUF9FTkdJTkVJRDo/U05NUF9FTkdJTkVJRCBpcyByZXF1aXJlZH0KICAgICAgU05NUF9ESVNBQkxFX0FVVEhPUklaQVRJT046ICR7U05NUF9ESVNBQkxFX0FVVEhPUklaQVRJT046LW5vfQogICAgcG9ydHM6CiAgICAgIC0gIjE2MjoxNjIvdGNwIgogICAgICAtICIxNjI6MTYyL3VkcCIKICAgIGRlcGVuZHNfb246CiAgICAgIGxpYnJlbm1zOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CiAgICAgIHJlZGlzOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9oZWFsdGh5CgogIGRiOgogICAgaW1hZ2U6IG1hcmlhZGI6MTAuMTEKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBlbnZpcm9ubWVudDoKICAgICAgVFo6ICR7VFo6LVVUQ30KICAgICAgTUFSSUFEQl9ST09UX1BBU1NXT1JEOiAke0RCX1JPT1RfUEFTU1dPUkQ6P0RCX1JPT1RfUEFTU1dPUkQgaXMgcmVxdWlyZWR9CiAgICAgIE1BUklBREJfREFUQUJBU0U6ICR7REJfTkFNRTotbGlicmVubXN9CiAgICAgIE1BUklBREJfVVNFUjogJHtEQl9VU0VSOi1saWJyZW5tc30KICAgICAgTUFSSUFEQl9QQVNTV09SRDogJHtEQl9QQVNTV09SRDo/REJfUEFTU1dPUkQgaXMgcmVxdWlyZWR9CiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9kYjovdmFyL2xpYi9teXNxbAogICAgY29tbWFuZDoKICAgICAgLSAtLWlubm9kYi1maWxlLXBlci10YWJsZT0xCiAgICAgIC0gLS1sb3dlci1jYXNlLXRhYmxlLW5hbWVzPTAKICAgICAgLSAtLWNoYXJhY3Rlci1zZXQtc2VydmVyPXV0ZjhtYjQKICAgICAgLSAtLWNvbGxhdGlvbi1zZXJ2ZXI9dXRmOG1iNF91bmljb2RlX2NpCiAgICAgIC0gLS1tYXgtYWxsb3dlZC1wYWNrZXQ9NjRNCiAgICAgIC0gLS1pbm5vZGItYnVmZmVyLXBvb2wtc2l6ZT0yNTZNCiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQiLCAiaGVhbHRoY2hlY2suc2giLCAiLS1jb25uZWN0IiwgIi0taW5ub2RiX2luaXRpYWxpemVkIl0KICAgICAgaW50ZXJ2YWw6IDEwcwogICAgICB0aW1lb3V0OiA1cwogICAgICByZXRyaWVzOiAxMgogICAgICBzdGFydF9wZXJpb2Q6IDMwcwogICAgbmV0d29ya3M6CiAgICAgIC0gbGlicmVubXMtbmV0CiAgICBsb2dnaW5nOgogICAgICBkcml2ZXI6IGpzb24tZmlsZQogICAgICBvcHRpb25zOgogICAgICAgIG1heC1zaXplOiAxMG0KICAgICAgICBtYXgtZmlsZTogIjMiCgogIHJlZGlzOgogICAgaW1hZ2U6IHJlZGlzOjcuMi1hbHBpbmUKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBlbnZpcm9ubWVudDoKICAgICAgUkVESVNfUEFTU1dPUkQ6ICR7UkVESVNfUEFTU1dPUkQ6P1JFRElTX1BBU1NXT1JEIGlzIHJlcXVpcmVkfQogICAgY29tbWFuZDoKICAgICAgLSAvYmluL3NoCiAgICAgIC0gLWVjCiAgICAgIC0gfAogICAgICAgIHVtYXNrIDA3NwogICAgICAgIHsKICAgICAgICAgIHByaW50ZiAncmVxdWlyZXBhc3MgJXNcbicgIiQkUkVESVNfUEFTU1dPUkQiCiAgICAgICAgICBwcmludGYgJ21heG1lbW9yeSA1MTJtYlxuJwogICAgICAgICAgcHJpbnRmICdtYXhtZW1vcnktcG9saWN5IG5vZXZpY3Rpb25cbicKICAgICAgICAgIHByaW50ZiAnYXBwZW5kb25seSB5ZXNcbicKICAgICAgICB9ID4vdG1wL3JlZGlzLmNvbmYKICAgICAgICBleGVjIHJlZGlzLXNlcnZlciAvdG1wL3JlZGlzLmNvbmYKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL3JlZGlzOi9kYXRhCiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQtU0hFTEwiLCAiUkVESVNDTElfQVVUSD1cIiQkUkVESVNfUEFTU1dPUkRcIiByZWRpcy1jbGkgcGluZyB8IGdyZXAgLXEgUE9ORyJdCiAgICAgIGludGVydmFsOiAxMHMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMTIKICAgICAgc3RhcnRfcGVyaW9kOiAxMHMKICAgIG5ldHdvcmtzOgogICAgICAtIGxpYnJlbm1zLW5ldAogICAgbG9nZ2luZzoKICAgICAgZHJpdmVyOiBqc29uLWZpbGUKICAgICAgb3B0aW9uczoKICAgICAgICBtYXgtc2l6ZTogMTBtCiAgICAgICAgbWF4LWZpbGU6ICIzIgoKbmV0d29ya3M6CiAgbGlicmVubXMtbmV0OgogICAgZHJpdmVyOiBicmlkZ2UK"

extract_docker_compose() {
  # Prefer a compose file next to this script (git clone / local edits), then
  # fall back to the embedded blob (curl|bash one-liner installs).
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    cat "$SCRIPT_DIR/docker-compose.yml"
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 -c "
import base64, sys
b64 = '''$EMBEDDED_COMPOSE_B64'''
sys.stdout.buffer.write(base64.b64decode(b64))
" 2>/dev/null && return 0
  fi
  die "Cannot find docker-compose.yml — re-download the installer"
}

#-------------------------- Validation helpers --------------------------
validate_url() {
  local url="$1"
  command -v python3 &>/dev/null || die "python3 is required for URL validation"
  python3 - "$url" <<'PY' || die "Invalid URL: $url (use http[s]://host[:port] with no path, query, credentials, or fragment)"
import sys
import ipaddress
import re
from urllib.parse import urlsplit

value = sys.argv[1]
try:
    parsed = urlsplit(value)
    port = parsed.port
except ValueError:
    raise SystemExit(1)

host = parsed.hostname or ""
try:
    ipaddress.ip_address(host)
    valid_host = True
except ValueError:
    valid_host = bool(re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", host
    )) and ".." not in host

valid = (
    parsed.scheme in {"http", "https"}
    and valid_host
    and parsed.username is None
    and parsed.password is None
    and parsed.path in {"", "/"}
    and not parsed.query
    and not parsed.fragment
    and (port is None or 1 <= port <= 65535)
    and not any(char.isspace() or ord(char) < 32 for char in value)
)
raise SystemExit(0 if valid else 1)
PY
}

validate_timezone() {
  [[ "$1" =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)*$ && "$1" != *".."* ]] ||
    die "Invalid timezone '$1'"
  if [[ -d /usr/share/zoneinfo && ! -f "/usr/share/zoneinfo/$1" ]]; then
    die "Invalid timezone '$1' (not found in /usr/share/zoneinfo)"
  fi
}

validate_identifier() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[a-zA-Z0-9_]+$ ]] ||
    die "$label may contain only letters, numbers, and underscores"
}

validate_secret() {
  local label="$1" value="$2"
  [[ ${#value} -ge 12 && "$value" =~ ^[a-zA-Z0-9._-]+$ ]] ||
    die "$label must be at least 12 characters using only letters, numbers, dot, underscore, or hyphen"
}

validate_email() {
  [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] ||
    die "Invalid admin email: $1"
}

backup_file() {
  # Must return 0 when the source is absent — first installs hit this path under set -e.
  [[ -f "$1" ]] || return 0
  cp -a "$1" "${1}.bak_${TIMESTAMP}" && info "Backed up $1"
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
      REDIS_HOST | REDIS_PASSWORD | POLLERS | CACHE_DRIVER | SESSION_DRIVER | \
      LIBRENMS_SNMP_COMMUNITY | SNMP_USER | SNMP_AUTH | SNMP_PRIV | SNMP_ENGINEID | \
      ADMIN_PASS | ADMIN_EMAIL)
      val="${val%$'\r'}"
      # Only import when the variable is not already set by CLI/env
      if [[ -z "${!key:-}" ]]; then
        printf -v "$key" '%s' "$val"
        export "${key?}"
      fi
      ;;
    esac
  done <"$env_file"
}

read_env_value() {
  local env_file="$1" wanted="$2" key val
  [[ -f "$env_file" ]] || return 1
  while IFS='=' read -r key val; do
    if [[ "$key" == "$wanted" ]]; then
      printf '%s' "${val%$'\r'}"
      return 0
    fi
  done <"$env_file"
  return 1
}

#-------------------------- Help ----------------------------------------
print_help() {
  cat <<'EOF'
Usage: sudo ./librenms-auto-install.sh [OPTIONS]

LibreNMS Docker Compose Installer - Network monitoring with auto-discovery,
SNMP, topology maps, traffic analysis, and alerting.

NOTE: This is NOT production-hardened. See README "Know before you install".

Options:
  -h, --help                 Show this help
  -d, --dir PATH             Install directory (default: /opt/librenms-easydeploy)
  -u, --url URL              Base URL for LibreNMS (e.g., http://librenms.example.com)
  -t, --timezone TZ          Timezone (default: UTC)
  -p, --pollers N            Number of pollers (default: 16, range: 1-64)
  -s, --save-creds FILE      Save generated credentials to file (chmod 600)
  -n, --non-interactive      Run without prompts (requires --url)
  -f, --force                Rewrite existing .env after backup (preserves loaded secrets)
  -D, --dry-run              Show actions without executing
  --no-firewall              Skip UFW firewall configuration
  --no-ssl                   Accepted for compatibility; stack is always HTTP-only
  --emit-env FILE            Write generated .env to FILE and exit (no Docker/root)
  --db-name NAME             Database name (letters, numbers, underscore)
  --db-user USER             Database user (letters, numbers, underscore)

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
    DIR_SET=true
    shift 2
    ;;
  -u | --url)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --url requires a URL"
    BASE_URL="$2"
    URL_SET=true
    validate_url "$BASE_URL"
    shift 2
    ;;
  -t | --timezone)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --timezone requires a timezone"
    TZ="$2"
    TZ_SET=true
    validate_timezone "$TZ"
    shift 2
    ;;
  -p | --pollers)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --pollers requires a number"
    POLLERS="$2"
    POLLERS_SET=true
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
    DB_NAME_SET=true
    shift 2
    ;;
  --db-user)
    [[ -z "${2:-}" || "$2" == -* ]] && die "Option --db-user requires a user"
    DB_USER="$2"
    DB_USER_SET=true
    shift 2
    ;;
  --)
    shift
    break
    ;;
  *) die "Unknown option: $1 (use --help)" ;;
  esac
done

#-------------------------- Existing config and defaults ----------------
# Loading happens after CLI parsing so explicit flags win, but before defaults
# so idempotent reruns retain every prior setting.
EXISTING_ENV="$INSTALL_DIR/.env"
HAD_EXISTING_ENV=false
[[ -f "$EXISTING_ENV" ]] && HAD_EXISTING_ENV=true
if [[ -z "$EMIT_ENV" || "$DIR_SET" == true ]]; then
  load_env "$EXISTING_ENV"
fi

TZ="${TZ:-UTC}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
DB_NAME="${DB_NAME:-librenms}"
DB_USER="${DB_USER:-librenms}"
REDIS_HOST="${REDIS_HOST:-redis}"
POLLERS="${POLLERS:-16}"
CACHE_DRIVER="${CACHE_DRIVER:-redis}"
SESSION_DRIVER="${SESSION_DRIVER:-redis}"
SNMP_USER="${SNMP_USER:-librenms_user}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@librenms.local}"
if [[ "$DRY_RUN" == true && "$NON_INTERACTIVE" == false && -z "$BASE_URL" ]]; then
  BASE_URL="http://localhost"
fi

#-------------------------- Validation ----------------------------------
[[ "$NON_INTERACTIVE" == true && -z "$BASE_URL" ]] &&
  die "Non-interactive mode requires --url (or BASE_URL in an existing .env)"
validate_timezone "$TZ"
validate_identifier "Database name" "$DB_NAME"
validate_identifier "Database user" "$DB_USER"
validate_identifier "SNMP user" "$SNMP_USER"
[[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] ||
  die "PUID and PGID must be non-negative integers"
if ! [[ "$POLLERS" =~ ^[0-9]+$ ]] || ((POLLERS < 1 || POLLERS > 64)); then
  die "Pollers must be 1-64"
fi

if [[ "$HAD_EXISTING_ENV" == true ]]; then
  if [[ "$DB_NAME_SET" == true ]]; then
    EXISTING_DB_NAME="$(read_env_value "$EXISTING_ENV" DB_NAME || true)"
    [[ "$DB_NAME" == "$EXISTING_DB_NAME" ]] ||
      die "Database name cannot be changed on an existing install"
  fi
  if [[ "$DB_USER_SET" == true ]]; then
    EXISTING_DB_USER="$(read_env_value "$EXISTING_ENV" DB_USER || true)"
    [[ "$DB_USER" == "$EXISTING_DB_USER" ]] ||
      die "Database user cannot be changed on an existing install"
  fi
fi

#-------------------------- Interactive prompts -------------------------
if [[ "$NON_INTERACTIVE" == false && "$DRY_RUN" == false ]]; then
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
REDIS_PASSWORD="${REDIS_PASSWORD:-$(gen_pass 32)}"
if [[ "$HAD_EXISTING_ENV" == false ]]; then
  ADMIN_PASS="${ADMIN_PASS:-$(gen_pass 24)}"
fi
LIBRENMS_SNMP_COMMUNITY="${LIBRENMS_SNMP_COMMUNITY:-$(gen_pass 24)}"
SNMP_AUTH="${SNMP_AUTH:-$(gen_pass 24)}"
SNMP_PRIV="${SNMP_PRIV:-$(gen_pass 24)}"
SNMP_ENGINEID="${SNMP_ENGINEID:-$(gen_hex 10)}"
validate_secret "Database password" "$DB_PASSWORD"
validate_secret "Database root password" "$DB_ROOT_PASSWORD"
validate_secret "Redis password" "$REDIS_PASSWORD"
validate_secret "SNMP community" "$LIBRENMS_SNMP_COMMUNITY"
validate_secret "SNMP authentication password" "$SNMP_AUTH"
validate_secret "SNMP privacy password" "$SNMP_PRIV"
[[ -z "$ADMIN_PASS" ]] || validate_secret "Admin password" "$ADMIN_PASS"
[[ "$SNMP_ENGINEID" =~ ^[a-fA-F0-9]{10,64}$ ]] ||
  die "SNMP engine ID must be 10-64 hexadecimal characters"
validate_email "$ADMIN_EMAIL"

#-------------------------- Write .env helper (no printf %s traps) -------
write_env_file() {
  local dest="$1" temp="${1}.tmp.$$"
  if ! (
    umask 077 && cat >"$temp" <<EOF
# LibreNMS Docker Compose Environment
# Generated by librenms-auto-install.sh on $(date)
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
BASE_URL=${BASE_URL}
LIBRENMS_BASE_URL=/
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
REDIS_HOST=${REDIS_HOST}
REDIS_PASSWORD=${REDIS_PASSWORD}
POLLERS=${POLLERS}
CACHE_DRIVER=${CACHE_DRIVER}
SESSION_DRIVER=${SESSION_DRIVER}
LIBRENMS_SNMP_COMMUNITY=${LIBRENMS_SNMP_COMMUNITY}
SNMP_USER=${SNMP_USER}
SNMP_AUTH=${SNMP_AUTH}
SNMP_PRIV=${SNMP_PRIV}
SNMP_ENGINEID=${SNMP_ENGINEID}
SNMP_DISABLE_AUTHORIZATION=no
ADMIN_PASS=${ADMIN_PASS}
ADMIN_EMAIL=${ADMIN_EMAIL}
EOF
  ); then
    rm -f -- "$temp"
    die "Could not write environment file: $dest"
  fi
  mv -f -- "$temp" "$dest"
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
  info "Would create: $INSTALL_DIR/data/{librenms/config,db,redis}"
  info "Would install docker-compose.yml, create/update .env, start services"
  info "=== DRY-RUN COMPLETE ==="
  exit 0
fi

#-------------------------- Pre-flight checks --------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)"
command -v docker &>/dev/null || die "Docker is not installed. Install Docker first."
docker info &>/dev/null || die "Docker daemon is not available"
docker compose version &>/dev/null || die "Docker Compose v2 is not installed."
DOCKER_COMPOSE=(docker compose)

command -v flock &>/dev/null || die "flock is required (provided by util-linux)"
exec 9>/var/lock/librenms-easydeploy.lock
flock -n 9 || die "Another LibreNMS EasyDeploy installer is already running"

if [[ -n "$SAVE_CREDS" && "$SAVE_CREDS" != /* ]]; then
  SAVE_CREDS="$(pwd)/$SAVE_CREDS"
fi

#-------------------------- Install directory ---------------------------
mkdir -p "$INSTALL_DIR"/data/{librenms/config,db,redis}
cd "$INSTALL_DIR" || die "Cannot access $INSTALL_DIR"

# The installer owns docker-compose.yml. Refresh it on upgrades while keeping a
# timestamped backup; local customizations belong in docker-compose.override.yml.
COMPOSE_TEMP=".docker-compose.yml.tmp.$$"
extract_docker_compose >"$COMPOSE_TEMP"
if [[ -f docker-compose.yml ]] && cmp -s docker-compose.yml "$COMPOSE_TEMP"; then
  rm -f "$COMPOSE_TEMP"
  info "docker-compose.yml is current"
else
  backup_file docker-compose.yml
  mv -f "$COMPOSE_TEMP" docker-compose.yml
  chmod 644 docker-compose.yml
  info "Installed current docker-compose.yml"
fi

#-------------------------- Environment file (idempotent) ---------------
CONFIG_CHANGED=false
if [[ -f .env ]]; then
  if [[ "$URL_SET" == true && "$BASE_URL" != "$(read_env_value .env BASE_URL || true)" ]] ||
    [[ "$TZ_SET" == true && "$TZ" != "$(read_env_value .env TZ || true)" ]] ||
    [[ "$POLLERS_SET" == true && "$POLLERS" != "$(read_env_value .env POLLERS || true)" ]] ||
    [[ "$(read_env_value .env SNMP_DISABLE_AUTHORIZATION || true)" == "yes" ]]; then
    CONFIG_CHANGED=true
  fi
fi

if [[ -f .env && ("$FORCE" == true || "$CONFIG_CHANGED" == true) ]]; then
  backup_file .env
  write_env_file .env
  chmod 600 .env
  info "Updated .env (previous file backed up) — chmod 600"
elif [[ -f .env && "$FORCE" == false ]]; then
  # Preserve existing .env; append any missing keys (e.g., REDIS_PASSWORD
  # from a pre-hardening install)
  for key in CACHE_DRIVER SESSION_DRIVER ADMIN_EMAIL REDIS_PASSWORD \
    LIBRENMS_SNMP_COMMUNITY SNMP_USER SNMP_AUTH SNMP_PRIV SNMP_ENGINEID \
    LIBRENMS_BASE_URL SNMP_DISABLE_AUTHORIZATION; do
    if ! grep -q "^${key}=" .env 2>/dev/null; then
      case "$key" in
      LIBRENMS_BASE_URL) echo 'LIBRENMS_BASE_URL=/' >>.env ;;
      SNMP_DISABLE_AUTHORIZATION) echo 'SNMP_DISABLE_AUTHORIZATION=no' >>.env ;;
      *) echo "${key}=${!key}" >>.env ;;
      esac
    fi
  done
  chmod 600 .env
  info ".env already exists — preserving (use --force to overwrite)"
else
  write_env_file .env
  chmod 600 .env
  info "Created .env (chmod 600)"
fi

"${DOCKER_COMPOSE[@]}" config --quiet ||
  die "Generated Docker Compose configuration is invalid"

#-------------------------- Credentials helper ---------------------------
write_credentials_file() {
  local destination="$1"
  (umask 077 && {
    echo "# LibreNMS credentials generated on $(date)"
    echo "MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
    echo "MYSQL_DATABASE=${DB_NAME}"
    echo "MYSQL_USER=${DB_USER}"
    echo "MYSQL_PASSWORD=${DB_PASSWORD}"
    echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
    echo "BASE_URL=${BASE_URL}"
    echo "TZ=${TZ}"
    echo "ADMIN_USER=admin"
    [[ -n "$ADMIN_PASS" ]] && echo "ADMIN_PASSWORD=${ADMIN_PASS}"
    echo "ADMIN_EMAIL=${ADMIN_EMAIL}"
    echo "SNMP_COMMUNITY=${LIBRENMS_SNMP_COMMUNITY}"
    echo "SNMP_V3_USER=${SNMP_USER}"
    echo "SNMP_V3_AUTH_PASSWORD=${SNMP_AUTH}"
    echo "SNMP_V3_PRIV_PASSWORD=${SNMP_PRIV}"
    echo "SNMP_ENGINE_ID=${SNMP_ENGINEID}"
  } >"$destination") || die "Could not write credentials file: $destination"
  chmod 600 "$destination"
}

#-------------------------- Volume permissions --------------------------
info "Setting volume permissions (PUID=$PUID, PGID=$PGID)..."
chown -R "$PUID:$PGID" "$INSTALL_DIR/data/librenms"

# Syslog ingestion must be enabled in LibreNMS as well as in the sidecar.
SYSLOG_CONFIG="$INSTALL_DIR/data/librenms/config/syslog.yaml"
if [[ ! -e "$SYSLOG_CONFIG" ]]; then
  printf 'enable_syslog: true\n' >"$SYSLOG_CONFIG"
  chown "$PUID:$PGID" "$SYSLOG_CONFIG"
  chmod 640 "$SYSLOG_CONFIG"
  info "Enabled LibreNMS syslog ingestion"
fi

#-------------------------- Firewall ------------------------------------
if [[ "$SKIP_FIREWALL" == false ]] && command -v ufw &>/dev/null; then
  ufw allow 80/tcp comment 'LibreNMS HTTP'
  ufw allow 162/tcp comment 'LibreNMS SNMP-Trap TCP'
  ufw allow 162/udp comment 'LibreNMS SNMP-Trap'
  ufw allow 514/tcp comment 'LibreNMS Syslog TCP'
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
"${DOCKER_COMPOSE[@]}" up -d --remove-orphans

info "Waiting for database to be ready..."
for i in $(seq 1 60); do
  if "${DOCKER_COMPOSE[@]}" exec -T -e MYSQL_PWD="${DB_ROOT_PASSWORD}" db \
    mariadb-admin ping -hlocalhost -uroot --silent &>/dev/null; then
    info "Database is ready"
    break
  fi
  sleep 2
  [[ $i -eq 60 ]] && die "Database did not become ready in time"
done

info "Waiting for Redis to be ready..."
for i in $(seq 1 30); do
  if "${DOCKER_COMPOSE[@]}" exec -T -e REDISCLI_AUTH="${REDIS_PASSWORD}" redis \
    redis-cli ping 2>/dev/null | grep -q PONG; then
    info "Redis is ready"
    break
  fi
  sleep 2
  [[ $i -eq 30 ]] && die "Redis did not become ready in time"
done

info "Waiting for LibreNMS web UI to be ready..."
for i in $(seq 1 120); do
  if "${DOCKER_COMPOSE[@]}" exec -T librenms \
    curl -fsS http://localhost:8000/ &>/dev/null; then
    info "LibreNMS web UI is ready"
    break
  fi
  sleep 3
  [[ $i -eq 120 ]] && {
    "${DOCKER_COMPOSE[@]}" logs --tail=80 librenms >&2 || true
    die "LibreNMS did not become ready in time"
  }
done

# The official container performs migrations and seeding during startup.
# Configure the dispatcher worker count through the supported LibreNMS setting.
info "Configuring dispatcher poller workers ($POLLERS)..."
"${DOCKER_COMPOSE[@]}" exec -T --user librenms librenms \
  lnms config:set service_poller_workers "$POLLERS" --no-interaction ||
  die "Could not configure dispatcher poller workers"
"${DOCKER_COMPOSE[@]}" exec -T --user librenms librenms \
  lnms config:set enable_syslog true --no-interaction ||
  die "Could not enable LibreNMS syslog ingestion"

# Create the admin only if it does not already exist.
info "Checking for existing admin user..."
if ! ADMIN_EXISTS=$(
  "${DOCKER_COMPOSE[@]}" exec -T -e MYSQL_PWD="$DB_PASSWORD" db \
    mariadb -u"$DB_USER" "$DB_NAME" --batch --skip-column-names \
    -e "SELECT COUNT(*) FROM users WHERE username='admin' AND auth_type='mysql';" 2>/dev/null
); then
  die "Could not query the LibreNMS users table"
fi
ADMIN_EXISTS="${ADMIN_EXISTS//$'\r'/}"
if [[ "$ADMIN_EXISTS" =~ ^[1-9][0-9]*$ ]]; then
  info "Admin user already exists — preserving credentials"
  if [[ -z "$ADMIN_PASS" ]]; then
    warn "Admin password is not stored in .env; existing login credentials are unchanged"
  fi
else
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(gen_pass 24)"
    # Rewrite .env atomically so we never leave a half-updated secrets file.
    write_env_file .env
    chmod 600 .env
  fi
  info "Creating admin user..."
  # Variables intentionally expand in the inner container shell, not here.
  # shellcheck disable=SC2016
  if ! "${DOCKER_COMPOSE[@]}" exec -T --user librenms \
    -e LIBRENMS_ADMIN_PASSWORD="$ADMIN_PASS" \
    -e LIBRENMS_ADMIN_EMAIL="$ADMIN_EMAIL" librenms sh -c \
    'lnms user:add admin --password="$LIBRENMS_ADMIN_PASSWORD" --email="$LIBRENMS_ADMIN_EMAIL" --role=admin --no-interaction'; then
    die "Admin user creation failed"
  fi
fi

# The image enables the web installer for an empty database. Automated admin
# creation replaces that flow, so remove INSTALL and clear the cached config.
# Either env file may be absent depending on image version — skip missing paths.
# Variables intentionally expand inside the container shell, not here.
# shellcheck disable=SC2016
if ! "${DOCKER_COMPOSE[@]}" exec -T --user librenms librenms sh -c '
  for f in /data/.env /opt/librenms/.env; do
    [ -f "$f" ] || continue
    sed -i "/^INSTALL=/d" "$f"
  done
  artisan config:clear --no-interaction
'; then
  die "Could not finalize the LibreNMS installation"
fi

"${DOCKER_COMPOSE[@]}" restart dispatcher >/dev/null ||
  die "Could not restart dispatcher after applying worker settings"

if [[ -n "$SAVE_CREDS" ]]; then
  write_credentials_file "$SAVE_CREDS"
  info "Credentials saved to $SAVE_CREDS (chmod 600)"
fi

#-------------------------- Summary -------------------------------------
cat <<EOF

============================================================
LibreNMS deployment complete!

Web UI: ${BASE_URL:-http://$(hostname -I | awk '{print $1}')/}
Admin user: admin
Email: ${ADMIN_EMAIL}

Initial credentials: .env (chmod 600; ADMIN_PASS, database, Redis, SNMP)
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
