#!/usr/bin/env bash
# Unit tests for lib/rules.sh's proxy_management_menu: the outer `while
# true` menu wrapper around set_proxy_mode/batch_set_proxy_mode (those
# callees themselves are covered by tests/unit/test-rules-proxy.sh). Driven
# with plain `read -p` input via heredocs, always ending in an explicit
# empty-input exit. Reads/writes the real, hardcoded /etc/realm/config.json
# for the global proxy toggle, so this runs against xwpf_lock_realm_config.
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

_setup() {
    xwpf_lock_realm_config
    xwpf_reset_mock_systemd_state
    xwpf_seed_realm_service_file
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
    mkdir -p /etc/realm
    echo '{"endpoints": [], "network": {}}' > /etc/realm/config.json
}

_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f /etc/realm/config.json /etc/systemd/system/realm.service
    xwpf_unlock_realm_config
}

describe "proxy_management_menu" _setup _teardown

test_that "shows the global status and returns when there are no rules"
out=$(proxy_management_menu <<< "")
assert_contains "$out" "全局[关闭]"
assert_not_contains "$out" "请输入要配置的规则ID"

test_that "an empty rule ID input returns without changes"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "")
assert_contains "$out" "当前规则列表"

test_that "rule ID 0 toggles the global proxy setting on, then off, restarting the service each time"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "$(printf '0\n\n0\n\n\n')")
assert_contains "$out" "已开启全局Proxy Protocol"
assert_contains "$out" "已关闭全局Proxy Protocol"
send_proxy=$(jq -r '.network.send_proxy // false' /etc/realm/config.json)
assert_eq "false" "$send_proxy"

test_that "a non-numeric, non-comma rule ID is rejected as invalid"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "$(printf 'abc\n1\n\n\n')")
assert_contains "$out" "无效的规则ID"

test_that "an empty direction choice aborts the current loop iteration without dispatching"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "$(printf '1\n\n\n\n')")
assert_not_contains "$out" "服务重启成功"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"

test_that "a single numeric rule ID with default version and direction=both dispatches set_proxy_mode"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "$(printf '1\n\n3\n\n\n')")
assert_contains "$out" "v2双向"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "v2_both" "$PROXY_MODE"

test_that "version choice 1 (off) dispatches set_proxy_mode with mode off for a single rule"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "$(printf '1\n1\n\n\n')")
assert_contains "$out" "Proxy已关闭"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"

test_that "a comma-separated rule ID list dispatches batch_set_proxy_mode"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
out=$(proxy_management_menu <<< "$(printf '1,2\n3\n3\ny\n\n\n')")
assert_contains "$out" "成功设置 2 个规则的Proxy模式"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "v2_both" "$PROXY_MODE"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_eq "v2_both" "$PROXY_MODE"

test_that "version choice 1 (off) with a comma-separated rule ID list dispatches batch_set_proxy_mode with off"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
out=$(proxy_management_menu <<< "$(printf '1,2\n1\ny\n\n\n')")
assert_contains "$out" "成功设置 2 个规则的Proxy模式"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$PROXY_MODE"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_eq "off" "$PROXY_MODE"

test_that "a non-numeric, non-comma rule ID is rejected as invalid after choosing a version and direction"
_make_relay_rule 1 8001
out=$(proxy_management_menu <<< "$(printf 'abc\n3\n3\n\n\n')")
assert_contains "$out" "无效的规则ID"

end_describe

ptyunit_test_summary
