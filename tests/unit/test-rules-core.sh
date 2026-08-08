#!/usr/bin/env bash
# Unit tests for pure/leaf functions in lib/rules.sh: ID validation, rule
# listing/display formatting, load-balance target-state bookkeeping,
# export metadata, proxy-mode display, weight-input validation, and the
# delete/toggle mutation flows. All read/write through $RULES_DIR, pointed
# at a throwaway temp directory rather than the real /etc/realm/rules.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

_make_relay_rule() {
    local id="$1" port="$2" enabled="${3:-true}"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=relay-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
THROUGH_IP=
ENABLED=${enabled}
SECURITY_LEVEL=standard
BALANCE_MODE=off
TARGET_STATES=
WEIGHTS=
EOF
}

_make_exit_rule() {
    local id="$1" port="$2" enabled="${3:-true}"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=exit-${id}
LISTEN_PORT=${port}
RULE_ROLE=2
FORWARD_TARGET=127.0.0.1:9100
ENABLED=${enabled}
SECURITY_LEVEL=standard
EOF
}

_setup_rules_dir() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
}

_teardown_rules_dir() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

describe "init_rules_dir" _setup_rules_dir _teardown_rules_dir

test_that "creates the directory and an .initialized marker on first call, then is silent on repeat calls"
rmdir "$RULES_DIR"
out=$(init_rules_dir)
assert_true test -d "$RULES_DIR"
assert_true test -f "${RULES_DIR}/.initialized"
assert_contains "$out" "规则目录已初始化"
out2=$(init_rules_dir)
assert_eq "" "$out2"

end_describe

describe "validate_rule_ids" _setup_rules_dir _teardown_rules_dir

test_that "splits comma-separated IDs into valid/invalid buckets"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
result="$(validate_rule_ids "1,2,99,abc")"
assert_eq "2|2|1 2|99 abc" "$result"

test_that "trims whitespace around each ID"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
result="$(validate_rule_ids " 1 , 2 ")"
assert_eq "2|0|1 2|" "$result"

end_describe

describe "get_active_rules_count" _setup_rules_dir _teardown_rules_dir

test_that "is 0 for an empty rules dir"
assert_eq "0" "$(get_active_rules_count)"

test_that "counts readable rule files"
_make_relay_rule 1 8001
_make_exit_rule 2 8002
assert_eq "2" "$(get_active_rules_count)"

end_describe

describe "sync_health_status_ids" _setup_rules_dir _teardown_rules_dir

test_that "is a no-op when no health status file exists"
rm -f /etc/realm/health/health_status.conf
assert_true sync_health_status_ids

test_that "remaps a relay rule's old ID to its new ID by matching target"
_make_relay_rule 1 8001
mkdir -p /etc/realm/health
cat > /etc/realm/health/health_status.conf <<'EOF'
# comment line
5|127.0.0.1:9000|healthy|0|3|2024-01-01|
EOF
sync_health_status_ids
result="$(cat /etc/realm/health/health_status.conf)"
assert_contains "$result" "1|127.0.0.1:9000|healthy|0|3|2024-01-01|"
rm -rf /etc/realm/health

test_that "remaps an exit rule's old ID to its new ID by matching FORWARD_TARGET"
_make_exit_rule 2 8002
mkdir -p /etc/realm/health
cat > /etc/realm/health/health_status.conf <<'EOF'
7|127.0.0.1:9100|healthy|0|3|2024-01-01|
EOF
sync_health_status_ids
result="$(cat /etc/realm/health/health_status.conf)"
assert_contains "$result" "2|127.0.0.1:9100|healthy|0|3|2024-01-01|"
rm -rf /etc/realm/health

end_describe

describe "reorder_rule_ids" _setup_rules_dir _teardown_rules_dir

test_that "returns immediately when RULES_DIR does not exist"
_real_rules_dir="$RULES_DIR"
RULES_DIR="/tmp/xwpf-no-such-rules-dir-$$"
assert_true reorder_rule_ids
RULES_DIR="$_real_rules_dir"

test_that "treats a directory entry matching rule-*.conf as unreadable, leaving an empty sorted list"
mkdir "${RULES_DIR}/rule-1.conf"
assert_true reorder_rule_ids
rmdir "${RULES_DIR}/rule-1.conf"

end_describe

describe "get_balance_info_display"

test_that "shows the roundrobin label"
assert_contains "$(get_balance_info_display "" "roundrobin")" "轮询"

test_that "shows the iphash label"
assert_contains "$(get_balance_info_display "" "iphash")" "IP哈希"

test_that "falls back to off for any other mode"
assert_contains "$(get_balance_info_display "" "off")" "off"

end_describe

describe "is_target_enabled"

test_that "returns false when the target's state key is explicitly false"
assert_eq "false" "$(is_target_enabled 0 "target_0:false,target_1:true")"

test_that "returns true when the target's state key is true"
assert_eq "true" "$(is_target_enabled 1 "target_0:false,target_1:true")"

test_that "defaults to true when the state key is absent"
assert_eq "true" "$(is_target_enabled 2 "target_0:false")"

end_describe

describe "read_and_check_relay_rule" _setup_rules_dir _teardown_rules_dir

test_that "succeeds for a relay (role 1) rule"
_make_relay_rule 1 8001
assert_true read_and_check_relay_rule "${RULES_DIR}/rule-1.conf"

test_that "fails for an exit (role 2) rule"
_make_exit_rule 2 8002
assert_false read_and_check_relay_rule "${RULES_DIR}/rule-2.conf"

end_describe

describe "list_rules_with_info" _setup_rules_dir _teardown_rules_dir

test_that "reports no rules when the dir is empty"
out=$(list_rules_with_info "management")
assert_contains "$out" "暂无转发规则"

test_that "management mode groups relay rules under 中转服务器 and exit rules under 服务端服务器"
_make_relay_rule 1 8001
_make_exit_rule 2 8002
out=$(list_rules_with_info "management")
assert_contains "$out" "中转服务器"
assert_contains "$out" "服务端服务器"
assert_contains "$out" "relay-1"
assert_contains "$out" "exit-2"

test_that "mptcp mode prints the plain rule list header"
_make_relay_rule 1 8001
out=$(list_rules_with_info "mptcp")
assert_contains "$out" "当前规则列表"

test_that "proxy mode prints the plain rule list header"
_make_relay_rule 1 8001
out=$(list_rules_with_info "proxy")
assert_contains "$out" "当前规则列表"

end_describe

describe "display_single_rule_info" _setup_rules_dir _teardown_rules_dir

test_that "fails for a missing rule file"
assert_false display_single_rule_info "${RULES_DIR}/rule-999.conf" "management"

test_that "management mode shows an exit rule's forward target"
_make_exit_rule 2 8002
out=$(display_single_rule_info "${RULES_DIR}/rule-2.conf" "management")
assert_contains "$out" "8002"
assert_contains "$out" "启用"

test_that "management mode shows a disabled relay rule as 禁用"
_make_relay_rule 3 8003 false
out=$(display_single_rule_info "${RULES_DIR}/rule-3.conf" "management")
assert_contains "$out" "禁用"

test_that "mptcp mode shows the MPTCP display label"
_make_relay_rule 1 8001
out=$(display_single_rule_info "${RULES_DIR}/rule-1.conf" "mptcp")
assert_contains "$out" "MPTCP"

test_that "proxy mode shows the Proxy display label"
_make_relay_rule 1 8001
out=$(display_single_rule_info "${RULES_DIR}/rule-1.conf" "proxy")
assert_contains "$out" "Proxy"

end_describe

describe "list_all_rules" _setup_rules_dir _teardown_rules_dir

test_that "reports no rules when the dir is empty"
out=$(list_all_rules)
assert_contains "$out" "暂无转发规则"

test_that "lists an existing rule's details"
_make_relay_rule 1 8001
out=$(list_all_rules)
assert_contains "$out" "relay-1"

end_describe

describe "remove_target_from_states"

test_that "drops the matching target and its paired weight"
result="$(remove_target_from_states "1.1.1.1:80,2.2.2.2:80,3.3.3.3:80" "2.2.2.2:80" "1,2,3")"
assert_eq "1.1.1.1:80,3.3.3.3:80|1,3" "$result"

test_that "returns empty when the only target is removed"
result="$(remove_target_from_states "1.1.1.1:80" "1.1.1.1:80" "1")"
assert_eq "|" "$result"

end_describe

describe "sync_target_states_for_port / disable_balance_for_port" _setup_rules_dir _teardown_rules_dir

test_that "sync_target_states_for_port updates TARGET_STATES/WEIGHTS for matching-port balance rules, then disable_balance_for_port clears them"
cat > "${RULES_DIR}/rule-1.conf" <<'EOF'
RULE_ID=1
RULE_NAME=lb-1
LISTEN_PORT=8001
RULE_ROLE=1
REMOTE_HOST=1.1.1.1
REMOTE_PORT=80
ENABLED=true
BALANCE_MODE=roundrobin
TARGET_STATES=target_0:true,target_1:true
WEIGHTS=1,1
EOF
sync_target_states_for_port "8001" "target_0:true" "5"
count=$?
assert_eq "1" "$count"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "target_0:true" "$TARGET_STATES"
assert_eq "5" "$WEIGHTS"

disable_balance_for_port "8001"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$BALANCE_MODE"
assert_eq "" "$TARGET_STATES"
assert_eq "" "$WEIGHTS"

end_describe

describe "generate_export_metadata" _setup_rules_dir _teardown_rules_dir

test_that "writes rule count and package version fields"
MANAGER_CONF="/tmp/xwpf-no-such-manager.conf"
_metadata="$(mktemp /tmp/xwpf-metadata.XXXXXX)"
generate_export_metadata "$_metadata" "3"
content="$(cat "$_metadata")"
assert_contains "$content" "RULES_COUNT=3"
assert_contains "$content" "PACKAGE_VERSION=1.0"
assert_contains "$content" "HAS_MANAGER_CONF=false"
rm -f "$_metadata"

end_describe

describe "get_proxy_mode_display / get_proxy_mode_color"

test_that "displays each known proxy mode"
assert_eq "关闭" "$(get_proxy_mode_display "off")"
assert_eq "v1发送" "$(get_proxy_mode_display "v1_send")"
assert_eq "v1接收" "$(get_proxy_mode_display "v1_accept")"
assert_eq "v1双向" "$(get_proxy_mode_display "v1_both")"
assert_eq "v2发送" "$(get_proxy_mode_display "v2_send")"
assert_eq "v2接收" "$(get_proxy_mode_display "v2_accept")"
assert_eq "v2双向" "$(get_proxy_mode_display "v2_both")"

test_that "falls back to 关闭 for an unknown mode"
assert_eq "关闭" "$(get_proxy_mode_display "bogus")"

test_that "colors each mode family distinctly"
assert_eq "$WHITE" "$(get_proxy_mode_color "off")"
assert_eq "$BLUE" "$(get_proxy_mode_color "v1_send")"
assert_eq "$YELLOW" "$(get_proxy_mode_color "v1_accept")"
assert_eq "$GREEN" "$(get_proxy_mode_color "v1_both")"
assert_eq "$WHITE" "$(get_proxy_mode_color "bogus")"

end_describe

describe "init_proxy_fields" _setup_rules_dir _teardown_rules_dir

test_that "appends PROXY_MODE=off to rule files missing the field"
_make_relay_rule 1 8001
sed -i '/^PROXY_MODE=/d' "${RULES_DIR}/rule-1.conf"
init_proxy_fields
assert_contains "$(cat "${RULES_DIR}/rule-1.conf")" 'PROXY_MODE="off"'

end_describe

describe "validate_weight_input"

test_that "accepts a well-formed weight list matching the expected count"
assert_true validate_weight_input "2,1,3" 3

test_that "rejects malformed input"
out=$(validate_weight_input "2,a,3" 3)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "权重格式错误"

test_that "rejects a count mismatch"
out=$(validate_weight_input "2,1" 3)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "权重数量不匹配"

test_that "rejects an out-of-range weight"
out=$(validate_weight_input "2,11,3" 3)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "超出范围"

end_describe

describe "delete_rule" _setup_rules_dir _teardown_rules_dir

test_that "fails for a nonexistent rule ID"
out=$(delete_rule 999 true)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "不存在"

test_that "cancels when the interactive confirmation is not y"
_make_relay_rule 1 8001
out=$(delete_rule 1 <<< "n")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "删除已取消"
assert_true test -f "${RULES_DIR}/rule-1.conf"

test_that "skip_confirm=true deletes without prompting"
_make_relay_rule 1 8001
assert_true delete_rule 1 true
assert_false test -f "${RULES_DIR}/rule-1.conf"

test_that "deleting a balance-mode rule with 2+ remaining targets syncs the others instead of disabling"
cat > "${RULES_DIR}/rule-2.conf" <<'EOF'
RULE_ID=2
RULE_NAME=lb-2
LISTEN_PORT=9001
RULE_ROLE=1
REMOTE_HOST=1.1.1.1
REMOTE_PORT=80
ENABLED=true
BALANCE_MODE=roundrobin
TARGET_STATES=target_0:true,target_1:true,target_2:true
WEIGHTS=1,1,1
EOF
cat > "${RULES_DIR}/rule-3.conf" <<'EOF'
RULE_ID=3
RULE_NAME=lb-3
LISTEN_PORT=9001
RULE_ROLE=1
REMOTE_HOST=1.1.1.1
REMOTE_PORT=80
ENABLED=true
BALANCE_MODE=roundrobin
TARGET_STATES=target_0:true,target_1:true,target_2:true
WEIGHTS=1,1,1
EOF
out=$(delete_rule 2 true)
assert_contains "$out" "已同步更新"
read_rule_file "${RULES_DIR}/rule-3.conf"
assert_eq "roundrobin" "$BALANCE_MODE"

test_that "interactively deleting a balance-mode rule with only 1 target left warns about the group and auto-disables balance mode"
cat > "${RULES_DIR}/rule-4.conf" <<'EOF'
RULE_ID=4
RULE_NAME=lb-4
LISTEN_PORT=9002
RULE_ROLE=1
REMOTE_HOST=1.1.1.1
REMOTE_PORT=80
ENABLED=true
BALANCE_MODE=roundrobin
TARGET_STATES=target_0:true
WEIGHTS=1
EOF
out=$(delete_rule 4 <<< "y")
assert_contains "$out" "此规则属于负载均衡组"
assert_contains "$out" "只剩1个目标，自动关闭负载均衡模式"
assert_false test -f "${RULES_DIR}/rule-4.conf"

end_describe

describe "batch_delete_rules" _setup_rules_dir _teardown_rules_dir

test_that "fails when given an empty rule ID list"
out=$(batch_delete_rules "")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "没有找到有效的规则ID"

test_that "fails immediately when any ID is invalid"
_make_relay_rule 1 8001
out=$(batch_delete_rules "1,99")
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "无效或不存在"
assert_true test -f "${RULES_DIR}/rule-1.conf"

test_that "cancels on a non-y confirmation"
_make_relay_rule 1 8001
out=$(batch_delete_rules "1" <<< "n")
assert_contains "$out" "批量删除已取消"
assert_true test -f "${RULES_DIR}/rule-1.conf"

test_that "deletes all valid IDs on y confirmation"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
out=$(batch_delete_rules "1,2" <<< "y")
assert_contains "$out" "共删除 2 个规则"
assert_false test -f "${RULES_DIR}/rule-1.conf"
assert_false test -f "${RULES_DIR}/rule-2.conf"

end_describe

describe "toggle_rule" _setup_rules_dir _teardown_rules_dir

test_that "fails for a nonexistent rule ID"
out=$(toggle_rule 999)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "不存在"

test_that "disables an enabled rule"
_make_relay_rule 1 8001 true
out=$(toggle_rule 1)
assert_contains "$out" "规则已禁用"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "false" "$ENABLED"

test_that "enables a disabled rule"
_make_relay_rule 1 8001 false
out=$(toggle_rule 1)
assert_contains "$out" "规则已启用"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "true" "$ENABLED"

end_describe

ptyunit_test_summary
