#!/usr/bin/env bats

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  SCRIPT="./librenms-auto-install.sh"
}

@test "Help shows usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "librenms-auto-install.sh"
}

@test "Invalid option fails" {
  run "$SCRIPT" --invalid-option
  assert_failure
  assert_output --partial "Unknown option"
}

@test "Non-interactive without URL fails" {
  run "$SCRIPT" --non-interactive
  assert_failure
  assert_output --partial "requires --url"
}

@test "Dry-run exits 0 and shows config" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com
  assert_success
  assert_output --partial "DRY-RUN MODE"
  assert_output --partial "test.example.com"
}

@test "Dry-run with save-creds shows file path" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --save-creds /tmp/test-creds.txt
  assert_success
  assert_output --partial "/tmp/test-creds.txt"
}

@test "Invalid URL format fails" {
  run "$SCRIPT" --dry-run --non-interactive --url "not-a-url"
  assert_failure
  assert_output --partial "Invalid URL format"
}

@test "Invalid pollers value fails" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --pollers 0
  assert_failure
  assert_output --partial "Pollers must be 1-64"
}

@test "Invalid pollers value too high fails" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --pollers 100
  assert_failure
  assert_output --partial "Pollers must be 1-64"
}

@test "Valid pollers accepted" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --pollers 8
  assert_success
}

@test "Timezone validation warns but continues" {
  run "$SCRIPT" --dry-run --non-interactive --url https://test.example.com --timezone UTC
  assert_success
}
