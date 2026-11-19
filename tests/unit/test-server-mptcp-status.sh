#!/usr/bin/env bash
# Unit tests for lib/server.sh's MPTCP status/display functions:
# get_network_interfaces_detailed, get_mptcp_endpoints_status,
# get_mptcp_connections_stats, show_mptcp_detailed_status,
# mptcp_display_dashboard, mptcp_check_and_persist_config,
# mptcp_handle_unsupported_state. Driven against the mock `ip`/`sysctl`
# (XWPF_MOCK_IP_*/XWPF_MOCK_SYSCTL_FAIL, see tests/mocks/bin/ip and
# tests/mocks/bin/sysctl).
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

# /proc/sys/net/mptcp/enabled never exists in this container regardless of
# kernel version (see check_mptcp_support's docs elsewhere), so branches
# gated on `[ -f "/proc/sys/net/mptcp/enabled" ]` or reading its content via
# `cat` are otherwise unreachable. Shadowing both `[` (the -f test) and
# `cat` inside a subshell fakes the file's presence/content without
# touching real /proc. Must use `command [`/`command cat` internally to
# avoid infinite recursion into the overridden functions.
# Note: cat() below reads XWPF_STUB_PROC_VALUE (a global) rather than a
# local of _stub_proc_enabled, since bash's dynamic scoping means a local
# var is gone from the call stack by the time cat() is later invoked from
# inside the function under test.
_stub_proc_enabled() {
    XWPF_STUB_PROC_VALUE="${1:-1}"
    function [ {
        if command [ "$1" = "-f" ] && command [ "$2" = "/proc/sys/net/mptcp/enabled" ] && command [ "${*: -1}" = "]" ]; then
            return 0
        fi
        command "[" "$@"
    }
    cat() {
        if command [ "$1" = "/proc/sys/net/mptcp/enabled" ]; then
            echo "$XWPF_STUB_PROC_VALUE"
        else
            command cat "$@"
        fi
    }
}

describe "get_network_interfaces_detailed"

test_that "lists each non-loopback interface's IPv4/IPv6 status"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:fd00::1/64,eth1::" get_network_interfaces_detailed)
assert_contains "$out" "网卡 eth0: 10.0.0.5/24 (IPv4) | fd00::1/64 (IPv6)"
assert_contains "$out" "网卡 eth1: 未配置IPv4 | 未配置IPv6"

test_that "flags an interface with a dot in its name as a VLAN"
out=$(XWPF_MOCK_IP_INTERFACES="eth0.100:10.0.0.5/24:" get_network_interfaces_detailed)
assert_contains "$out" "(VLAN)"

test_that "prints nothing extra when there are no interfaces"
out=$(XWPF_MOCK_IP_INTERFACES="" get_network_interfaces_detailed)
assert_eq "" "$out"

end_describe

describe "get_mptcp_endpoints_status"

test_that "lists each endpoint with its parsed id/addr/dev/flags"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS=$'10.0.0.5 id 1 dev eth0 subflow fullmesh\n10.0.0.6 id 2 dev eth1 signal\n10.0.0.7 id 3 dev eth1 subflow backup\n10.0.0.8 id 4 dev eth1 other' get_mptcp_endpoints_status)
assert_contains "$out" "ID 1: 10.0.0.5 dev eth0 [subflow fullmesh]"
assert_contains "$out" "ID 2: 10.0.0.6 dev eth1 [signal]"
assert_contains "$out" "ID 3: 10.0.0.7 dev eth1 [subflow backup]"
assert_contains "$out" "ID 4: 10.0.0.8 dev eth1 [unknown]"

test_that "reports no endpoints when the list is empty"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="" get_mptcp_endpoints_status)
assert_contains "$out" "暂无MPTCP端点配置"

end_describe

describe "get_mptcp_connections_stats"

test_that "reports zero connections and subflows when ss shows nothing"
out=$(get_mptcp_connections_stats)
assert_contains "$out" "活跃连接: 0个 | 子流: 0个 (无连接时为0正常现象)"

end_describe

describe "show_mptcp_detailed_status"

test_that "renders the sysctl status, limits, interfaces, and connection sections"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="" show_mptcp_detailed_status)
assert_contains "$out" "MPTCP详细状态"
assert_contains "$out" "MPTCP未启用"
assert_contains "$out" "MPTCP连接限制:"
assert_contains "$out" "subflows 2 add_addr_accepted 0"
assert_contains "$out" "网络接口状态:"
assert_contains "$out" "暂无活跃MPTCP连接"

test_that "falls back to an unavailable message when ip mptcp monitor fails"
out=$(XWPF_MOCK_IP_MPTCP_MONITOR_FAIL=1 show_mptcp_detailed_status)
assert_contains "$out" "MPTCP事件监控不可用"

test_that "reports MPTCP as enabled when the proc value is 1"
out=$(_stub_proc_enabled 1; XWPF_MOCK_IP_MPTCP_ENDPOINTS="" show_mptcp_detailed_status)
assert_contains "$out" "MPTCP已启用"
assert_contains "$out" "net.mptcp.enabled=1"

end_describe

describe "mptcp_display_dashboard"

test_that "renders the interfaces section followed by the endpoints and connection-stats sections"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:" XWPF_MOCK_IP_MPTCP_ENDPOINTS="" mptcp_display_dashboard)
assert_contains "$out" "网络环境状态:"
assert_contains "$out" "网卡 eth0"
assert_contains "$out" "MPTCP端点配置:"
assert_contains "$out" "MPTCP连接统计:"

end_describe

_cleanup_mptcp_conf() {
    rm -f /etc/sysctl.d/90-enable-MPTCP.conf
}

describe "mptcp_check_and_persist_config" "" _cleanup_mptcp_conf

test_that "reports MPTCP is not enabled when the sysctl proc value is not 1"
out=$(mptcp_check_and_persist_config)
status=$?
assert_contains "$out" "系统未开启MPTCP"
assert_eq "1" "$status"

test_that "reports already-configured when enabled and the config file exists"
echo "net.mptcp.enabled=1" > /etc/sysctl.d/90-enable-MPTCP.conf
out=$(_stub_proc_enabled 1; mptcp_check_and_persist_config)
assert_contains "$out" "系统已开启MPTCP"
assert_contains "$out" "MPTCP配置已设置"
_cleanup_mptcp_conf

test_that "declines to persist a temporary enable when not confirmed"
_cleanup_mptcp_conf
out=$(_stub_proc_enabled 1; mptcp_check_and_persist_config <<< "n")
assert_contains "$out" "临时开启，重启后可能失效"
assert_not_contains "$out" "配置已保存"
_cleanup_mptcp_conf

test_that "persists the config and reports immediate success when confirmed"
_cleanup_mptcp_conf
out=$(_stub_proc_enabled 1; mptcp_check_and_persist_config <<< $'y\n\n')
assert_contains "$out" "MPTCP配置已保存"
assert_contains "$out" "配置已立即生效"
assert_true test -f /etc/sysctl.d/90-enable-MPTCP.conf
_cleanup_mptcp_conf

test_that "persists the config but reports apply failure when sysctl -p fails"
_cleanup_mptcp_conf
out=$(_stub_proc_enabled 1; XWPF_MOCK_SYSCTL_FAIL=1 mptcp_check_and_persist_config <<< $'y\n\n')
assert_contains "$out" "MPTCP配置已保存"
assert_contains "$out" "配置文件已保存，但立即应用失败"
_cleanup_mptcp_conf

test_that "reports save failure when the config file can't be written"
_cleanup_mptcp_conf
mv /etc/sysctl.d /etc/sysctl.d.bak
out=$(_stub_proc_enabled 1; mptcp_check_and_persist_config <<< "y")
assert_contains "$out" "保存MPTCP配置失败"
rmdir /etc/sysctl.d 2>/dev/null
mv /etc/sysctl.d.bak /etc/sysctl.d

end_describe

describe "mptcp_handle_unsupported_state"

test_that "reports an unsupported-kernel finding and skips enabling when declined"
result=$( (uname() { echo "4.19.0-generic"; }; mptcp_handle_unsupported_state <<< $'n\n') )
assert_contains "$result" "系统不支持MPTCP或未启用"
assert_contains "$result" "内核版本不支持MPTCP"

test_that "reports a supported-kernel finding when the kernel is new enough"
result=$(mptcp_handle_unsupported_state <<< $'n\n')
assert_contains "$result" "内核版本支持MPTCP"
assert_contains "$result" "系统不支持MPTCP"

test_that "offers to enable MPTCP and calls enable_mptcp when confirmed"
result=$(mptcp_handle_unsupported_state <<< $'y\n')
assert_contains "$result" "正在启用MPTCP并进行配置"
rm -f /etc/sysctl.d/90-enable-MPTCP.conf

test_that "reports MPTCP as already enabled when the proc value is 1"
result=$(_stub_proc_enabled 1; mptcp_handle_unsupported_state <<< $'n\n')
assert_contains "$result" "MPTCP已启用"
assert_contains "$result" "net.mptcp.enabled=1"

end_describe

ptyunit_test_summary
