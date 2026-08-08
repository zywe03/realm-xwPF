#!/usr/bin/env bash
# Unit tests for the per-port weight configuration flow in lib/rules.sh:
# configure_port_group_weights -> preview_port_group_weight_config ->
# apply_port_group_weight_config. Driven with plain `read -p` input via
# heredocs; apply_port_group_weight_config restarts the real (mocked)
# systemd service, so these run against xwpf_reset_mock_systemd_state.
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
    local id="$1" port="$2" host="$3" weights="${4:-}"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=relay-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=${host}
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
BALANCE_MODE=roundrobin
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

describe "configure_port_group_weights" _setup_rules_dir _teardown_rules_dir

test_that "an empty weight input keeps the original config and returns"
_make_relay_rule 1 8001 "10.0.0.1" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "5,5"
out=$(configure_port_group_weights "8001" "relay-1" "10.0.0.1:9000,10.0.0.2:9000" "5,5" <<< "")
assert_contains "$out" "未输入权重，保持原配置"

test_that "a malformed weight input is rejected by validate_weight_input and returns"
_make_relay_rule 1 8001 "10.0.0.1" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "5,5"
out=$(configure_port_group_weights "8001" "relay-1" "10.0.0.1:9000,10.0.0.2:9000" "5,5" <<< "abc")
assert_contains "$out" "权重格式错误"

test_that "a valid input previews the change and cancelling on n leaves the rule files untouched"
_make_relay_rule 1 8001 "10.0.0.1" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "5,5"
out=$(configure_port_group_weights "8001" "relay-1" "10.0.0.1:9000,10.0.0.2:9000" "5,5" <<< "$(printf '2,8\nn\n')")
assert_contains "$out" "配置预览"
assert_contains "$out" "已取消配置更改"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "5,5" "$WEIGHTS"

test_that "a valid input previews the change and confirming on y applies and restarts the service"
_make_relay_rule 1 8001 "10.0.0.1" "5,5"
_make_relay_rule 2 8001 "10.0.0.2" "5,5"
xwpf_seed_realm_service_file
out=$(configure_port_group_weights "8001" "relay-1" "10.0.0.1:9000,10.0.0.2:9000" "5,5" <<< "$(printf '2,8\ny\n')")
assert_contains "$out" "已更新 2 个规则文件的权重配置"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "2,8" "$WEIGHTS"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_eq "8" "$WEIGHTS"

end_describe

describe "apply_port_group_weight_config" _setup_rules_dir _teardown_rules_dir

test_that "reports failure when the service fails to restart, but still updates the files"
_make_relay_rule 1 8001 "10.0.0.1" "5,5"
xwpf_seed_realm_service_file
out=$(XWPF_MOCK_SYSTEMCTL_RESTART_FAIL=1 apply_port_group_weight_config "8001" "9")
assert_contains "$out" "已更新 1 个规则文件的权重配置"
assert_contains "$out" "服务重启失败"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "9" "$WEIGHTS"

test_that "reports 'no matching rules' when no rule file matches the port"
out=$(apply_port_group_weight_config "9999" "5")
assert_contains "$out" "未找到相关规则文件"

end_describe

ptyunit_test_summary
