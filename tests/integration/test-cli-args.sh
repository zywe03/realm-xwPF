#!/usr/bin/env bash
# Integration test for main()'s special CLI-arg branches (lib/ui.sh):
# --generate-config-only and --restart-service both exit before reaching
# show_menu, so no interactive input is needed. Still routed through
# pty_run.py (with zero keystrokes) rather than a plain `bash` subprocess
# call: only pty_run.py injects the BASH_ENV coverage-tracing hook, so a
# plain subprocess call would run for real but be invisible to the
# coverage report.
#
# Requires root and Linux — only run inside tests/Dockerfile.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"

PTY_RUN="$TESTS_DIR/ptyunit/pty_run.py"
WRAPPER_GENERATE_CONFIG="$TESTS_DIR/fixtures/run-generate-config-only.sh"
WRAPPER_RESTART_SERVICE="$TESTS_DIR/fixtures/run-restart-service.sh"

_pty() { python3 "$PTY_RUN" "$1" 2>/dev/null; }

xwpf_clean_system_state
xwpf_seed_installed_files
xwpf_reset_mock_systemd_state
xwpf_seed_rule 1 8001 true

ptyunit_test_begin "--generate-config-only writes config.json and exits without showing the menu"
out=$(_pty "$WRAPPER_GENERATE_CONFIG")
rc=$?
assert_eq "0" "$rc"
assert_not_contains "$out" "请选择操作"
assert_file_exists "/etc/realm/config.json"
assert_contains "$(cat /etc/realm/config.json)" "8001"

ptyunit_test_begin "--restart-service restarts the mocked unit and exits with service_restart's status"
xwpf_seed_fake_realm_binary
xwpf_seed_realm_service_file
out=$(_pty "$WRAPPER_RESTART_SERVICE")
rc=$?
assert_eq "0" "$rc"
assert_not_contains "$out" "请选择操作"
assert_eq "active" "$(systemctl is-active realm 2>/dev/null)"

ptyunit_test_summary
