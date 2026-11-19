#!/usr/bin/env bash
# Unit tests for the pure validation helpers in lib/core.sh.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"

describe "validate_port"

test_that "accepts 1"
assert_true validate_port "1"

test_that "accepts 65535"
assert_true validate_port "65535"

test_that "accepts a typical port"
assert_true validate_port "8080"

test_that "rejects 0"
assert_false validate_port "0"

test_that "rejects 65536 (out of range)"
assert_false validate_port "65536"

test_that "rejects non-numeric input"
assert_false validate_port "abc"

test_that "rejects empty string"
assert_false validate_port ""

test_that "rejects trailing garbage"
assert_false validate_port "8080a"

end_describe

describe "validate_ports"

test_that "accepts a single port"
assert_true validate_ports "80"

test_that "accepts a comma list"
assert_true validate_ports "80,443,8080"

test_that "tolerates spaces around commas"
assert_true validate_ports "80, 443"

test_that "rejects empty string"
assert_false validate_ports ""

test_that "rejects a list with one invalid port"
assert_false validate_ports "80,99999"

end_describe

describe "validate_ip"

test_that "accepts a normal IPv4 address"
assert_true validate_ip "192.168.1.1"

test_that "accepts the IPv4 broadcast address"
assert_true validate_ip "255.255.255.255"

test_that "rejects an IPv4 octet over 255"
assert_false validate_ip "256.1.1.1"

test_that "rejects an incomplete IPv4 address"
assert_false validate_ip "1.1.1"

test_that "accepts IPv6 loopback"
assert_true validate_ip "::1"

test_that "accepts a full IPv6 address"
assert_true validate_ip "2001:db8::1"

test_that "rejects a non-IP string"
assert_false validate_ip "not-an-ip"

end_describe

describe "validate_target_address"

test_that "accepts a domain name"
assert_true validate_target_address "example.com"

test_that "accepts an IPv4 address"
assert_true validate_target_address "192.168.1.1"

test_that "accepts localhost"
assert_true validate_target_address "localhost"

test_that "accepts a comma-separated multi-address list"
assert_true validate_target_address "example.com,192.168.1.1"

test_that "rejects a multi-address list with one bad entry"
assert_false validate_target_address "example.com,not_a_domain"

test_that "rejects an empty string"
assert_false validate_target_address ""

end_describe

ptyunit_test_summary
