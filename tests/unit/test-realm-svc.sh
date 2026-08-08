#!/usr/bin/env bash
# Unit tests for the standalone helpers in lib/realm.sh that aren't already
# covered by the integration suite: the systemd-facing service-status
# wrappers (svc_is_active, svc_status_text, svc_enabled_text) against the
# mocked systemctl, virtualization detection, and the mocked-curl download/
# version-lookup helpers. svc_start/svc_stop/svc_restart/svc_enable and
# svc_status_detail are already exercised end-to-end by
# test-service-lifecycle.sh and test-install-offline.sh; svc_logs is a
# foreground `journalctl -f` and isn't safe to call from a test process.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"

INIT_SYSTEM="systemd"

describe "svc_is_active / svc_status_text" xwpf_reset_mock_systemd_state

test_that "reports inactive when the mock has no active flag"
assert_false svc_is_active
assert_eq "inactive" "$(svc_status_text)"

test_that "reports active once the mock unit is marked active"
touch "$XWPF_MOCK_STATE_DIR/realm.active"
assert_true svc_is_active
assert_eq "active" "$(svc_status_text)"

end_describe

describe "svc_enabled_text" xwpf_reset_mock_systemd_state

test_that "reports disabled by default"
assert_eq "disabled" "$(svc_enabled_text)"

test_that "reports enabled once the mock unit is marked enabled"
touch "$XWPF_MOCK_STATE_DIR/realm.enabled"
assert_eq "enabled" "$(svc_enabled_text)"

end_describe

describe "detect_virtualization"

test_that "detects the real Docker container this suite always runs in"
assert_eq "Docker容器" "$(detect_virtualization)"

end_describe

describe "download_from_sources"

test_that "reports success and copies the file when the mocked URL resolves"
dest="$(mktemp -u /tmp/xwpf-dl.XXXXXX)"
assert_true download_from_sources "https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh" "$dest"
assert_file_exists "$dest"
rm -f "$dest"

test_that "reports failure for a URL the mock can't reach"
dest="$(mktemp -u /tmp/xwpf-dl.XXXXXX)"
assert_false download_from_sources "https://github.com/zhboner/realm/releases" "$dest"

end_describe

describe "get_latest_realm_version"

test_that "falls back to the bundled REALM_VERSION when the mocked upstream is unreachable"
assert_eq "$REALM_VERSION" "$(get_latest_realm_version 2>/dev/null)"

end_describe

ptyunit_test_summary
