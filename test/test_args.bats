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

@test "Dry-run with save-creds shows file path" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --save-creds /tmp/test-creds.txt
  assert_success
  assert_output "/tmp/test-creds.txt"
}

@test "Invalid URL format fails" {
  run "$SCRIPT" --dry-run --non-interactive --url "not-a-url"
  assert_failure
  assert_output "Invalid URL format"
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

@test "Timezone validation warns but continues" {
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
  assert_output "Overwrite existing .env"
}

@test "Dry-run shows sidecar container plan" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com
  assert_success
  assert_output "Would copy docker-compose.yml"
  assert_output "create .env"
  assert_output "start services"
}

@test "Invalid timezone format warns but continues" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --timezone "Invalid/Timezone"
  assert_success
  assert_output "may not be valid"
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

  for key in TZ BASE_URL DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD REDIS_PASSWORD ADMIN_PASS ADMIN_EMAIL POLLERS; do
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
}

@test "embedded compose matches docker-compose.yml" {
  command -v python3 >/dev/null || skip "python3 required"
  run python3 -c "
import base64, pathlib, re, sys
root = pathlib.Path('.')
compose = (root / 'docker-compose.yml').read_bytes()
script = (root / 'librenms-auto-install.sh').read_text(encoding='utf-8')
m = re.search(r'EMBEDDED_COMPOSE_B64=\"([^\"]*)\"', script)
if not m:
    sys.exit('EMBEDDED_COMPOSE_B64 missing')
decoded = base64.b64decode(m.group(1))
if decoded != compose:
    sys.exit(f'drift: file={len(compose)} embedded={len(decoded)}')
"
  assert_success
}
