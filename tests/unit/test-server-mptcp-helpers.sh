#!/usr/bin/env bash
# Unit tests for lib/server.sh's small, mostly-pure MPTCP helper functions:
# get_mptcp_mode_display, get_mptcp_mode_color, init_mptcp_fields,
# check_mptcp_support, upgrade_iproute2_for_mptcp, enable_mptcp, disable_mptcp.
#
# check_mptcp_support/enable_mptcp/disable_mptcp shell out to `ip`/`sysctl`;
# the mock `ip` at tests/mocks/bin/ip (also installed at /usr/bin/ip, see
# tests/Dockerfile) makes MPTCP netlink ops deterministic. The container's
# real kernel never exposes /proc/sys/net/mptcp/enabled, so that branch is
# permanently unreachable here regardless of mocking (see also lib/rules.sh's
# equivalent, already documented as an environment-dependent gap).
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

describe "get_mptcp_mode_display"

test_that "maps each known mode to its Chinese label"
assert_eq "关闭" "$(get_mptcp_mode_display "off")"
assert_eq "发送" "$(get_mptcp_mode_display "send")"
assert_eq "接收" "$(get_mptcp_mode_display "accept")"
assert_eq "双向" "$(get_mptcp_mode_display "both")"

test_that "defaults an unrecognized mode to 关闭"
assert_eq "关闭" "$(get_mptcp_mode_display "bogus")"

end_describe

describe "get_mptcp_mode_color"

test_that "maps each known mode to its color variable"
assert_eq "$WHITE" "$(get_mptcp_mode_color "off")"
assert_eq "$BLUE" "$(get_mptcp_mode_color "send")"
assert_eq "$YELLOW" "$(get_mptcp_mode_color "accept")"
assert_eq "$GREEN" "$(get_mptcp_mode_color "both")"

test_that "defaults an unrecognized mode to white"
assert_eq "$WHITE" "$(get_mptcp_mode_color "bogus")"

end_describe

_setup_rules_dir() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
}
_teardown_rules_dir() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

describe "init_mptcp_fields" _setup_rules_dir _teardown_rules_dir

test_that "appends MPTCP_MODE=off to a rule file that doesn't have it yet"
cat > "${RULES_DIR}/rule-1.conf" <<EOF
RULE_ID=1
RULE_NAME=relay-1
EOF
init_mptcp_fields
assert_true grep -q '^MPTCP_MODE="off"' "${RULES_DIR}/rule-1.conf"

test_that "leaves an existing MPTCP_MODE field untouched"
cat > "${RULES_DIR}/rule-1.conf" <<EOF
RULE_ID=1
MPTCP_MODE="send"
EOF
init_mptcp_fields
count=$(grep -c '^MPTCP_MODE=' "${RULES_DIR}/rule-1.conf")
assert_eq "1" "$count"
assert_true grep -q '^MPTCP_MODE="send"' "${RULES_DIR}/rule-1.conf"

test_that "does nothing when RULES_DIR does not exist"
rm -rf "$RULES_DIR"
assert_true init_mptcp_fields

end_describe

describe "check_mptcp_support"

test_that "returns 1 (unsupported) when the kernel major version is below 5"
result=$( (uname() { echo "4.19.0-generic"; }; check_mptcp_support); echo $? )
assert_eq "1" "$result"

test_that "returns 1 (unsupported) when kernel is 5.6 or older"
result=$( (uname() { echo "5.6.0-generic"; }; check_mptcp_support); echo $? )
assert_eq "1" "$result"

test_that "returns 1 when kernel is new enough but /proc/sys/net/mptcp/enabled is absent"
assert_false check_mptcp_support

end_describe

describe "upgrade_iproute2_for_mptcp"

test_that "reports success immediately when ip mptcp help already advertises endpoint/limits"
out=$(upgrade_iproute2_for_mptcp)
assert_contains "$out" "当前版本已支持MPTCP"

test_that "attempts an apt upgrade when ip mptcp help doesn't advertise support, and fails when it still doesn't afterward"
out=$(XWPF_MOCK_IP_MPTCP_UNSUPPORTED=1 upgrade_iproute2_for_mptcp)
assert_contains "$out" "当前版本不支持MPTCP，开始升级"
assert_contains "$out" "升级后仍不支持MPTCP"
assert_not_contains "$out" "升级成功"

end_describe

describe "enable_mptcp" _setup_rules_dir _teardown_rules_dir

_cleanup_mptcp_conf() {
    rm -f /etc/sysctl.d/90-enable-MPTCP.conf
}

test_that "creates the sysctl conf file, and reports when sysctl -p fails to apply it immediately"
_cleanup_mptcp_conf
out=$(XWPF_MOCK_SYSCTL_FAIL=1 enable_mptcp)
assert_contains "$out" "MPTCP配置文件已创建"
assert_contains "$out" "配置文件已创建，但立即应用失败"
assert_true test -f /etc/sysctl.d/90-enable-MPTCP.conf
assert_true grep -q "net.mptcp.enabled=1" /etc/sysctl.d/90-enable-MPTCP.conf
_cleanup_mptcp_conf

test_that "completes all steps and reports success when sysctl applies cleanly"
_cleanup_mptcp_conf
out=$(enable_mptcp)
assert_contains "$out" "MPTCP已成功启用并保存生效"
assert_contains "$out" "已切换到内核路径管理器"
assert_contains "$out" "已优化反向路径过滤设置"
assert_contains "$out" "MPTCP连接限制已设置为最大值"
assert_contains "$out" "MPTCP基础配置完成"
_cleanup_mptcp_conf

test_that "reports a failure when the MPTCP connection-limits command fails"
out=$(XWPF_MOCK_IP_MPTCP_LIMITS_FAIL=1 enable_mptcp)
assert_contains "$out" "无法设置MPTCP连接限制，使用默认值"
_cleanup_mptcp_conf

test_that "reports a failure when only the path-manager sysctl key fails to apply"
out=$(XWPF_MOCK_SYSCTL_FAIL_KEYS="net.mptcp.pm_type" enable_mptcp)
assert_contains "$out" "无法设置路径管理器类型"
assert_not_contains "$out" "已切换到内核路径管理器"
_cleanup_mptcp_conf

test_that "detects and stops an active mptcpd service"
touch "$XWPF_MOCK_STATE_DIR/mptcpd.active"
out=$(enable_mptcp)
assert_contains "$out" "检测到mptcpd服务，正在停止"
assert_contains "$out" "已停止mptcpd服务"
rm -f "$XWPF_MOCK_STATE_DIR/mptcpd.active"
_cleanup_mptcp_conf

test_that "reports failure to create the sysctl conf file when the target directory is unwritable"
mv /etc/sysctl.d /etc/sysctl.d.bak
out=$(enable_mptcp)
assert_contains "$out" "错误: 无法创建MPTCP配置文件"
rmdir /etc/sysctl.d 2>/dev/null
mv /etc/sysctl.d.bak /etc/sysctl.d

end_describe

describe "disable_mptcp" _setup_rules_dir _teardown_rules_dir

test_that "flushes existing MPTCP endpoints and reports the config file was removed"
echo "net.mptcp.enabled=1" > /etc/sysctl.d/90-enable-MPTCP.conf
out=$(XWPF_MOCK_IP_MPTCP_ENDPOINTS="10.0.0.5 id 1 dev eth0 subflow fullmesh" disable_mptcp)
assert_contains "$out" "已清理所有MPTCP端点"
assert_contains "$out" "MPTCP配置文件已删除"
assert_false test -f /etc/sysctl.d/90-enable-MPTCP.conf

test_that "reports no endpoints to clean up when the endpoint list is empty"
out=$(disable_mptcp)
assert_contains "$out" "无MPTCP端点需要清理"

test_that "reports no config file to delete when none exists"
rm -f /etc/sysctl.d/90-enable-MPTCP.conf
out=$(disable_mptcp)
assert_contains "$out" "无配置文件需要删除"

test_that "reports the ip mptcp command is unavailable and skips endpoint cleanup"
out=$(XWPF_MOCK_IP_MPTCP_UNAVAILABLE=1 disable_mptcp)
assert_contains "$out" "ip mptcp命令不可用，跳过端点清理"

end_describe

ptyunit_test_summary
