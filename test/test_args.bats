#!/usr/bin/env bats
# librenms-auto-install tests — self-contained, no external helpers required

# Inline assert helpers
assert_success() {
  if [ "$status" -ne 0 ]; then
    echo "expected success but status=$status" >&2
    echo "output: $output" >&2
    return 1
  fi
}

assert_failure() {
  if [ "$status" -eq 0 ]; then
    echo "expected failure but status=0" >&2
    echo "output: $output" >&2
    return 1
  fi
}

assert_output() {
  local pattern="$1"
  if [[ "$output" != *"$pattern"* ]]; then
    echo "expected output to contain: $pattern" >&2
    echo "actual output: $output" >&2
    return 1
  fi
}

setup() {
  SCRIPT="./librenms-auto-install.sh"
  TEST_TMP="${BATS_TEST_TMPDIR:-/tmp}/librenms-bats-$$"
  mkdir -p "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "Help shows usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output "Usage:"
  assert_output "librenms-auto-install.sh"
}

@test "Invalid option fails" {
  run "$SCRIPT" --invalid-option
  assert_failure
  assert_output "Unknown option"
}

@test "Non-interactive without URL fails" {
  run "$SCRIPT" --non-interactive
  assert_failure
  assert_output "requires --url"
}

@test "Dry-run exits 0 and shows config" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com
  assert_success
  assert_output "DRY-RUN"
  assert_output "test.example.com"
}

@test "Interactive dry-run never prompts or writes credentials" {
  creds="$TEST_TMP/should-not-exist"
  run "$SCRIPT" --dry-run --save-creds "$creds"
  assert_success
  assert_output "Base URL: http://localhost"
  [[ ! -e "$creds" ]]
}

@test "Dry-run with save-creds shows file path" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --save-creds /tmp/test-creds.txt
  assert_success
  assert_output "/tmp/test-creds.txt"
}

@test "Invalid URL format fails" {
  run "$SCRIPT" --dry-run --non-interactive --url "not-a-url"
  assert_failure
  assert_output "Invalid URL"
}

@test "Invalid pollers value fails" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --pollers 0
  assert_failure
  assert_output "Pollers must be 1-64"
}

@test "Invalid pollers value too high fails" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --pollers 100
  assert_failure
  assert_output "Pollers must be 1-64"
}

@test "Valid pollers accepted" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --pollers 8
  assert_success
}

@test "Valid timezone is accepted" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --timezone UTC
  assert_success
}

@test "Help shows NOT production-hardened disclaimer" {
  run "$SCRIPT" --help
  assert_success
  assert_output "NOT production-hardened"
}

@test "Help describes --force as .env overwrite" {
  run "$SCRIPT" --help
  assert_success
  assert_output "Rewrite existing .env"
  assert_output "preserves loaded secrets"
}

@test "Dry-run shows sidecar container plan" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com
  assert_success
  assert_output "Would install docker-compose.yml"
  assert_output "create/update .env"
  assert_output "start services"
}

@test "Invalid timezone fails early" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --timezone "../Invalid"
  assert_failure
  assert_output "Invalid timezone"
}

@test "le-email is rejected with honest TLS message" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --le-email admin@example.com
  assert_failure
  assert_output "TLS/Let's Encrypt is not built into this installer"
}

@test "emit-env writes valid KEY=value .env without literal %s" {
  envfile="$TEST_TMP/test.env"
  run "$SCRIPT" --non-interactive --url http://librenms.test.local --emit-env "$envfile"
  assert_success
  [[ -f "$envfile" ]]

  # Must be KEY=value lines — the old printf bug left literal %s
  if grep -q '%s' "$envfile"; then
    echo "literal %s found in .env:" >&2
    cat "$envfile" >&2
    return 1
  fi

  for key in TZ BASE_URL LIBRENMS_BASE_URL DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD \
    REDIS_PASSWORD ADMIN_PASS ADMIN_EMAIL POLLERS LIBRENMS_SNMP_COMMUNITY SNMP_USER \
    SNMP_AUTH SNMP_PRIV SNMP_ENGINEID SNMP_DISABLE_AUTHORIZATION; do
    grep -q "^${key}=" "$envfile" || {
      echo "missing key: $key" >&2
      cat "$envfile" >&2
      return 1
    }
  done

  # Passwords should be non-empty and not placeholders
  pass=$(grep '^DB_PASSWORD=' "$envfile" | cut -d= -f2-)
  [[ ${#pass} -ge 16 ]] || {
    echo "DB_PASSWORD too short or empty: '$pass'" >&2
    return 1
  }
  grep -q '^BASE_URL=http://librenms.test.local$' "$envfile"
  grep -q '^LIBRENMS_BASE_URL=/$' "$envfile"
  grep -q '^SNMP_DISABLE_AUTHORIZATION=no$' "$envfile"
  if [[ "$(uname -s)" == "Linux" ]]; then
    mode=$(stat -c '%a' "$envfile")
    [[ "$mode" == "600" ]]
  fi
}

@test "existing .env values survive a non-interactive rerun" {
  install_dir="$TEST_TMP/existing"
  mkdir -p "$install_dir"
  cat >"$install_dir/.env" <<'EOF'
TZ=Europe/Berlin
PUID=2000
PGID=2001
BASE_URL=https://existing.example.com
DB_NAME=existing_db
DB_USER=existing_user
DB_PASSWORD=ExistingDbPass123
DB_ROOT_PASSWORD=ExistingRootPass123
REDIS_HOST=redis
REDIS_PASSWORD=ExistingRedisPass123
POLLERS=7
CACHE_DRIVER=redis
SESSION_DRIVER=redis
LIBRENMS_SNMP_COMMUNITY=ExistingCommunity123
SNMP_USER=existing_snmp
SNMP_AUTH=ExistingAuthPass123
SNMP_PRIV=ExistingPrivPass123
SNMP_ENGINEID=00112233445566778899
ADMIN_PASS=ExistingAdminPass123
ADMIN_EMAIL=existing@example.com
EOF

  emitted="$TEST_TMP/existing-emitted.env"
  run "$SCRIPT" --non-interactive --dir "$install_dir" --emit-env "$emitted"
  assert_success
  grep -q '^TZ=Europe/Berlin$' "$emitted"
  grep -q '^PUID=2000$' "$emitted"
  grep -q '^DB_NAME=existing_db$' "$emitted"
  grep -q '^POLLERS=7$' "$emitted"
  grep -q '^DB_PASSWORD=ExistingDbPass123$' "$emitted"
  grep -q '^ADMIN_PASS=ExistingAdminPass123$' "$emitted"
}

@test "CLI values override an existing .env" {
  install_dir="$TEST_TMP/override"
  mkdir -p "$install_dir"
  cat >"$install_dir/.env" <<'EOF'
BASE_URL=https://old.example.com
POLLERS=4
EOF

  emitted="$TEST_TMP/override-emitted.env"
  run "$SCRIPT" --non-interactive --dir "$install_dir" \
    --url https://new.example.com --pollers 9 --emit-env "$emitted"
  assert_success
  grep -q '^BASE_URL=https://new.example.com$' "$emitted"
  grep -q '^POLLERS=9$' "$emitted"
}

@test "URL paths, credentials, and invalid ports are rejected" {
  run "$SCRIPT" --dry-run --non-interactive --url https://example.com/librenms
  assert_failure
  assert_output "Invalid URL"

  run "$SCRIPT" --dry-run --non-interactive --url https://user:pass@example.com
  assert_failure
  assert_output "Invalid URL"

  run "$SCRIPT" --dry-run --non-interactive --url https://example.com:70000
  assert_failure
  assert_output "Invalid URL"
}

@test "database identifiers reject unsafe characters" {
  run "$SCRIPT" --dry-run --non-interactive --url https://example.com --db-name 'bad-name'
  assert_failure
  assert_output "Database name may contain only"
}

@test "docker compose is invoked as an array" {
  grep -q '^DOCKER_COMPOSE=(docker compose)$' "$SCRIPT"
  if grep -qE '^\$DOCKER_COMPOSE ' "$SCRIPT"; then
    echo "unsafe scalar docker compose invocation found" >&2
    return 1
  fi
}

@test "embedded compose matches docker-compose.yml" {
  command -v python3 >/dev/null || skip "python3 required"
  run python3 scripts/sync_embedded_compose.py --check
  assert_success
}
