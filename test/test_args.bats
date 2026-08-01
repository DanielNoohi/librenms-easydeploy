#! /usr/bin/env bats

load test_helper/bats-support/load
load test_helper/bats-assert/load

@test "Help shows usage" {
  run ./librenms-auto-install.sh --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Parameters"
}

@test "Non-interactive without URL fails" {
  run ./librenms-auto-install.sh --non-interactive
  assert_failure
  assert_output --partial "non-interactive mode requires --url"
}

@test "Validates custom directory" {
  run ./librenms-auto-install.sh --dir /tmp/test-install --url http://test.local
  assert_success
}

@test "Accepts custom DB name" {
  run ./librenms-auto-install.sh --db-name mymonitoring --url http://test.local
  assert_success
}

@test "Accepts custom DB user" {
  run ./librenms-auto-install.sh --db-user librenmsadmin --url http://test.local
  assert_success
}

@test "Accepts custom pollers" {
  run ./librenms-auto-install.sh --pollers 32 --url http://test.local
  assert_success
}