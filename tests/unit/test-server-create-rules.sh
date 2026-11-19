#!/usr/bin/env bash
# Unit tests for lib/server.sh's rule-file writers: create_single_nat_rule,
# create_single_exit_rule, create_nat_rules_for_ports, create_exit_rules_for_ports.
# These write RULE_ID/etc rule-N.conf files directly from globals the caller
# (configure_nat_server/configure_exit_server) is expected to have set first.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

_setup_rules_dir() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
    SECURITY_LEVEL="standard"
    NAT_THROUGH_IP="::"
    NAT_LISTEN_IP="::"
    REMOTE_IP="203.0.113.5"
    TLS_SERVER_NAME=""
    WS_PATH=""
    WS_HOST=""
    RULE_NOTE=""
    FORWARD_TARGET=""
    TLS_CERT_PATH=""
    TLS_KEY_PATH=""
}

_teardown_rules_dir() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

describe "create_single_nat_rule" _setup_rules_dir _teardown_rules_dir

test_that "writes a role-1 rule file with the given listen/remote ports"
out=$(create_single_nat_rule "8001" "9001")
assert_contains "$out" "中转配置已创建"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8001" "$LISTEN_PORT"
assert_eq "9001" "$REMOTE_PORT"
assert_eq "1" "$RULE_ROLE"
assert_eq "$REMOTE_IP" "$REMOTE_HOST"
assert_eq "off" "$BALANCE_MODE"
assert_eq "off" "$MPTCP_MODE"
assert_eq "off" "$PROXY_MODE"

end_describe

describe "create_single_exit_rule" _setup_rules_dir _teardown_rules_dir

test_that "writes a role-2 rule file with the forward target built from FORWARD_TARGET and the port"
FORWARD_TARGET="127.0.0.1"
out=$(create_single_exit_rule "8001" "9001")
assert_contains "$out" "服务端配置已创建"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8001" "$LISTEN_PORT"
assert_eq "2" "$RULE_ROLE"
assert_eq "127.0.0.1:9001" "$FORWARD_TARGET"

test_that "appends TLS_CERT_PATH/TLS_KEY_PATH when SECURITY_LEVEL is tls_ca"
FORWARD_TARGET="127.0.0.1"
SECURITY_LEVEL="tls_ca"
TLS_CERT_PATH="/etc/realm/cert.pem"
TLS_KEY_PATH="/etc/realm/key.pem"
create_single_exit_rule "8001" "9001" >/dev/null
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "/etc/realm/cert.pem" "$TLS_CERT_PATH"
assert_eq "/etc/realm/key.pem" "$TLS_KEY_PATH"

test_that "appends TLS_CERT_PATH/TLS_KEY_PATH when SECURITY_LEVEL is ws_tls_ca"
FORWARD_TARGET="127.0.0.1"
SECURITY_LEVEL="ws_tls_ca"
TLS_CERT_PATH="/etc/realm/cert2.pem"
TLS_KEY_PATH="/etc/realm/key2.pem"
create_single_exit_rule "8001" "9001" >/dev/null
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "/etc/realm/cert2.pem" "$TLS_CERT_PATH"

test_that "does not append TLS cert fields for a non-CA security level"
FORWARD_TARGET="127.0.0.1"
SECURITY_LEVEL="standard"
create_single_exit_rule "8001" "9001" >/dev/null
assert_false grep -q "^TLS_CERT_PATH=" "${RULES_DIR}/rule-1.conf"

end_describe

describe "create_nat_rules_for_ports" _setup_rules_dir _teardown_rules_dir

test_that "maps a single remote port to every listen port"
create_nat_rules_for_ports "8001,8002,8003" "9001" >/dev/null
read_rule_file "${RULES_DIR}/rule-1.conf"; assert_eq "8001" "$LISTEN_PORT"; assert_eq "9001" "$REMOTE_PORT"
read_rule_file "${RULES_DIR}/rule-2.conf"; assert_eq "8002" "$LISTEN_PORT"; assert_eq "9001" "$REMOTE_PORT"
read_rule_file "${RULES_DIR}/rule-3.conf"; assert_eq "8003" "$LISTEN_PORT"; assert_eq "9001" "$REMOTE_PORT"

test_that "pairs listen ports with remote ports index-by-index when counts match"
create_nat_rules_for_ports "8001,8002" "9001,9002" >/dev/null
read_rule_file "${RULES_DIR}/rule-1.conf"; assert_eq "9001" "$REMOTE_PORT"
read_rule_file "${RULES_DIR}/rule-2.conf"; assert_eq "9002" "$REMOTE_PORT"

test_that "falls back to the first remote port once the remote list is exhausted"
create_nat_rules_for_ports "8001,8002,8003" "9001,9002" >/dev/null
read_rule_file "${RULES_DIR}/rule-3.conf"; assert_eq "9001" "$REMOTE_PORT"

test_that "prints a multi-port summary only when more than one rule was created"
out=$(create_nat_rules_for_ports "8001,8002" "9001")
assert_contains "$out" "多端口配置完成，共创建 2 个中转规则"

test_that "does not print the multi-port summary for a single port"
out=$(create_nat_rules_for_ports "8001" "9001")
assert_not_contains "$out" "多端口配置完成"

end_describe

describe "create_exit_rules_for_ports" _setup_rules_dir _teardown_rules_dir

test_that "maps a single forward port to every listen port"
FORWARD_TARGET="127.0.0.1"
create_exit_rules_for_ports "8001,8002,8003" "9001" >/dev/null
read_rule_file "${RULES_DIR}/rule-1.conf"; assert_eq "127.0.0.1:9001" "$FORWARD_TARGET"
read_rule_file "${RULES_DIR}/rule-3.conf"; assert_eq "127.0.0.1:9001" "$FORWARD_TARGET"

test_that "pairs listen ports with forward ports index-by-index when counts match"
FORWARD_TARGET="127.0.0.1"
create_exit_rules_for_ports "8001,8002" "9001,9002" >/dev/null
read_rule_file "${RULES_DIR}/rule-1.conf"; assert_eq "127.0.0.1:9001" "$FORWARD_TARGET"
read_rule_file "${RULES_DIR}/rule-2.conf"; assert_eq "127.0.0.1:9002" "$FORWARD_TARGET"

test_that "falls back to the first forward port once the forward list is exhausted"
FORWARD_TARGET="127.0.0.1"
create_exit_rules_for_ports "8001,8002,8003" "9001,9002" >/dev/null
read_rule_file "${RULES_DIR}/rule-3.conf"; assert_eq "127.0.0.1:9001" "$FORWARD_TARGET"

test_that "prints a multi-port summary only when more than one rule was created"
FORWARD_TARGET="127.0.0.1"
out=$(create_exit_rules_for_ports "8001,8002" "9001")
assert_contains "$out" "多端口配置完成，共创建 2 个服务端规则"

test_that "does not print the multi-port summary for a single port"
FORWARD_TARGET="127.0.0.1"
out=$(create_exit_rules_for_ports "8001" "9001")
assert_not_contains "$out" "多端口配置完成"

end_describe

ptyunit_test_summary
