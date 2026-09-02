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

describe "service wrappers: systemd-only helpers not otherwise exercised" xwpf_reset_mock_systemd_state

test_that "svc_disable calls systemctl disable"
touch "$XWPF_MOCK_STATE_DIR/realm.enabled"
svc_disable
assert_false test -f "$XWPF_MOCK_STATE_DIR/realm.enabled"

test_that "svc_daemon_reload calls systemctl daemon-reload under systemd"
assert_true svc_daemon_reload

test_that "svc_daemon_reload is a no-op under openrc"
INIT_SYSTEM="openrc" assert_false svc_daemon_reload

test_that "svc_status_detail reports systemd status"
out="$(svc_status_detail 2>&1)"
assert_contains "$out" "mock"

end_describe

_openrc_setup() { xwpf_reset_mock_systemd_state; INIT_SYSTEM="openrc"; }
_openrc_teardown() { INIT_SYSTEM="systemd"; }

describe "service wrappers: openrc branch" _openrc_setup _openrc_teardown

test_that "svc_start/svc_is_active/svc_status_text round-trip through rc-service"
assert_false svc_is_active
assert_eq "inactive" "$(svc_status_text)"
svc_start
assert_true svc_is_active
assert_eq "active" "$(svc_status_text)"

test_that "svc_stop clears the active flag"
touch "$XWPF_MOCK_STATE_DIR/realm.active"
svc_stop
assert_false svc_is_active

test_that "svc_restart marks the service active"
svc_restart
assert_true svc_is_active

test_that "svc_enable/svc_enabled_text/svc_disable round-trip through rc-update"
assert_eq "disabled" "$(svc_enabled_text)"
svc_enable
assert_eq "enabled" "$(svc_enabled_text)"
svc_disable
assert_eq "disabled" "$(svc_enabled_text)"

test_that "svc_status_detail reports rc-service status"
touch "$XWPF_MOCK_STATE_DIR/realm.active"
out="$(svc_status_detail 2>&1)"
assert_contains "$out" "started"

end_describe

describe "detect_virtualization"

test_that "detects the real Docker container this suite always runs in"
assert_eq "Docker容器" "$(detect_virtualization)"

end_describe

_virt_setup() { xwpf_hide_dockerenv; }
_virt_teardown() { xwpf_restore_dockerenv; unset XWPF_MOCK_VIRT; }

describe "detect_virtualization: systemd-detect-virt fallback" _virt_setup _virt_teardown

test_that "maps systemd-detect-virt=kvm to KVM虚拟机"
export XWPF_MOCK_VIRT="kvm"
assert_eq "KVM虚拟机" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=qemu to QEMU虚拟机"
export XWPF_MOCK_VIRT="qemu"
assert_eq "QEMU虚拟机" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=vmware to VMware虚拟机"
export XWPF_MOCK_VIRT="vmware"
assert_eq "VMware虚拟机" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=xen to Xen虚拟机"
export XWPF_MOCK_VIRT="xen"
assert_eq "Xen虚拟机" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=lxc to LXC容器"
export XWPF_MOCK_VIRT="lxc"
assert_eq "LXC容器" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=docker to Docker容器"
export XWPF_MOCK_VIRT="docker"
assert_eq "Docker容器" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=openvz to OpenVZ容器"
export XWPF_MOCK_VIRT="openvz"
assert_eq "OpenVZ容器" "$(detect_virtualization)"

test_that "maps systemd-detect-virt=none to 物理机"
export XWPF_MOCK_VIRT="none"
assert_eq "物理机" "$(detect_virtualization)"

test_that "falls back to an annotated 未知虚拟化 label for anything else"
export XWPF_MOCK_VIRT="bhyve"
assert_eq "未知虚拟化(bhyve)" "$(detect_virtualization)"

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
