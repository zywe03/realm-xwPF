#!/usr/bin/env bash
# PTY integration test for `xwPF.sh install`, the real bootstrap entrypoint
# (equivalent to `curl ... | sudo bash -s install`). Drives it through the
# built-in offline-install prompt so no real download of the realm binary
# is needed; the script-file bootstrap itself still goes through the mocked
# curl, so _bootstrap()/_load_libs() get real coverage.
#
# Requires root and Linux (writes to /usr/local/bin, /etc/realm,
# /etc/systemd/system) — only run inside tests/Dockerfile.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"

PTY_RUN="$TESTS_DIR/ptyunit/pty_run.py"
WRAPPER="$TESTS_DIR/fixtures/run-install.sh"

_pty() { python3 "$PTY_RUN" "$WRAPPER" "$@" 2>/dev/null; }

xwpf_clean_system_state
xwpf_reset_mock_systemd_state

tarball="$(xwpf_build_fake_realm_tarball)"

ptyunit_test_begin "install: offline path installs realm, generates config and unit, starts service"
out=$(_pty "$tarball" ENTER)
rc=$?

assert_eq "0" "$rc"
assert_contains "$out" "realm 安装成功"
assert_contains "$out" "安装完成"
assert_file_exists "/usr/local/bin/realm"
assert_file_exists "/etc/realm/config.json"
assert_file_exists "/etc/systemd/system/realm.service"
assert_eq "active" "$(systemctl is-active realm 2>/dev/null)"
assert_eq "enabled" "$(systemctl is-enabled realm 2>/dev/null)"

ptyunit_test_summary
