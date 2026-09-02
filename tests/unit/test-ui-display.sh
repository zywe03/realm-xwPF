#!/usr/bin/env bash
# Unit tests for lib/ui.sh's pure display/formatting helpers and the
# temp-file cleanup routine: smart_display_target, get_security_display,
# get_gmt8_time, cleanup_temp_files, cleanup_files_by_paths,
# cleanup_files_by_pattern. None of these touch the real /etc/realm or
# /usr/local/bin paths, so no cross-file locking is needed.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

describe "smart_display_target"

test_that "passes through a plain external address unchanged"
assert_eq "203.0.113.5" "$(smart_display_target "203.0.113.5")"

test_that "falls back to the literal target when no public IPv4 is available"
assert_eq "127.0.0.1" "$(smart_display_target "127.0.0.1")"

test_that "shows the public IPv4 for a localhost target when available"
out=$(XWPF_MOCK_PUBLIC_IP="198.51.100.9" smart_display_target "127.0.0.1")
assert_eq "198.51.100.9" "$out"

test_that "shows the public IPv4 for the 'localhost' hostname when available"
out=$(XWPF_MOCK_PUBLIC_IP="198.51.100.9" smart_display_target "localhost")
assert_eq "198.51.100.9" "$out"

test_that "falls back to the literal target when no public IPv6 is available"
assert_eq "::1" "$(smart_display_target "::1")"

test_that "shows the public IPv6 for a ::1 target when available"
out=$(XWPF_MOCK_PUBLIC_IP="2001:db8::9" smart_display_target "::1")
assert_eq "2001:db8::9" "$out"

test_that "resolves each address in a multi-address list independently"
out=$(XWPF_MOCK_PUBLIC_IP="198.51.100.9" smart_display_target "127.0.0.1, 203.0.113.5,::1")
assert_eq "198.51.100.9,203.0.113.5,198.51.100.9" "$out"

end_describe

describe "get_security_display"

test_that "shows a plain label for standard transport"
assert_eq "默认传输" "$(get_security_display "standard" "" "")"

test_that "shows the ws path and host"
assert_eq "ws (host: example.com) (路径: /ws)" "$(get_security_display "ws" "/ws" "example.com")"

test_that "shows the DEFAULT_SNI_DOMAIN fallback when tls_self has no SNI set"
out=$(get_security_display "tls_self" "" "")
assert_contains "$out" "TLS自签证书"
assert_contains "$out" "$DEFAULT_SNI_DOMAIN"

test_that "shows the given SNI for tls_self when set"
out=$(get_security_display "tls_self" "" "custom.example.com")
assert_contains "$out" "custom.example.com"

test_that "shows the domain for a CA-signed TLS cert"
assert_eq "TLS CA证书 (域名: example.com)" "$(get_security_display "tls_ca" "" "example.com")"

test_that "shows ws+tls_self with path and SNI fallback"
out=$(get_security_display "ws_tls_self" "/ws" "example.com")
assert_contains "$out" "wss 自签证书"
assert_contains "$out" "/ws"
assert_contains "$out" "$DEFAULT_SNI_DOMAIN"

test_that "shows ws+tls_ca with path and SNI fallback"
out=$(get_security_display "ws_tls_ca" "/ws" "example.com")
assert_contains "$out" "wss CA证书"
assert_contains "$out" "/ws"

test_that "falls back to a generic ws_* label with the path for unknown ws variants"
out=$(get_security_display "ws_custom" "/ws" "")
assert_eq "ws_custom (路径: /ws)" "$out"

test_that "echoes back an unrecognized security level verbatim"
assert_eq "mystery" "$(get_security_display "mystery" "" "")"

end_describe

describe "get_gmt8_time"

test_that "formats the current time using the GMT-8 timezone"
# POSIX TZ semantics invert the sign: "GMT-8" is UTC+8 (matching this
# function's intent of showing China Standard Time), not UTC-8.
out=$(get_gmt8_time "+%z")
assert_eq "+0800" "$out"

end_describe

describe "cleanup_files_by_paths"

test_that "removes a plain file"
_f="$(mktemp /tmp/xwpf-cleanuptest.XXXXXX)"
cleanup_files_by_paths "$_f"
assert_false test -f "$_f"

test_that "removes a directory recursively"
_d="$(mktemp -d /tmp/xwpf-cleanuptest.XXXXXX)"
touch "$_d/nested"
cleanup_files_by_paths "$_d"
assert_false test -d "$_d"

test_that "silently ignores a path that doesn't exist"
cleanup_files_by_paths "/tmp/xwpf-does-not-exist-$$"

end_describe

describe "cleanup_files_by_pattern"

test_that "removes files matching the pattern within the given directory"
_d="$(mktemp -d /tmp/xwpf-cleanuptest.XXXXXX)"
touch "$_d/keep-me.txt" "$_d/drop-realm-thing.txt"
cleanup_files_by_pattern "realm" "$_d"
assert_true test -f "$_d/keep-me.txt"
assert_false test -f "$_d/drop-realm-thing.txt"
rm -rf "$_d"

end_describe

describe "cleanup_temp_files"

test_that "is a no-op when the cache file doesn't exist"
rm -f /tmp/realm_path_cache
cleanup_temp_files
assert_false test -f /tmp/realm_path_cache

test_that "leaves a small cache file untouched"
echo "small" > /tmp/realm_path_cache
cleanup_temp_files
assert_eq "small" "$(cat /tmp/realm_path_cache)"
rm -f /tmp/realm_path_cache

test_that "truncates an oversized cache file down to its last 5MB"
head -c 11000000 /dev/zero > /tmp/realm_path_cache
cleanup_temp_files
_size=$(stat -c%s /tmp/realm_path_cache 2>/dev/null || stat -f%z /tmp/realm_path_cache)
assert_eq "5242880" "$_size"
rm -f /tmp/realm_path_cache

test_that "deletes a stale realm_config_update_needed marker older than 5 minutes"
_marker="/tmp/realm_config_update_needed"
touch -d "-10 minutes" "$_marker"
cleanup_temp_files
assert_false test -f "$_marker"

test_that "leaves a fresh realm_config_update_needed marker alone"
_marker="/tmp/realm_config_update_needed"
touch "$_marker"
cleanup_temp_files
assert_true test -f "$_marker"
rm -f "$_marker"

test_that "deletes a stale *realm* temp file older than 60 minutes"
_stale="/tmp/xwpf-cleanuptest-realm-stale-$$"
touch -d "-70 minutes" "$_stale"
cleanup_temp_files
assert_false test -f "$_stale"

test_that "spares stale *realm* files under a realm/config or realm/rules path"
_dir="/tmp/xwpf-cleanuptest/realm/config"
mkdir -p "$_dir"
_spared="$_dir/realm-fixture.txt"
touch -d "-70 minutes" "$_spared"
cleanup_temp_files
assert_true test -f "$_spared"
rm -rf "/tmp/xwpf-cleanuptest"

end_describe

ptyunit_test_summary
