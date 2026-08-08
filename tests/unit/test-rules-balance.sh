#!/usr/bin/env bash
# Unit tests for the port-group load-balance menus in lib/rules.sh:
# load_balance_management_menu, switch_balance_mode, and
# weight_management_menu's entry/selection logic. All three are `while
# true` menu loops driven by plain `read -p`, so inputs are fed as
# newline-separated heredocs exactly like lib/ui.sh's menu tests, always
# ending in an explicit exit choice (never relying on stdin exhaustion).
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
    local id="$1" port="$2" host="$3" balance_mode="${4:-off}" weights="${5:-}"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=relay-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=${host}
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
BALANCE_MODE=${balance_mode}
TARGET_STATES=
WEIGHTS=${weights}
PROXY_MODE=off
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

describe "load_balance_management_menu" _setup_rules_dir _teardown_rules_dir

test_that "shows a 'no rules' message and returns when RULES_DIR is empty"
out=$(load_balance_management_menu <<< "")
assert_contains "$out" "暂无转发规则"

test_that "shows a 'no balance groups' message when no port has 2+ targets"
_make_relay_rule 1 8001 "10.0.0.1"
out=$(load_balance_management_menu <<< "0")
assert_contains "$out" "暂无符合条件的负载均衡组"

test_that "lists a port group with 2+ targets and its weight breakdown"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
out=$(load_balance_management_menu <<< "0")
assert_contains "$out" "端口 8001"
assert_contains "$out" "2个服务器"
assert_contains "$out" "10.0.0.1:9000"
assert_contains "$out" "10.0.0.2:9000"

test_that "an invalid menu choice is rejected and re-prompts"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
out=$(load_balance_management_menu <<< "$(printf '9\n\n0\n')")
assert_contains "$out" "无效选择，请输入 0-3"

test_that "choice 1 dispatches into switch_balance_mode and returns to the outer loop"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
out=$(load_balance_management_menu <<< "$(printf '1\n\n0\n')")
assert_contains "$out" "切换负载均衡模式"

test_that "choice 2 dispatches into weight_management_menu and returns to the outer loop"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
out=$(load_balance_management_menu <<< "$(printf '2\n\n0\n')")
assert_contains "$out" "权重配置管理"

end_describe

describe "switch_balance_mode" _setup_rules_dir _teardown_rules_dir

test_that "reports no eligible rule groups when no port has 2+ targets"
_make_relay_rule 1 8001 "10.0.0.1"
out=$(switch_balance_mode <<< "")
assert_contains "$out" "暂无多目标服务器的规则组"

test_that "an empty rule-number choice returns without changes"
_make_relay_rule 1 8001 "10.0.0.1"
_make_relay_rule 2 8001 "10.0.0.2"
out=$(switch_balance_mode <<< "")
assert_contains "$out" "请选择要切换负载均衡模式的规则组"

test_that "an out-of-range rule number is rejected and re-prompted"
_make_relay_rule 1 8001 "10.0.0.1"
_make_relay_rule 2 8001 "10.0.0.2"
out=$(switch_balance_mode <<< "$(printf '99\n\n')")
assert_contains "$out" "无效的规则编号"

test_that "an invalid balance-mode choice is rejected and re-loops"
_make_relay_rule 1 8001 "10.0.0.1"
_make_relay_rule 2 8001 "10.0.0.2"
out=$(switch_balance_mode <<< "$(printf '1\n9\n\n')")
assert_contains "$out" "无效选择"

test_that "selecting roundrobin updates every rule in the port group and restarts the service"
_make_relay_rule 1 8001 "10.0.0.1"
_make_relay_rule 2 8001 "10.0.0.2"
xwpf_seed_realm_service_file
out=$(switch_balance_mode <<< "$(printf '1\n2\n')")
assert_contains "$out" "已将端口 8001 的 2 个规则的负载均衡模式更新为: 轮询"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "roundrobin" "$BALANCE_MODE"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_eq "roundrobin" "$BALANCE_MODE"

test_that "selecting off (mode 1) disables balance mode for the whole group"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
xwpf_seed_realm_service_file
out=$(switch_balance_mode <<< "$(printf '1\n1\n')")
assert_contains "$out" "更新为: 关闭"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$BALANCE_MODE"

end_describe

describe "weight_management_menu" _setup_rules_dir _teardown_rules_dir

test_that "shows a 'no groups' message when no port has balance mode enabled"
_make_relay_rule 1 8001 "10.0.0.1"
_make_relay_rule 2 8001 "10.0.0.2"
out=$(weight_management_menu <<< "")
assert_contains "$out" "暂无需要权重配置的规则组"

test_that "lists a balance-enabled port group and returns on empty selection"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
out=$(weight_management_menu <<< "")
assert_contains "$out" "请选择要配置权重的规则组"
assert_contains "$out" "[roundrobin]"

test_that "an out-of-range selection is rejected and re-prompted"
_make_relay_rule 1 8001 "10.0.0.1" "roundrobin" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "roundrobin" "5,5"
out=$(weight_management_menu <<< "$(printf '99\n\n')")
assert_contains "$out" "无效"

end_describe

ptyunit_test_summary
