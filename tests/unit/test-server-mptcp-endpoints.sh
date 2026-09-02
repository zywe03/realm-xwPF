#!/usr/bin/env bash
# Unit tests for lib/server.sh's MPTCP interface/endpoint selection and
# add/delete flows: mptcp_select_interface, mptcp_select_ips,
# mptcp_select_endpoint_type, mptcp_select_endpoint_to_delete,
# add_mptcp_endpoint_interactive, delete_mptcp_endpoint_interactive.
# Driven against the mock `ip` (XWPF_MOCK_IP_*, see tests/mocks/bin/ip).
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

describe "mptcp_select_interface"

test_that "lists interfaces with a configured address and returns the chosen one"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:,eth1::fd00::1/64" mptcp_select_interface <<< "2")
assert_eq "eth1" "$out"

test_that "fails with an error when no interface has any address"
err=$(XWPF_MOCK_IP_INTERFACES="" mptcp_select_interface 2>&1 >/dev/null)
XWPF_MOCK_IP_INTERFACES="" mptcp_select_interface >/dev/null 2>/dev/null
status=$?
assert_eq "1" "$status"
assert_contains "$err" "未找到配置IP地址的网络接口"

test_that "rejects an out-of-range selection"
err=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:" mptcp_select_interface <<< "9" 2>&1 >/dev/null)
assert_contains "$err" "无效的选择"

end_describe

describe "mptcp_select_ips"

test_that "selects all IPs when input is empty"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:fd00::1/64" mptcp_select_ips "eth0" <<< "")
assert_contains "$out" "10.0.0.5"
assert_contains "$out" "fd00::1"

test_that "selects a single IP by index"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:fd00::1/64" mptcp_select_ips "eth0" <<< "2")
assert_eq "fd00::1" "$out"

test_that "fails when the interface has no addresses at all"
err=$(XWPF_MOCK_IP_INTERFACES="eth0::" mptcp_select_ips "eth0" 2>&1 >/dev/null)
assert_contains "$err" "选中的网卡没有可用的IP地址"

test_that "rejects an out-of-range index"
err=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:" mptcp_select_ips "eth0" <<< "9" 2>&1 >/dev/null)
assert_contains "$err" "无效的选择"

end_describe

describe "mptcp_select_endpoint_type"

test_that "defaults to subflow fullmesh on an empty selection"
out=$(mptcp_select_endpoint_type <<< "")
assert_eq "subflow fullmesh" "$out"

test_that "maps choice 2 to signal"
out=$(mptcp_select_endpoint_type <<< "2")
assert_eq "signal" "$out"

test_that "maps choice 3 to subflow backup"
out=$(mptcp_select_endpoint_type <<< "3")
assert_eq "subflow backup" "$out"

test_that "errors on an invalid choice"
err=$(mptcp_select_endpoint_type <<< "9" 2>&1 >/dev/null)
status=$(mptcp_select_endpoint_type <<< "9" >/dev/null 2>/dev/null; echo $?)
assert_eq "1" "$status"
assert_contains "$err" "无效的选择"

end_describe

describe "mptcp_select_endpoint_to_delete"

test_that "lists endpoints and returns the raw line for the chosen index"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS=$'10.0.0.5 id 1 dev eth0 subflow fullmesh\n10.0.0.6 id 2 dev eth1 signal' mptcp_select_endpoint_to_delete <<< "2")
assert_eq "10.0.0.6 id 2 dev eth1 signal" "$out"

test_that "fails when there are no endpoints to choose from"
err=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="" mptcp_select_endpoint_to_delete 2>&1 >/dev/null)
assert_contains "$err" "暂无MPTCP端点配置"

test_that "rejects an out-of-range choice"
err=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="10.0.0.5 id 1 dev eth0 subflow fullmesh" mptcp_select_endpoint_to_delete <<< "9" 2>&1 >/dev/null)
assert_contains "$err" "无效的选择"

end_describe

describe "add_mptcp_endpoint_interactive"

test_that "adds an endpoint for each selected IP and reports the success count"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:" XWPF_MOCK_IP_MPTCP_ENDPOINTS="" \
    add_mptcp_endpoint_interactive <<< $'1\n\n1\n')
assert_contains "$out" "MPTCP端点添加成功: 10.0.0.5"
assert_contains "$out" "添加结果: 成功 1/1"

test_that "reports failures and possible causes when every add fails"
out=$(XWPF_MOCK_IP_INTERFACES="eth0:10.0.0.5/24:" XWPF_MOCK_IP_MPTCP_ADD_FAIL=1 \
    add_mptcp_endpoint_interactive <<< $'1\n\n1\n')
assert_contains "$out" "MPTCP端点添加失败: 10.0.0.5"
assert_contains "$out" "添加结果: 成功 0/1"
assert_contains "$out" "可能的原因"

test_that "stops early when interface selection fails"
out=$(XWPF_MOCK_IP_INTERFACES="" add_mptcp_endpoint_interactive)
status=$?
assert_eq "1" "$status"

end_describe

describe "delete_mptcp_endpoint_interactive"

test_that "deletes the selected endpoint on confirmation"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="10.0.0.5 id 1 dev eth0 subflow fullmesh" \
    delete_mptcp_endpoint_interactive <<< $'1\ny\n')
assert_contains "$out" "MPTCP端点删除成功"

test_that "reports a failure when the delete command fails"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="10.0.0.5 id 1 dev eth0 subflow fullmesh" XWPF_MOCK_IP_MPTCP_DELETE_FAIL=1 \
    delete_mptcp_endpoint_interactive <<< $'1\ny\n')
assert_contains "$out" "MPTCP端点删除失败"

test_that "cancels without deleting when not confirmed"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="10.0.0.5 id 1 dev eth0 subflow fullmesh" \
    delete_mptcp_endpoint_interactive <<< $'1\nn\n')
assert_contains "$out" "已取消删除操作"

test_that "returns early when there are no endpoints to select from"
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="" delete_mptcp_endpoint_interactive)
status=$?
assert_eq "0" "$status"

end_describe

ptyunit_test_summary
