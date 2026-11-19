#!/usr/bin/env bash
# PTY integration test for the uninstall flow (show_menu() choice 8 ->
# uninstall_realm() -> uninstall_realm_stage_one()/uninstall_script_files()
# in lib/ui.sh). Deliberately kept as an integration test (sequential phase)
# rather than a unit test: uninstall_realm_stage_one() rm -rf's the real
# /etc/realm tree and cleanup_files_by_pattern() sweeps /tmp for *realm*
# files, both far too invasive to run against shared state from a parallel
# unit-test worker.
#
# Requires root and Linux — only run inside tests/Dockerfile.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"

PTY_RUN="$TESTS_DIR/ptyunit/pty_run.py"
INSTALLED_SCRIPT="/usr/local/bin/xwPF.sh"

_pty() { python3 "$PTY_RUN" "$INSTALLED_SCRIPT" "$@" 2>/dev/null; }

_seed_uninstall_fixture() {
    xwpf_clean_system_state
    xwpf_seed_installed_files
    xwpf_seed_fake_realm_binary
    xwpf_seed_realm_service_file
    xwpf_seed_rule 1 8001 true
    xwpf_reset_mock_systemd_state
    touch "$XWPF_MOCK_STATE_DIR/realm.active"
    touch "$XWPF_MOCK_STATE_DIR/realm.enabled"
    # Trivial stand-in for the real (661-line) xwFailover.sh: exercises the
    # "stop the health-check service" branch without invoking the genuine
    # interactive companion script.
    printf '#!/bin/sh\nexit 0\n' > /etc/realm/xwFailover.sh
    chmod +x /etc/realm/xwFailover.sh
    # Mocked pgrep/pkill (tests/mocks/bin) read this flag file instead of
    # touching real processes — see tests/mocks/bin/pgrep for why a real
    # pgrep/pkill pair is unsafe here.
    touch "$XWPF_MOCK_STATE_DIR/fake-realm-proc"
}

ptyunit_test_begin "uninstall: declining stage one cancels immediately, leaving everything in place"
_seed_uninstall_fixture
out=$(_pty 8 ENTER n ENTER ENTER 0 ENTER)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "第一阶段已取消"
assert_true test -f /usr/local/bin/realm
assert_true test -d /etc/realm

ptyunit_test_begin "uninstall: confirming stage one only removes realm files, keeps the script"
_seed_uninstall_fixture
out=$(_pty 8 ENTER y ENTER n ENTER ENTER 0 ENTER)
assert_contains "$out" "第一阶段完成"
assert_contains "$out" "脚本文件保留"
assert_false test -f /usr/local/bin/realm
assert_false test -d /etc/realm
assert_false test -f /etc/systemd/system/realm.service
assert_true test -f /usr/local/bin/xwPF.sh

ptyunit_test_begin "uninstall: confirming both stages removes the script files too"
_seed_uninstall_fixture
out=$(_pty 8 ENTER y ENTER y ENTER ENTER 0 ENTER)
assert_contains "$out" "完全卸载完成"
assert_false test -f /usr/local/bin/xwPF.sh
assert_false test -d /usr/local/bin/lib
assert_false test -f /usr/local/bin/pf

# Re-seed the installed-files symlinks this test just removed. Purely for
# coverage-tool correctness: coverage_report.py resolves each traced
# /usr/local/bin/lib/*.sh path back to the repo checkout via realpath() at
# report-generation time (after every test file has run), which requires
# the symlink to still exist. Without this, being the alphabetically-last
# integration test would silently zero out every PTY-driven test's
# coverage contribution, not just this file's.
xwpf_seed_installed_files

ptyunit_test_summary
