#!/usr/bin/env bash
# PTY integration test for the main menu's restart/stop service options
# (show_menu() choices 3 and 4 in lib/ui.sh), against the mocked systemctl.
#
# Requires root and Linux — only run inside tests/Dockerfile.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"

PTY_RUN="$TESTS_DIR/ptyunit/pty_run.py"
INSTALLED_SCRIPT="/usr/local/bin/xwPF.sh"

_pty() { python3 "$PTY_RUN" "$INSTALLED_SCRIPT" "$@" 2>/dev/null; }

xwpf_clean_system_state
xwpf_seed_installed_files
xwpf_seed_fake_realm_binary
xwpf_seed_realm_service_file
xwpf_seed_rule 1 8001 true
xwpf_reset_mock_systemd_state

ptyunit_test_begin "main menu: restart regenerates config and starts the mocked unit"
out=$(_pty 3 ENTER ENTER 0 ENTER)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "Realm 服务重启成功"
assert_file_exists "/etc/realm/config.json"
assert_contains "$(cat /etc/realm/config.json)" "8001"
assert_eq "active" "$(systemctl is-active realm 2>/dev/null)"

ptyunit_test_begin "main menu: stop deactivates the mocked unit"
out=$(_pty 4 ENTER ENTER 0 ENTER)
assert_contains "$out" "Realm 服务已停止"
assert_eq "inactive" "$(systemctl is-active realm 2>/dev/null)"

ptyunit_test_begin "main menu: status line reflects the stopped state"
out=$(_pty 0 ENTER)
assert_contains "$out" "已停止"

ptyunit_test_summary
