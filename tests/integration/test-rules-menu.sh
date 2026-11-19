#!/usr/bin/env bash
# PTY integration test for rules_management_menu() in lib/ui.sh: toggling and
# deleting a rule, navigated through the real main menu. Rules are
# pre-seeded directly into /etc/realm/rules rather than scripting the full
# interactive_add_rule flow, which is out of scope for this suite.
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
xwpf_reset_mock_systemd_state

ptyunit_test_begin "rules menu: toggling a rule off flips ENABLED and restarts the service"
xwpf_seed_rule 1 8001 true
out=$(_pty 2 ENTER 5 ENTER 1 ENTER ENTER 0 ENTER 0 ENTER)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "规则已禁用"
assert_contains "$out" "Realm 服务重启成功"
assert_contains "$(cat /etc/realm/rules/rule-1.conf)" 'ENABLED="false"'

ptyunit_test_begin "rules menu: deleting a rule removes its file"
xwpf_seed_rule 2 8002 true
out=$(_pty 2 ENTER 4 ENTER 2 ENTER y ENTER ENTER 0 ENTER 0 ENTER)
assert_contains "$out" "规则 2 已删除"
assert_false test -f /etc/realm/rules/rule-2.conf

ptyunit_test_summary
