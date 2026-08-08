#!/usr/bin/env bash
# Unit tests for lib/server.sh's configure_nat_server interactive wizard.
#
# configure_nat_server is a pure prompt-and-set-globals function: it never
# writes rule files itself (that's the caller's job), it just populates
# NAT_LISTEN_PORT/NAT_LISTEN_IP/NAT_THROUGH_IP/REMOTE_IP/REMOTE_PORT/
# SECURITY_LEVEL/WS_HOST/WS_PATH/TLS_SERVER_NAME/RULE_NOTE from user input
# (with defaults on blank input) and calls check_port_usage/check_connectivity
# along the way. Tests drive it entirely via stdin heredocs and assert on
# the resulting globals plus key status lines.
#
# IMPORTANT: `out=$(configure_nat_server <<< ...)` forks a subshell for the
# command substitution, so any global variable assignments made inside the
# function (NAT_LISTEN_PORT, SECURITY_LEVEL, etc.) are discarded when that
# subshell exits — only captured stdout survives. _run_nat below instead
# redirects stdout to a temp file (plain redirection does NOT fork a
# subshell), so the function runs in the top-level test shell and its
# global writes are actually observable afterward. The one test that
# expects the function to `exit 1` (declining to continue after a failed
# connectivity check) deliberately keeps the $(...) subshell wrapper
# instead, since exit 1 would otherwise kill the whole test run.
#
# Most tests use an unreachable-but-fast target (127.0.0.1:1, connection
# refused) plus "y" at the "continue anyway?" prompt, to avoid needing a
# real listener process for every single test. Exactly one test verifies
# the connectivity-success branch against a real loopback listener, and
# two verify the port-occupied-by-realm branch against a real
# realm-named listener (see test-core-system.sh's check_port_usage tests
# for the same technique: ss reports the *kernel comm* of the listening
# process, so a python3 binary copied to a file literally named "realm"
# and exec'd is what makes ss -p's users:(("realm",...)) match for real).
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

_run_nat() {
    local tmpout
    tmpout="$(mktemp)"
    configure_nat_server > "$tmpout" 2>&1 <<< "$1"
    out=$(cat "$tmpout")
    rm -f "$tmpout"
}

_setup_nat() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
    unset NAT_LISTEN_PORT NAT_LISTEN_IP NAT_THROUGH_IP REMOTE_IP REMOTE_PORT \
        SECURITY_LEVEL WS_HOST WS_PATH TLS_SERVER_NAME RULE_NOTE
}
_teardown_nat() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

_make_realm_rule() {
    local id="$1" port="$2"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=nat-${id}
LISTEN_PORT=${port}
LISTEN_IP=192.168.9.9
THROUGH_IP=10.10.10.10
RULE_ROLE=1
REMOTE_HOST=1.2.3.4
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL="tls_ca"
TLS_SERVER_NAME=custom.example.com
WS_PATH=/custom
WS_HOST=wshost.example.com
RULE_NOTE="existing note"
EOF
}

describe "configure_nat_server" _setup_nat _teardown_nat

test_that "assigns a random port and :: defaults, and completes on all-blank input with a real successful connectivity check"
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48020))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
_run_nat $'\n\n\n127.0.0.1\n48020\n\n\n'
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
assert_contains "$out" "连接测试成功"
assert_match "^[0-9]+$" "$NAT_LISTEN_PORT"
assert_eq "::" "$NAT_LISTEN_IP"
assert_eq "::" "$NAT_THROUGH_IP"
assert_eq "127.0.0.1" "$REMOTE_IP"
assert_eq "48020" "$REMOTE_PORT"
assert_eq "standard" "$SECURITY_LEVEL"
assert_contains "$out" "未设置备注"

test_that "loops on an invalid listen port until a valid single port is given"
_run_nat $'99999\n8080\n\n\n127.0.0.1\n1\ny\n\n\n'
assert_contains "$out" "无效端口号"
assert_eq "8080" "$NAT_LISTEN_PORT"

test_that "accepts a custom listen IP and loops past an invalid one first"
_run_nat $'\n not@ip!!\n192.168.1.50\n\n127.0.0.1\n1\ny\n\n\n'
assert_contains "$out" "无效IP地址或网卡名称格式"
assert_eq "192.168.1.50" "$NAT_LISTEN_IP"

test_that "accepts an interface name for the through IP"
_run_nat $'\n\neth0\n127.0.0.1\n1\ny\n\n\n'
assert_eq "eth0" "$NAT_THROUGH_IP"
assert_contains "$out" "出口网卡设置为"

test_that "detects a multi-port listen input and skips the port-usage check"
_run_nat $'8001,8002\n\n\n127.0.0.1\n1\ny\n\n\n'
assert_contains "$out" "检测到多端口配置，跳过端口占用检测"
assert_eq "8001,8002" "$NAT_LISTEN_PORT"

test_that "rejects an empty remote address before accepting a valid one"
_run_nat $'\n\n\n\n10.0.0.5\n1\ny\n\n\n'
assert_contains "$out" "IP地址或域名不能为空"
assert_eq "10.0.0.5" "$REMOTE_IP"

test_that "loops on an invalid remote address until a valid IP or domain is given"
_run_nat $'\n\n\nnot valid!!\n10.0.0.5\n1\ny\n\n\n'
assert_contains "$out" "请输入有效的IP地址或域名"

test_that "loops on an invalid remote port until a valid one is given"
_run_nat $'\n\n\n127.0.0.1\n999999\n1\ny\n\n\n'
assert_contains "$out" "无效端口号"
assert_eq "1" "$REMOTE_PORT"

test_that "skips connectivity testing for a multi-port remote configuration"
_run_nat $'\n\n\n127.0.0.1\n9001,9002\n\n\n'
assert_contains "$out" "多端口配置，跳过连通性测试"
assert_eq "9001,9002" "$REMOTE_PORT"

test_that "shows a DDNS hint and aborts when connectivity fails for a domain target and the user declines to continue"
result=$( (configure_nat_server <<< $'\n\n\ntest.invalid\n1\nn\n') ; echo "STATUS:$?" )
assert_contains "$result" "检测到您使用的是域名地址"
assert_contains "$result" "STATUS:1"

test_that "continues past a failed connectivity check when confirmed"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n\n\n'
assert_contains "$out" "连接测试失败"
assert_contains "$out" "已选择: 默认传输"

test_that "loops on an invalid transport choice until a valid one is given"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n9\n1\n\n'
assert_contains "$out" "无效选择，请输入 1-6"
assert_eq "standard" "$SECURITY_LEVEL"

test_that "configures WebSocket transport with default host/path on blank input"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n2\n\n\n\n'
assert_eq "ws" "$SECURITY_LEVEL"
assert_eq "$DEFAULT_SNI_DOMAIN" "$WS_HOST"
assert_eq "/ws" "$WS_PATH"

test_that "configures TLS self-signed transport with a default SNI on blank input"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n3\n\n\n'
assert_eq "tls_self" "$SECURITY_LEVEL"
assert_eq "$DEFAULT_SNI_DOMAIN" "$TLS_SERVER_NAME"

test_that "configures TLS CA transport with a custom SNI"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n4\nca.example.com\n\n'
assert_eq "tls_ca" "$SECURITY_LEVEL"
assert_eq "ca.example.com" "$TLS_SERVER_NAME"
assert_contains "$out" "TLS配置完成"

test_that "configures TLS+WebSocket self-signed transport with a custom host and default SNI/path"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n5\nwshost.example.com\n\n\n\n'
assert_eq "ws_tls_self" "$SECURITY_LEVEL"
assert_eq "wshost.example.com" "$WS_HOST"
assert_eq "$DEFAULT_SNI_DOMAIN" "$TLS_SERVER_NAME"
assert_eq "/ws" "$WS_PATH"

test_that "configures TLS+WebSocket CA transport with a custom SNI and path"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n6\n\nca2.example.com\n/customws\n\n'
assert_eq "ws_tls_ca" "$SECURITY_LEVEL"
assert_eq "$DEFAULT_SNI_DOMAIN" "$WS_HOST"
assert_eq "ca2.example.com" "$TLS_SERVER_NAME"
assert_eq "/customws" "$WS_PATH"
assert_contains "$out" "TLS+WebSocket配置完成"

test_that "sets a custom rule note when none exists yet"
_run_nat $'\n\n\n127.0.0.1\n1\ny\n\nmy custom note\n'
assert_eq "my custom note" "$RULE_NOTE"
assert_contains "$out" "备注设置为: my custom note"

test_that "reuses an existing same-port realm rule's config and skips the IP/transport prompts"
realm_bin="$(mktemp -u /tmp/realm.XXXXXX)"
cp "$(command -v python3)" "$realm_bin"
"$realm_bin" -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48030))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
_make_realm_rule 1 48030
_run_nat $'48030\n127.0.0.1\n1\ny\n\n'
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
rm -f "$realm_bin"
assert_contains "$out" "检测到端口已被realm占用"
assert_contains "$out" "使用默认配置完成设置"
assert_not_contains "$out" "请选择传输模式"
assert_eq "192.168.9.9" "$NAT_LISTEN_IP"
assert_eq "10.10.10.10" "$NAT_THROUGH_IP"
assert_eq "tls_ca" "$SECURITY_LEVEL"
assert_eq "custom.example.com" "$TLS_SERVER_NAME"
assert_eq "/custom" "$WS_PATH"
assert_eq "wshost.example.com" "$WS_HOST"
assert_contains "$out" "使用现有备注: existing note"
assert_eq "existing note" "$RULE_NOTE"

test_that "overrides an existing rule's note with a newly entered one"
realm_bin="$(mktemp -u /tmp/realm.XXXXXX)"
cp "$(command -v python3)" "$realm_bin"
"$realm_bin" -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48031))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
_make_realm_rule 1 48031
_run_nat $'48031\n127.0.0.1\n1\ny\nbrand new note\n'
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
rm -f "$realm_bin"
assert_eq "brand new note" "$RULE_NOTE"
assert_contains "$out" "备注设置为: brand new note"

end_describe

ptyunit_test_summary
