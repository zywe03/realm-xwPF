#!/usr/bin/env bash
# Unit tests for lib/server.sh's MPTCP per-rule mode setters and the
# mptcp_management_menu dispatcher: set_mptcp_mode, batch_set_mptcp_mode,
# mptcp_management_menu. Mirrors tests/unit/test-rules-proxy*.sh's approach
# to rules.sh's analogous PROXY_MODE flow.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

INIT_SYSTEM="systemd"

_make_relay_rule() {
    local id="$1" port="$2"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=relay-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=10.0.0.1
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
MPTCP_MODE=off
EOF
}

_setup_rules_dir() {
    xwpf_lock_realm_config
    xwpf_reset_mock_systemd_state
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
}

_teardown_rules_dir() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f /etc/realm/config.json /etc/systemd/system/realm.service
    xwpf_unlock_realm_config
}

describe "set_mptcp_mode" _setup_rules_dir _teardown_rules_dir

test_that "disables system MPTCP when rule ID is 0, without touching any rule file"
out=$(set_mptcp_mode "0" "" <<< "")
assert_contains "$out" "系统MPTCP已关闭"

test_that "errors when the target rule does not exist"
out=$(set_mptcp_mode "99" "1")
assert_contains "$out" "规则 99 不存在"

test_that "rejects an invalid mode choice"
_make_relay_rule 1 8001
out=$(set_mptcp_mode "1" "9")
assert_contains "$out" "无效的模式选择"

test_that "updates MPTCP_MODE and restarts the service on success"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(set_mptcp_mode "1" "2" <<< "")
assert_contains "$out" "MPTCP模式已更新为"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "send" "$MPTCP_MODE"

test_that "sets mode off when mode_choice is 1"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(set_mptcp_mode "1" "1" <<< "")
assert_contains "$out" "MPTCP模式已更新为"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$MPTCP_MODE"

test_that "appends a new MPTCP_MODE field when the rule file doesn't already have one"
cat > "${RULES_DIR}/rule-1.conf" <<EOF
RULE_ID=1
RULE_NAME=relay-1
LISTEN_PORT=8001
RULE_ROLE=1
REMOTE_HOST=10.0.0.1
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
EOF
xwpf_seed_realm_service_file
out=$(set_mptcp_mode "1" "2" <<< "")
assert_contains "$out" "MPTCP模式已更新为"
count=$(grep -c '^MPTCP_MODE=' "${RULES_DIR}/rule-1.conf")
assert_eq "1" "$count"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "send" "$MPTCP_MODE"

test_that "replaces an existing MPTCP_MODE field rather than duplicating it"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
set_mptcp_mode "1" "4" <<< "" >/dev/null
set_mptcp_mode "1" "3" <<< "" >/dev/null
count=$(grep -c '^MPTCP_MODE=' "${RULES_DIR}/rule-1.conf")
assert_eq "1" "$count"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "accept" "$MPTCP_MODE"

test_that "suppresses the per-rule status lines in batch mode"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(set_mptcp_mode "1" "2" "batch" <<< "")
assert_not_contains "$out" "正在为规则"
assert_not_contains "$out" "MPTCP模式已更新为"

end_describe

describe "batch_set_mptcp_mode" _setup_rules_dir _teardown_rules_dir

test_that "rejects the whole batch when any rule ID is invalid"
_make_relay_rule 1 8001
out=$(batch_set_mptcp_mode "1,99" "2")
assert_contains "$out" "以下规则ID无效或不存在"

test_that "errors when no valid rule IDs are found"
out=$(batch_set_mptcp_mode "" "2")
assert_contains "$out" "没有找到有效的规则ID"

test_that "reports failure when none of the rules could be updated"
_make_relay_rule 1 8001
out=$(batch_set_mptcp_mode "1" "9" <<< "y")
assert_contains "$out" "没有成功设置任何规则"

test_that "sets the mode for every valid rule and restarts the service once"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
xwpf_seed_realm_service_file
out=$(batch_set_mptcp_mode "1,2" "4" <<< "y")
assert_contains "$out" "成功设置 2 个规则的MPTCP模式"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"; assert_eq "both" "$MPTCP_MODE"
read_rule_file "${RULES_DIR}/rule-2.conf"; assert_eq "both" "$MPTCP_MODE"

test_that "reports a failure message when the post-update service restart fails"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(XWPF_MOCK_SYSTEMCTL_RESTART_FAIL=1 batch_set_mptcp_mode "1" "2" <<< "y")
assert_contains "$out" "成功设置 1 个规则的MPTCP模式"
assert_contains "$out" "服务重启失败，请检查配置"

test_that "cancels without changing anything when not confirmed"
_make_relay_rule 1 8001
out=$(batch_set_mptcp_mode "1" "2" <<< "n")
assert_contains "$out" "操作已取消"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$MPTCP_MODE"

end_describe

describe "mptcp_management_menu" _setup_rules_dir _teardown_rules_dir

# check_mptcp_support is unconditionally false in this container (kernel
# version can be mocked, but /proc/sys/net/mptcp/enabled never exists here
# regardless — see test-server-mptcp-helpers.sh). Stubbing it out to "true"
# per-subshell is the only way to reach mptcp_management_menu's logic past
# its initial support gate.
_stub_supported() { check_mptcp_support() { return 0; }; }

test_that "reports the unsupported state and returns when MPTCP support is unavailable"
out=$(mptcp_management_menu <<< $'n\n')
assert_contains "$out" "MPTCP 管理"
assert_contains "$out" "系统不支持MPTCP或未启用"

test_that "returns after showing the dashboard when there are no rules"
out=$(_stub_supported; mptcp_management_menu)
assert_contains "$out" "网络环境状态"

test_that "dispatches rule ID 0 to system-MPTCP-off after confirmation"
_make_relay_rule 1 8001
out=$(_stub_supported; mptcp_management_menu <<< $'0\ny\n\n')
assert_contains "$out" "系统MPTCP已关闭"

test_that "dispatches a comma-separated rule ID list to batch_set_mptcp_mode"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
xwpf_seed_realm_service_file
out=$(_stub_supported; mptcp_management_menu <<< $'1,2\n2\ny\n\n')
assert_contains "$out" "成功设置 2 个规则的MPTCP模式"

test_that "dispatches a single numeric rule ID to set_mptcp_mode"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(_stub_supported; mptcp_management_menu <<< $'1\n3\n\n')
assert_contains "$out" "MPTCP模式已更新为"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "accept" "$MPTCP_MODE"

test_that "rejects a non-numeric, non-comma rule ID"
_make_relay_rule 1 8001
out=$(_stub_supported; mptcp_management_menu <<< $'abc\n1\n\n')
assert_contains "$out" "无效的规则ID"

test_that "returns without dispatching when the rule ID prompt is left empty"
_make_relay_rule 1 8001
out=$(_stub_supported; mptcp_management_menu <<< "")
assert_not_contains "$out" "无效的规则ID"

test_that "returns without dispatching when the mode-choice prompt is left empty"
_make_relay_rule 1 8001
out=$(_stub_supported; mptcp_management_menu <<< $'1\n\n')
assert_not_contains "$out" "MPTCP模式已更新为"

test_that "dispatches the add subcommand to add_mptcp_endpoint_interactive"
_make_relay_rule 1 8001
out=$(_stub_supported; XWPF_MOCK_IP_INTERFACES="" mptcp_management_menu <<< $'add\n\n\n')
assert_contains "$out" "添加MPTCP端点"

test_that "dispatches the del subcommand to delete_mptcp_endpoint_interactive"
_make_relay_rule 1 8001
out=$(_stub_supported; XWPF_MOCK_IP_MPTCP_ENDPOINTS="" mptcp_management_menu <<< $'del\n\n\n')
assert_contains "$out" "删除MPTCP端点"

test_that "dispatches the look subcommand to show_mptcp_detailed_status"
_make_relay_rule 1 8001
out=$(_stub_supported; XWPF_MOCK_IP_MPTCP_ENDPOINTS="" mptcp_management_menu <<< $'look\n\n\n')
assert_contains "$out" "MPTCP详细状态"

end_describe

ptyunit_test_summary
