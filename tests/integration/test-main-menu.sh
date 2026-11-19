#!/usr/bin/env bash
# PTY integration test for the main menu (show_menu() in lib/ui.sh), driven
# through the real installed entrypoint (/usr/local/bin/xwPF.sh) the same
# way the `pf` shortcut would invoke it.
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
xwpf_reset_mock_systemd_state

ptyunit_test_begin "main menu: shows header and prompts to install when realm is missing"
out=$(_pty 0 ENTER)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "xwPF Realm"
assert_contains "$out" "未安装"
assert_contains "$out" "感谢使用"

ptyunit_test_begin "main menu: rejects an out-of-range choice, then exits cleanly"
out=$(_pty 9 ENTER ENTER 0 ENTER)
assert_contains "$out" "无效选择"
assert_contains "$out" "感谢使用"

ptyunit_test_summary
