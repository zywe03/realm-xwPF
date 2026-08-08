#!/usr/bin/env bash
# Unit tests for the interactive single-rule editors in lib/rules.sh:
# edit_nat_server_config and edit_exit_server_config. Both read a sequence
# of plain `read` prompts from stdin (no readline needed), so answers are
# fed as newline-separated heredocs; a blank line means "accept default".
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
LISTEN_IP=::
THROUGH_IP=::
RULE_ROLE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
ENABLED=${enabled}
SECURITY_LEVEL=standard
BALANCE_MODE=off
TARGET_STATES=
WEIGHTS=
RULE_NOTE=orig-note
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
RULE_NOTE=orig-note
EOF
}

_setup_rules_dir() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
}

_teardown_rules_dir() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

describe "edit_nat_server_config" _setup_rules_dir _teardown_rules_dir

test_that "accepting every default leaves fields unchanged except the note is re-saved"
_make_relay_rule 1 8001
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'




EOF
)
assert_contains "$out" "配置已更新"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8001" "$LISTEN_PORT"
assert_eq "::" "$LISTEN_IP"
assert_eq "::" "$THROUGH_IP"
assert_eq "127.0.0.1" "$REMOTE_HOST"
assert_eq "9000" "$REMOTE_PORT"
assert_eq "orig-note" "$RULE_NOTE"

test_that "an invalid port is rejected and re-prompted, then a valid port is applied"
_make_relay_rule 1 8001
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'
notaport
8002




EOF
)
assert_contains "$out" "无效端口号"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8002" "$LISTEN_PORT"

test_that "an invalid listen IP/interface falls back to the original value"
_make_relay_rule 1 8001
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'

!!!bad!!!



EOF
)
assert_contains "$out" "无效IP地址或网卡名称，保持原值"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "::" "$LISTEN_IP"

test_that "an invalid through IP/interface falls back to the original value"
_make_relay_rule 1 8001
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'


!!!bad!!!


EOF
)
assert_contains "$out" "无效IP地址或网卡名称，保持原值"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "::" "$THROUGH_IP"

test_that "an invalid remote host falls back to the original value"
_make_relay_rule 1 8001
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'



!!!bad!!!
EOF
)
assert_contains "$out" "无效地址，保持原值"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "127.0.0.1" "$REMOTE_HOST"

test_that "an invalid remote port is rejected and re-prompted, then a valid port is applied"
_make_relay_rule 1 8001
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'




notaport
9001
EOF
)
assert_contains "$out" "无效端口号"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "9001" "$REMOTE_PORT"

test_that "custom values including a new note are all applied, and RULE_NOTE is appended when missing"
_make_relay_rule 1 8001
sed -i '/^RULE_NOTE=/d' "${RULES_DIR}/rule-1.conf"
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'
9001
192.168.1.1
10.0.0.1
example.com
9100
hello world
EOF
)
assert_contains "$out" "配置已更新"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "9001" "$LISTEN_PORT"
assert_eq "192.168.1.1" "$LISTEN_IP"
assert_eq "10.0.0.1" "$THROUGH_IP"
assert_eq "example.com" "$REMOTE_HOST"
assert_eq "9100" "$REMOTE_PORT"
assert_eq "hello world" "$RULE_NOTE"

test_that "balance-mode rule: changing the listen port with 2+ remaining targets syncs the old port group instead of disabling it"
_make_relay_rule 1 8001
_make_relay_rule 2 8001
_make_relay_rule 3 8001
for id in 1 2 3; do
    sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"roundrobin\"/" "${RULES_DIR}/rule-${id}.conf"
    sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"127.0.0.1:9000,10.0.0.2:9000,10.0.0.3:9000\"|" "${RULES_DIR}/rule-${id}.conf"
    sed -i "s|^WEIGHTS=.*|WEIGHTS=\"5,5,5\"|" "${RULES_DIR}/rule-${id}.conf"
done
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'
9002




EOF
)
assert_contains "$out" "检测到端口变更"
assert_contains "$out" "已更新旧端口组"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$BALANCE_MODE"
assert_eq "" "$TARGET_STATES"

test_that "balance-mode rule: changing the listen port with only 1 remaining target auto-disables balance mode on the old port"
_make_relay_rule 1 8001
_make_relay_rule 2 8001
for id in 1 2; do
    sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"roundrobin\"/" "${RULES_DIR}/rule-${id}.conf"
    sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"127.0.0.1:9000,10.0.0.2:9000\"|" "${RULES_DIR}/rule-${id}.conf"
    sed -i "s|^WEIGHTS=.*|WEIGHTS=\"5,5\"|" "${RULES_DIR}/rule-${id}.conf"
done
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'
9002




EOF
)
assert_contains "$out" "旧端口组只剩1个目标，自动关闭负载均衡模式"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "off" "$BALANCE_MODE"

test_that "balance-mode rule: changing only the target (same port) syncs the target across the group"
_make_relay_rule 1 8001
_make_relay_rule 2 8001
for id in 1 2; do
    sed -i "s/^BALANCE_MODE=.*/BALANCE_MODE=\"roundrobin\"/" "${RULES_DIR}/rule-${id}.conf"
    sed -i "s|^TARGET_STATES=.*|TARGET_STATES=\"127.0.0.1:9000,10.0.0.2:9000\"|" "${RULES_DIR}/rule-${id}.conf"
    sed -i "s|^WEIGHTS=.*|WEIGHTS=\"5,5\"|" "${RULES_DIR}/rule-${id}.conf"
done
out=$(edit_nat_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'



192.168.1.1
9500
EOF
)
assert_contains "$out" "检测到负载均衡规则，正在同步更新相同端口的所有规则"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_contains "$TARGET_STATES" "192.168.1.1:9500"

end_describe

describe "edit_exit_server_config" _setup_rules_dir _teardown_rules_dir

test_that "accepting every default leaves fields unchanged except the note is re-saved"
_make_exit_rule 1 8101
out=$(edit_exit_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'



EOF
)
assert_contains "$out" "配置已更新"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8101" "$LISTEN_PORT"
assert_eq "127.0.0.1:9100" "$FORWARD_TARGET"
assert_eq "orig-note" "$RULE_NOTE"

test_that "an invalid listen port is rejected and re-prompted, then a valid port is applied"
_make_exit_rule 1 8101
out=$(edit_exit_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'
notaport
8102



EOF
)
assert_contains "$out" "无效端口号"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8102" "$LISTEN_PORT"

test_that "an invalid forward target host falls back to the original value"
_make_exit_rule 1 8101
out=$(edit_exit_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'

!!!bad!!!

EOF
)
assert_contains "$out" "无效地址，保持原值"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "127.0.0.1:9100" "$FORWARD_TARGET"

test_that "an invalid forward target port is rejected and re-prompted, then a valid port is applied"
_make_exit_rule 1 8101
out=$(edit_exit_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'


notaport
9200
EOF
)
assert_contains "$out" "无效端口号"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "127.0.0.1:9200" "$FORWARD_TARGET"

test_that "custom values including a new note are all applied, and RULE_NOTE is appended when missing"
_make_exit_rule 1 8101
sed -i '/^RULE_NOTE=/d' "${RULES_DIR}/rule-1.conf"
out=$(edit_exit_server_config "${RULES_DIR}/rule-1.conf" <<'EOF'
8200
example.com
9300
hello world
EOF
)
assert_contains "$out" "配置已更新"
read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8200" "$LISTEN_PORT"
assert_eq "example.com:9300" "$FORWARD_TARGET"
assert_eq "hello world" "$RULE_NOTE"

end_describe

ptyunit_test_summary
