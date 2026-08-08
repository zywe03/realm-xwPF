#!/usr/bin/env bash
# Unit tests for the Proxy Protocol mode-setting flows in lib/rules.sh:
# update_proxy_mode_in_file, set_proxy_mode, batch_set_proxy_mode, and
# restart_service_for_proxy. The non-batch paths call service_restart
# (lib/realm.sh), so these run against the mocked systemd state and the
# real /etc/realm/config.json path (serialized via xwpf_lock_realm_config).
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
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
BALANCE_MODE=off
TARGET_STATES=
WEIGHTS=
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

describe "update_proxy_mode_in_file"

test_that "appends PROXY_MODE when the field is missing"
tmp_rule="$(mktemp /tmp/xwpf-proxyfield.XXXXXX)"
printf 'RULE_ID=1\n' > "$tmp_rule"
update_proxy_mode_in_file "$tmp_rule" "v2_both"
assert_contains "$(cat "$tmp_rule")" 'PROXY_MODE="v2_both"'
rm -f "$tmp_rule"

test_that "replaces an existing PROXY_MODE field"
tmp_rule="$(mktemp /tmp/xwpf-proxyfield.XXXXXX)"
printf 'RULE_ID=1\nPROXY_MODE="off"\n' > "$tmp_rule"
update_proxy_mode_in_file "$tmp_rule" "v1_send"
out="$(cat "$tmp_rule")"
assert_contains "$out" 'PROXY_MODE="v1_send"'
assert_eq "1" "$(grep -c '^PROXY_MODE=' "$tmp_rule")"
rm -f "$tmp_rule"

end_describe

describe "set_proxy_mode" _setup_rules_dir _teardown_rules_dir

test_that "fails for a nonexistent rule ID"
out=$(set_proxy_mode 999 "3" "3")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "不存在"

test_that "an invalid version choice fails without changing the rule"
_make_relay_rule 1 8001
out=$(set_proxy_mode 1 "9" "3")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "无效的版本选择"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"

test_that "an invalid direction choice fails without changing the rule"
_make_relay_rule 1 8001
out=$(set_proxy_mode 1 "3" "9")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "无效的方向选择"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"

test_that "version_choice=off closes proxy and restarts the service"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(set_proxy_mode 1 "off" "")
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "Proxy已关闭"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"

test_that "version v1 + direction send sets PROXY_MODE=v1_send and restarts the service"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(set_proxy_mode 1 "2" "1")
assert_contains "$out" "v1发送"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "v1_send" "$PROXY_MODE"

test_that "version v2 + direction both sets PROXY_MODE=v2_both"
_make_relay_rule 1 8001
xwpf_seed_realm_service_file
out=$(set_proxy_mode 1 "3" "3")
assert_contains "$out" "v2双向"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "v2_both" "$PROXY_MODE"

test_that "batch mode suppresses per-rule output and does not restart the service"
_make_relay_rule 1 8001
out=$(set_proxy_mode 1 "3" "2" "batch")
rc=$?
assert_eq "0" "$rc"
assert_not_contains "$out" "服务重启成功"
assert_not_contains "$out" "正在为规则"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "v2_accept" "$PROXY_MODE"

end_describe

describe "batch_set_proxy_mode" _setup_rules_dir _teardown_rules_dir

test_that "fails immediately when any ID is invalid"
_make_relay_rule 1 8001
out=$(batch_set_proxy_mode "1,99" "3" "3")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "无效或不存在"

test_that "fails when no valid IDs are given at all"
out=$(batch_set_proxy_mode "" "3" "3")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "没有找到有效的规则ID"

test_that "cancels on a non-y confirmation"
_make_relay_rule 1 8001
out=$(batch_set_proxy_mode "1" "3" "3" <<< "n")
assert_contains "$out" "操作已取消"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"

test_that "sets proxy mode for all valid IDs on y confirmation and restarts the service once"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
xwpf_seed_realm_service_file
out=$(batch_set_proxy_mode "1,2" "3" "3" <<< "y")
assert_contains "$out" "成功设置 2 个规则的Proxy模式"
assert_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "v2_both" "$PROXY_MODE"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_eq "v2_both" "$PROXY_MODE"

end_describe

describe "restart_service_for_proxy" _setup_rules_dir _teardown_rules_dir

test_that "reports success when the service restarts cleanly"
xwpf_seed_realm_service_file
out=$(restart_service_for_proxy)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "服务重启成功"

test_that "reports failure when the service fails to restart"
xwpf_seed_realm_service_file
out=$(XWPF_MOCK_SYSTEMCTL_RESTART_FAIL=1 restart_service_for_proxy)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "服务重启失败"

end_describe

ptyunit_test_summary
