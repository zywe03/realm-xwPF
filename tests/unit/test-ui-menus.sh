#!/usr/bin/env bash
# Unit tests for lib/ui.sh's menu-driving functions: rules_management_menu
# and show_brief_status. Both are called directly (not via a PTY) with all
# `read -p` input pre-fed on stdin, the same technique test-realm-install.sh
# uses for install_realm. RULES_DIR is overridden to a private temp
# directory per describe (a plain global var, not a hardcoded path), so
# these tests don't race the real /etc/realm/rules other files use.
# Restart-on-success branches call the real service_restart(), which writes
# real /etc/realm/config.json — those specific tests hold xwpf_lock_realm_config.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

INIT_SYSTEM="systemd"

_seed_relay_rule() {
    # RULE_ROLE=1, enabled, ws security, with a note — hits the relay-rule
    # display branch including the RULE_NOTE and security-display lines.
    cat > "${RULES_DIR}/rule-${1}.conf" <<EOF
RULE_ID=${1}
RULE_NAME=relay-${1}
LISTEN_PORT=800${1}
RULE_ROLE=1
REMOTE_HOST=203.0.113.5
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=ws
WS_PATH=/ws
WS_HOST=example.com
RULE_NOTE=note-${1}
EOF
}

_seed_exit_rule() {
    # RULE_ROLE=2, enabled, tls_self security — hits the exit-server
    # (server-role) display branch.
    cat > "${RULES_DIR}/rule-${1}.conf" <<EOF
RULE_ID=${1}
RULE_NAME=exit-${1}
LISTEN_PORT=800${1}
RULE_ROLE=2
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
FORWARD_TARGET=203.0.113.9:9200
ENABLED=true
SECURITY_LEVEL=tls_self
EOF
}

_seed_disabled_relay_rule() {
    cat > "${RULES_DIR}/rule-${1}.conf" <<EOF
RULE_ID=${1}
RULE_NAME=disabled-relay-${1}
LISTEN_PORT=800${1}
RULE_ROLE=1
REMOTE_HOST=203.0.113.5
REMOTE_PORT=9000
ENABLED=false
SECURITY_LEVEL=standard
EOF
}

_seed_disabled_exit_rule() {
    cat > "${RULES_DIR}/rule-${1}.conf" <<EOF
RULE_ID=${1}
RULE_NAME=disabled-exit-${1}
LISTEN_PORT=800${1}
RULE_ROLE=2
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
FORWARD_TARGET=203.0.113.9:9200
ENABLED=false
SECURITY_LEVEL=standard
EOF
}

_rules_setup() {
    RULES_DIR="$(mktemp -d /tmp/xwpf-ui-rules.XXXXXX)"
}
_rules_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

describe "rules_management_menu: display" _rules_setup _rules_teardown xwpf_reset_mock_systemd_state

test_that "shows the empty-config placeholder when no rules exist"
out=$(rules_management_menu <<< "0")
assert_contains "$out" "暂无配置"
assert_contains "$out" "已停止"

test_that "shows the running status line when the mock service is active"
touch "$XWPF_MOCK_STATE_DIR/realm.active"
out=$(rules_management_menu <<< "0")
assert_contains "$out" "运行中"

test_that "shows relay, exit, and disabled rule sections with notes and security displays"
_seed_relay_rule 1
_seed_exit_rule 2
_seed_disabled_relay_rule 3
_seed_disabled_exit_rule 4
out=$(rules_management_menu <<< "0")
assert_contains "$out" "多规则模式"
assert_contains "$out" "中转服务器:"
assert_contains "$out" "relay-1"
assert_contains "$out" "note-1"
assert_contains "$out" "服务端服务器 (双端Realm架构):"
assert_contains "$out" "exit-2"
assert_contains "$out" "禁用的规则:"
assert_contains "$out" "disabled-relay-3"
assert_contains "$out" "disabled-exit-4"

test_that "rejects an out-of-range choice, then exits on 0"
# The default branch has its own unconditional trailing
# "按回车键继续..." prompt, so an extra blank line is needed before the
# final "0" to exit the outer loop.
out=$(rules_management_menu <<< "$(printf '99\n\n0\n')")
assert_contains "$out" "无效选择，请输入 0-8"

end_describe

describe "rules_management_menu: config file submenu (choice 1)" _rules_setup _rules_teardown

test_that "returns from the submenu on 0, then exits the outer menu on 0"
out=$(rules_management_menu <<< "$(printf '1\n0\n0\n')")
assert_contains "$out" "配置文件管理"

test_that "rejects an invalid submenu choice before returning"
# The submenu's own invalid-choice branch has an unconditional trailing
# "按回车键继续..." prompt before looping back for the next sub_choice.
out=$(rules_management_menu <<< "$(printf '1\n9\n\n0\n0\n')")
assert_contains "$out" "无效选择，请重新输入"

test_that "dispatches to export_config_with_view, which returns to the submenu on choice 0"
out=$(rules_management_menu <<< "$(printf '1\n1\n0\n0\n0\n')")
assert_contains "$out" "查看配置文件"

test_that "dispatches to import_config_package, which cancels on an empty path"
out=$(rules_management_menu <<< "$(printf '1\n2\n\n\n0\n0\n')")
assert_contains "$out" "导入配置包"
assert_contains "$out" "已取消操作"

test_that "dispatches to import_realm_config, which downloads and runs the OCR script, cancelling on empty input"
rm -f /etc/realm/xw_realm_OCR.sh
out=$(rules_management_menu <<< "$(printf '1\n3\n\n\n0\n0\n')")
assert_contains "$out" "识别realm配置文件并导入"
assert_contains "$out" "已取消操作"
rm -f /etc/realm/xw_realm_OCR.sh

end_describe

describe "rules_management_menu: add-rule dispatch (choice 2)" _rules_setup _rules_teardown

test_that "does not restart the service when interactive_add_rule fails"
# Choice 2's branch has an unconditional trailing "按回车键继续..."
# prompt regardless of interactive_add_rule's result.
interactive_add_rule() { return 1; }
out=$(rules_management_menu <<< "$(printf '2\n\n0\n')")
assert_not_contains "$out" "正在重启服务以应用新配置"
source "$XWPF_REPO_ROOT/lib/rules.sh"

end_describe

_add_rule_success_setup() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    xwpf_lock_realm_config
    RULES_DIR="$(mktemp -d /tmp/xwpf-ui-rules.XXXXXX)"
    xwpf_reset_mock_systemd_state
}
_add_rule_success_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f /etc/realm/config.json
    xwpf_unlock_realm_config
}

describe "rules_management_menu: add-rule dispatch, success path" _add_rule_success_setup _add_rule_success_teardown

test_that "restarts the service when interactive_add_rule succeeds"
interactive_add_rule() { return 0; }
out=$(rules_management_menu <<< "$(printf '2\n\n0\n')")
assert_contains "$out" "正在重启服务以应用新配置"
source "$XWPF_REPO_ROOT/lib/rules.sh"

end_describe

describe "rules_management_menu: edit dispatch (choice 3)" _rules_setup _rules_teardown

test_that "returns immediately from edit_rule_interactive when there are no rules"
# edit_rule_interactive's own empty-rules path reads one "按回车键返回..."
# prompt itself; choice 3's case block has no additional outer read.
out=$(rules_management_menu <<< "$(printf '3\n\n0\n')")
assert_contains "$out" "编辑配置"
assert_contains "$out" "暂无转发规则"

end_describe

describe "rules_management_menu: delete dispatch (choice 4)" _rules_setup _rules_teardown

# Choice 4's block always ends with an unconditional trailing
# "按回车键继续..." prompt, on top of whatever reads happen inside — every
# sequence below needs one extra blank line before the final "0".

test_that "skips straight past deletion when there are no rules to list"
out=$(rules_management_menu <<< "$(printf '4\n\n0\n')")
assert_contains "$out" "删除配置"
assert_not_contains "$out" "请输入要删除的规则ID"

test_that "reports a missing rule ID when the input is empty"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '4\n\n\n0\n')")
assert_contains "$out" "请输入规则ID"

test_that "reports an invalid rule ID for non-numeric single input"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '4\nabc\n\n0\n')")
assert_contains "$out" "无效的规则ID"

test_that "reports invalid IDs for a comma-separated batch with unknown IDs"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '4\n8,9\n\n0\n')")
assert_contains "$out" "以下规则ID无效或不存在"

test_that "does not restart the service when delete_rule fails against an unknown ID"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '4\n999\n\n0\n')")
assert_contains "$out" "规则 999 不存在"
assert_not_contains "$out" "正在重启服务以应用配置更改"

end_describe

_delete_success_setup() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    xwpf_lock_realm_config
    RULES_DIR="$(mktemp -d /tmp/xwpf-ui-rules.XXXXXX)"
    xwpf_reset_mock_systemd_state
}
_delete_success_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f /etc/realm/config.json
    xwpf_unlock_realm_config
}

describe "rules_management_menu: delete dispatch, success path" _delete_success_setup _delete_success_teardown

test_that "restarts the service after successfully deleting a rule"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '4\n1\ny\n\n0\n')")
assert_contains "$out" "规则 1 已删除"
assert_contains "$out" "正在重启服务以应用配置更改"

end_describe

describe "rules_management_menu: toggle dispatch (choice 5)" _rules_setup _rules_teardown

# Choice 5's block, like choice 4's, always ends with an unconditional
# trailing "按回车键继续..." prompt.

test_that "skips straight past toggling when there are no rules to list"
out=$(rules_management_menu <<< "$(printf '5\n\n0\n')")
assert_contains "$out" "启用/禁用中转规则"
assert_not_contains "$out" "请输入要切换状态的规则ID"

test_that "reports an invalid rule ID for non-numeric input"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '5\nabc\n\n0\n')")
assert_contains "$out" "无效的规则ID"

test_that "does not restart the service when toggle_rule fails against an unknown ID"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '5\n999\n\n0\n')")
assert_contains "$out" "规则 999 不存在"
assert_not_contains "$out" "正在重启服务以应用状态更改"

end_describe

describe "rules_management_menu: toggle dispatch, success path" _delete_success_setup _delete_success_teardown

test_that "restarts the service after successfully toggling a rule"
_seed_relay_rule 1
out=$(rules_management_menu <<< "$(printf '5\n1\n\n0\n')")
assert_contains "$out" "规则已禁用"
assert_contains "$out" "正在重启服务以应用状态更改"

end_describe

describe "rules_management_menu: load-balance/mptcp/proxy dispatch (choices 6-8)" _rules_setup _rules_teardown

test_that "dispatches to load_balance_management_menu, which returns immediately with no rules"
out=$(rules_management_menu <<< "$(printf '6\n\n0\n')")
assert_contains "$out" "负载均衡管理"
assert_contains "$out" "暂无转发规则"

test_that "dispatches to mptcp_management_menu, which reports lack of kernel support"
out=$(rules_management_menu <<< "$(printf '7\n\n\n0\n')")
assert_contains "$out" "MPTCP 管理"
assert_contains "$out" "系统不支持MPTCP或未启用"

test_that "dispatches to proxy_management_menu, which returns immediately with no rules"
out=$(rules_management_menu <<< "$(printf '8\n\n0\n')")
assert_contains "$out" "Proxy Protocol 管理"

end_describe

describe "show_brief_status" _rules_setup _rules_teardown

test_that "reports not-installed when the realm binary is missing"
rm -f /usr/local/bin/realm
out=$(show_brief_status 2>&1)
assert_contains "$out" "未安装"

end_describe

_show_status_installed_setup() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /usr/local/bin: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    xwpf_lock_realm_config
    RULES_DIR="$(mktemp -d /tmp/xwpf-ui-rules.XXXXXX)"
    xwpf_reset_mock_systemd_state
    xwpf_seed_fake_realm_binary
}
_show_status_installed_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f /usr/local/bin/realm /etc/realm/config.json
    xwpf_unlock_realm_config
}

describe "show_brief_status: installed" _show_status_installed_setup _show_status_installed_teardown

test_that "reports missing config when realm is installed but config.json is absent"
rm -f /etc/realm/config.json
out=$(show_brief_status 2>&1)
assert_contains "$out" "配置缺失"

test_that "shows relay/exit/disabled rule sections once config.json exists"
mkdir -p /etc/realm
echo '{}' > /etc/realm/config.json
_seed_relay_rule 1
_seed_exit_rule 2
_seed_disabled_relay_rule 3
_seed_disabled_exit_rule 4
touch "$XWPF_MOCK_STATE_DIR/realm.active"
out=$(show_brief_status 2>&1)
assert_contains "$out" "运行中"
assert_contains "$out" "中转服务器:"
assert_contains "$out" "relay-1"
assert_contains "$out" "服务端服务器 (双端Realm架构):"
assert_contains "$out" "exit-2"
assert_contains "$out" "禁用的规则:"
assert_contains "$out" "disabled-relay-3"
assert_contains "$out" "disabled-exit-4"

test_that "shows the no-rules placeholder when config.json exists but no rules are seeded"
mkdir -p /etc/realm
echo '{}' > /etc/realm/config.json
out=$(show_brief_status 2>&1)
assert_contains "$out" "暂无"

end_describe

describe "download helper functions" _rules_setup _rules_teardown

_realm_etc_cleanup() {
    rm -f /etc/realm/xw_realm_OCR.sh /etc/realm/xwFailover.sh /etc/realm/speedtest.sh
}

test_that "download_realm_ocr_script fetches the real companion script from the repo checkout"
_realm_etc_cleanup
out=$(download_realm_ocr_script 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "下载成功"
assert_true test -x /etc/realm/xw_realm_OCR.sh
_realm_etc_cleanup

test_that "download_realm_ocr_script reports failure when curl can't reach the source"
_stub_bin="$(mktemp -d /tmp/xwpf-brokencurl.XXXXXX)"
printf '#!/bin/sh\nexit 7\n' > "$_stub_bin/curl"
chmod +x "$_stub_bin/curl"
out=$(PATH="$_stub_bin:$PATH" download_realm_ocr_script 2>&1)
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "下载失败"
assert_contains "$out" "请检查网络连接"

test_that "import_realm_config downloads and invokes the real OCR script, which cancels on empty input"
_realm_etc_cleanup
out=$(import_realm_config <<< "$(printf '\n\n')" 2>&1)
assert_contains "$out" "识别realm配置文件并导入"
assert_contains "$out" "已取消操作"
_realm_etc_cleanup

test_that "import_realm_config reports failure and returns when the OCR script can't be downloaded"
_stub_bin="$(mktemp -d /tmp/xwpf-brokencurl.XXXXXX)"
printf '#!/bin/sh\nexit 7\n' > "$_stub_bin/curl"
chmod +x "$_stub_bin/curl"
out=$(PATH="$_stub_bin:$PATH" import_realm_config <<< "" 2>&1)
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "无法下载配置识别脚本"

test_that "download_failover_script fetches the real companion script from the repo checkout"
_realm_etc_cleanup
out=$(download_failover_script 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "下载成功"
assert_true test -x /etc/realm/xwFailover.sh
_realm_etc_cleanup

test_that "failover_management_menu reports failure and returns when the script can't be downloaded"
_stub_bin="$(mktemp -d /tmp/xwpf-brokencurl.XXXXXX)"
printf '#!/bin/sh\nexit 7\n' > "$_stub_bin/curl"
chmod +x "$_stub_bin/curl"
out=$(PATH="$_stub_bin:$PATH" failover_management_menu <<< "" 2>&1)
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "无法下载故障转移脚本"

test_that "download_speedtest_script fetches the real companion script from the repo checkout"
_realm_etc_cleanup
out=$(download_speedtest_script 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "下载成功"
assert_true test -x /etc/realm/speedtest.sh
_realm_etc_cleanup

test_that "speedtest_menu reports failure and returns when the script can't be downloaded"
_stub_bin="$(mktemp -d /tmp/xwpf-brokencurl.XXXXXX)"
printf '#!/bin/sh\nexit 7\n' > "$_stub_bin/curl"
chmod +x "$_stub_bin/curl"
out=$(PATH="$_stub_bin:$PATH" speedtest_menu <<< "" 2>&1)
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "无法下载测速脚本"

test_that "port_traffic_dog_menu reports failure and returns when the script can't be downloaded"
rm -f /usr/local/bin/port-traffic-dog.sh
_stub_bin="$(mktemp -d /tmp/xwpf-brokencurl.XXXXXX)"
printf '#!/bin/sh\nexit 7\n' > "$_stub_bin/curl"
chmod +x "$_stub_bin/curl"
out=$(PATH="$_stub_bin:$PATH" port_traffic_dog_menu <<< "" 2>&1)
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "无法下载端口流量狗脚本"

end_describe

ptyunit_test_summary
