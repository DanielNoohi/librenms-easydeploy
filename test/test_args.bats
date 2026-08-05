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
