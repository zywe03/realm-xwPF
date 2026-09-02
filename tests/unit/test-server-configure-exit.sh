#!/usr/bin/env bash
# Unit tests for lib/server.sh's configure_exit_server interactive wizard —
# the "出口服务器" (exit-side) counterpart to configure_nat_server. Like
# that function, it's a pure prompt-and-set-globals flow (EXIT_LISTEN_PORT,
# FORWARD_TARGET, SECURITY_LEVEL, WS_HOST/WS_PATH, TLS_SERVER_NAME or
# TLS_CERT_PATH/TLS_KEY_PATH, RULE_NOTE) with no rule-file writes, plus a
# get_public_ip() display step at the top (mocked via tests/mocks/bin/curl's
# XWPF_MOCK_PUBLIC_IP).
#
# Same subshell trap as test-server-configure-nat.sh: `$(configure_exit_server
# <<< ...)` forks a subshell for the command substitution, discarding any
# global variable writes once it exits. _run_exit below redirects stdout to
# a temp file instead (plain redirection does not fork), so the function
# runs in the top-level test shell and its globals are observable after the
# call. The one test that expects the function to `exit 1` (declining to
# continue after a failed connectivity check) keeps the $(...) subshell
# wrapper deliberately, since exit 1 would otherwise kill the whole run.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

_run_exit() {
    local tmpout
    tmpout="$(mktemp)"
    configure_exit_server > "$tmpout" 2>&1 <<< "$1"
    out=$(cat "$tmpout")
    rm -f "$tmpout"
}

_setup_exit() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
    unset EXIT_LISTEN_PORT FORWARD_TARGET SECURITY_LEVEL WS_HOST WS_PATH \
        TLS_SERVER_NAME TLS_CERT_PATH TLS_KEY_PATH RULE_NOTE
}
_teardown_exit() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

# Redirecting python3's own stdout/stderr away (rather than just
# backgrounding it) matters: called as `listener_pid=$(_bind_listener ...)`,
# this whole function body runs inside a command-substitution subshell, and
# a backgrounded child that still shares that subshell's stdout pipe keeps
# the pipe open (so the command substitution blocks) until the child exits
# — i.e. it wouldn't return until the listener's 5s sleep finished.
_bind_listener() {
    python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $1))
s.listen(1)
time.sleep(5)
" >/dev/null 2>&1 &
    echo $!
}

describe "configure_exit_server" _setup_exit _teardown_exit

test_that "shows both public IPs and completes a standard-transport flow with a reachable loopback forward target"
listener_pid=$(_bind_listener 48040)
sleep 0.3
XWPF_MOCK_PUBLIC_IP="203.0.113.9" _run_exit $'47001\n\n48040\n\n\n'
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
assert_contains "$out" "本机IPv4地址: 203.0.113.9"
assert_contains "$out" "本机IPv6地址: 203.0.113.9"
assert_eq "47001" "$EXIT_LISTEN_PORT"
assert_eq "127.0.0.1:48040" "$FORWARD_TARGET"
assert_eq "standard" "$SECURITY_LEVEL"
assert_contains "$out" "所有转发目标连接测试成功"
assert_contains "$out" "未设置备注"

test_that "reports being unable to auto-detect a public IP when both lookups fail"
_run_exit $'47001\n127.0.0.1\n1\ny\n\n\n'
assert_contains "$out" "无法自动获取公网IP，请手动确认"

test_that "loops on an invalid listen port until a valid one is given"
_run_exit $'99999\n47002\n\n1\ny\n\n\n'
assert_contains "$out" "无效端口号"
assert_eq "47002" "$EXIT_LISTEN_PORT"

test_that "detects a multi-port listen input and skips the port-usage check"
_run_exit $'8001,8002\n\n1\ny\n\n\n'
assert_contains "$out" "检测到多端口配置，跳过端口占用检测"
assert_eq "8001,8002" "$EXIT_LISTEN_PORT"

test_that "defaults the forward target to 127.0.0.1 on blank input"
_run_exit $'47003\n\n1\ny\n\n\n'
assert_eq "127.0.0.1:1" "$FORWARD_TARGET"
assert_contains "$out" "转发目标设置为: 127.0.0.1"

test_that "loops on an invalid forward target address before accepting a valid one"
_run_exit $'47004\nnot a target!!\nlocalhost\n1\ny\n\n\n'
assert_contains "$out" "无效地址格式"
assert_eq "localhost:1" "$FORWARD_TARGET"

test_that "accepts a comma-separated multi-address forward target"
_run_exit $'47005\n127.0.0.1,localhost\n1\ny\n\n\n'
assert_eq "127.0.0.1,localhost:1" "$FORWARD_TARGET"

test_that "loops on an invalid forward port until a valid one is given"
_run_exit $'47006\n127.0.0.1\n999999\n1\ny\n\n\n'
assert_contains "$out" "无效端口号"
assert_eq "127.0.0.1:1" "$FORWARD_TARGET"

test_that "skips connectivity testing for a multi-port forward target"
_run_exit $'47007\n127.0.0.1\n9001,9002\n\n\n'
assert_contains "$out" "多端口配置，跳过转发目标连通性测试"
assert_eq "127.0.0.1:9001,9002" "$FORWARD_TARGET"

test_that "shows a DDNS hint and aborts when a domain forward target fails connectivity and the user declines to continue"
result=$( (configure_exit_server <<< $'47008\ntest.invalid\n1\nn\n') ; echo "STATUS:$?" )
assert_contains "$result" "检测到您使用的是域名地址"
assert_contains "$result" "DDNS域名无法进行连通性测试"
assert_contains "$result" "STATUS:1"

test_that "continues past a failed connectivity check when confirmed"
_run_exit $'47009\n127.0.0.1\n1\ny\n\n\n'
assert_contains "$out" "连接失败"
assert_contains "$out" "已选择: 默认传输"

test_that "loops on an invalid transport choice until a valid one is given"
_run_exit $'47010\n127.0.0.1\n1\ny\n9\n1\n\n'
assert_contains "$out" "无效选择，请输入 1-6"
assert_eq "standard" "$SECURITY_LEVEL"

test_that "configures WebSocket transport with default host/path on blank input"
_run_exit $'47011\n127.0.0.1\n1\ny\n2\n\n\n\n'
assert_eq "ws" "$SECURITY_LEVEL"
assert_eq "$DEFAULT_SNI_DOMAIN" "$WS_HOST"
assert_eq "/ws" "$WS_PATH"

test_that "configures TLS self-signed transport with a default SNI on blank input"
_run_exit $'47012\n127.0.0.1\n1\ny\n3\n\n\n'
assert_eq "tls_self" "$SECURITY_LEVEL"
assert_eq "$DEFAULT_SNI_DOMAIN" "$TLS_SERVER_NAME"

test_that "loops on non-existent cert/key file paths before accepting real ones for TLS CA transport"
cert_file="$(mktemp)"
key_file="$(mktemp)"
_run_exit $'47013\n127.0.0.1\n1\ny\n4\n/no/such/cert\n'"$cert_file"$'\n/no/such/key\n'"$key_file"$'\n\n'
rm -f "$cert_file" "$key_file"
assert_contains "$out" "证书文件不存在"
assert_contains "$out" "私钥文件不存在"
assert_eq "tls_ca" "$SECURITY_LEVEL"
assert_eq "$cert_file" "$TLS_CERT_PATH"
assert_eq "$key_file" "$TLS_KEY_PATH"
assert_contains "$out" "TLS配置完成"

test_that "configures TLS+WebSocket self-signed transport with a custom host and default SNI/path"
_run_exit $'47014\n127.0.0.1\n1\ny\n5\nwshost.example.com\n\n\n\n'
assert_eq "ws_tls_self" "$SECURITY_LEVEL"
assert_eq "wshost.example.com" "$WS_HOST"
assert_eq "$DEFAULT_SNI_DOMAIN" "$TLS_SERVER_NAME"
assert_eq "/ws" "$WS_PATH"

test_that "configures TLS+WebSocket CA transport with cert/key files and a custom path"
cert_file="$(mktemp)"
key_file="$(mktemp)"
_run_exit $'47015\n127.0.0.1\n1\ny\n6\n\n'"$cert_file"$'\n'"$key_file"$'\n/customws\n\n'
rm -f "$cert_file" "$key_file"
assert_eq "ws_tls_ca" "$SECURITY_LEVEL"
assert_eq "$DEFAULT_SNI_DOMAIN" "$WS_HOST"
assert_eq "$cert_file" "$TLS_CERT_PATH"
assert_eq "$key_file" "$TLS_KEY_PATH"
assert_eq "/customws" "$WS_PATH"
assert_contains "$out" "TLS+WebSocket配置完成"

test_that "sets a custom rule note"
_run_exit $'47016\n127.0.0.1\n1\ny\n\nmy exit note\n'
assert_eq "my exit note" "$RULE_NOTE"
assert_contains "$out" "备注设置为: my exit note"

end_describe

ptyunit_test_summary
