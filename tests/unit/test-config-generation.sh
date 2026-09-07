#!/usr/bin/env bash
# Unit tests for realm.sh's config-file generation: turning rule-N.conf files
# into the endpoints array of realm's own config.json.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"

_make_rule_file() {
    local id="$1" port="$2" role="${3:-1}" enabled="${4:-true}"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=test-rule-${id}
LISTEN_PORT=${port}
RULE_ROLE=${role}
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
FORWARD_TARGET=127.0.0.1:9100
ENABLED=${enabled}
SECURITY_LEVEL=standard
EOF
}

_setup() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
}

_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

# Base fields plus any "KEY=VALUE" extras, appended after (and so overriding,
# since read_rule_file just sources the whole file) the base block — lets
# each test set only the fields it cares about (BALANCE_MODE, TARGET_STATES,
# WEIGHTS, FAILOVER_ENABLED, MPTCP_MODE, PROXY_MODE, LISTEN_IP, THROUGH_IP...)
# without every other test needing to know about them.
_make_rule_file_ex() {
    local id="$1" port="$2"
    shift 2
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=test-rule-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
FORWARD_TARGET=127.0.0.1:9100
ENABLED=true
SECURITY_LEVEL=standard
EOF
    for kv in "$@"; do
        echo "$kv" >> "${RULES_DIR}/rule-${id}.conf"
    done
}

describe "generate_endpoints_from_rules" _setup _teardown

test_that "produces no endpoints when the rules dir is empty"
assert_eq "" "$(generate_endpoints_from_rules)"

test_that "produces no endpoints when the rules dir doesn't exist at all"
rm -rf "$RULES_DIR"
assert_eq "" "$(generate_endpoints_from_rules)"

test_that "produces one endpoint per enabled rule"
_make_rule_file 1 8001
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" "8001"

test_that "skips disabled rules"
_setup
_make_rule_file 1 8001 1 false
endpoints="$(generate_endpoints_from_rules)"
assert_not_contains "$endpoints" "8001"

test_that "warns and skips a rule when its port is already claimed by a different role"
_make_rule_file_ex 1 8002 'RULE_ROLE=1'
_make_rule_file_ex 2 8002 'RULE_ROLE=2'
out="$(generate_endpoints_from_rules 2>&1 >/dev/null)"
assert_contains "$out" "已被角色"

test_that "role-2 (exit server) rules use FORWARD_TARGET and dual-stack listen by default"
_make_rule_file_ex 1 8003 'RULE_ROLE=2' 'FORWARD_TARGET=10.0.0.5:9200'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"listen": ":::8003"'
assert_contains "$endpoints" '"remote": "10.0.0.5:9200"'

test_that "TARGET_STATES drives multi-target load balancing when balance mode is on"
_make_rule_file_ex 1 8004 'BALANCE_MODE=roundrobin' 'TARGET_STATES=10.0.0.1:9001,10.0.0.2:9002' 'WEIGHTS=3,1'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"remote": "10.0.0.1:9001"'
assert_contains "$endpoints" '"extra_remotes": ["10.0.0.2:9002"]'
assert_contains "$endpoints" '"balance": "roundrobin: 3, 1"'

test_that "comma-separated REMOTE_HOST expands into multiple targets with default equal weights"
_make_rule_file_ex 1 8005 'REMOTE_HOST=10.0.0.1,10.0.0.2' 'BALANCE_MODE=roundrobin'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"extra_remotes": ["10.0.0.2:9000"]'
assert_contains "$endpoints" '"balance": "roundrobin: 1, 1"'

test_that "listen_ip that isn't a valid IP is treated as an interface name"
_make_rule_file_ex 1 8006 'LISTEN_IP=eth0'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"listen": "0.0.0.0:8006"'
assert_contains "$endpoints" '"listen_interface": "eth0"'

test_that "a valid through_ip on a relay rule adds a through field"
_make_rule_file_ex 1 8007 'THROUGH_IP=10.0.0.9'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"through": "10.0.0.9"'

test_that "an interface-name through_ip adds an interface field instead"
_make_rule_file_ex 1 8008 'THROUGH_IP=eth1'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"interface": "eth1"'

test_that "MPTCP_MODE=both sets send_mptcp and accept_mptcp"
_make_rule_file_ex 1 8009 'MPTCP_MODE=both'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"send_mptcp": true'
assert_contains "$endpoints" '"accept_mptcp": true'

test_that "PROXY_MODE=v1_send sets send_proxy with version 1"
_make_rule_file_ex 1 8010 'PROXY_MODE=v1_send'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"send_proxy": true'
assert_contains "$endpoints" '"send_proxy_version": 1'

test_that "PROXY_MODE=v1_accept sets accept_proxy alone at version 1"
_make_rule_file_ex 1 8010 'PROXY_MODE=v1_accept'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"accept_proxy": true'
assert_not_contains "$endpoints" '"send_proxy": true'
assert_contains "$endpoints" '"accept_proxy_timeout": 5'

test_that "PROXY_MODE=v1_both sets send_proxy and accept_proxy at version 1"
_make_rule_file_ex 1 8010 'PROXY_MODE=v1_both'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"send_proxy": true'
assert_contains "$endpoints" '"accept_proxy": true'
assert_contains "$endpoints" '"send_proxy_version": 1'

test_that "PROXY_MODE=v2_accept sets accept_proxy alone at version 2"
_make_rule_file_ex 1 8010 'PROXY_MODE=v2_accept'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"accept_proxy": true'
assert_not_contains "$endpoints" '"send_proxy": true'

test_that "PROXY_MODE=v2_both sets both send_proxy and accept_proxy at version 2"
_make_rule_file_ex 1 8011 'PROXY_MODE=v2_both'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"send_proxy": true'
assert_contains "$endpoints" '"accept_proxy": true'
assert_contains "$endpoints" '"send_proxy_version": 2'

test_that "MPTCP_MODE=accept sets accept_mptcp alone"
_make_rule_file_ex 1 8010 'MPTCP_MODE=accept'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"accept_mptcp": true'
assert_not_contains "$endpoints" '"send_mptcp": true'

test_that "MPTCP and Proxy configs merge into a single network block when both are set"
_make_rule_file_ex 1 8012 'MPTCP_MODE=send' 'PROXY_MODE=v2_send'
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"send_mptcp": true'
assert_contains "$endpoints" '"send_proxy": true'
network_block_count="$(grep -o '"network": {' <<< "$endpoints" | wc -l)"
assert_eq "1" "$network_block_count"

end_describe

_health_setup() {
    _setup
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm/health: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    mkdir -p /etc/realm/health
}
_health_teardown() {
    _teardown
    rm -rf /etc/realm/health
}

describe "generate_endpoints_from_rules: failover filtering" _health_setup _health_teardown

test_that "drops a target marked failed in health_status.conf, and rebalances its weight"
_make_rule_file_ex 1 8013 'BALANCE_MODE=roundrobin' \
    'TARGET_STATES=10.0.0.1:9001,10.0.0.2:9002' 'WEIGHTS=1,1' 'FAILOVER_ENABLED=true'
cat > /etc/realm/health/health_status.conf <<'EOF'
# comment lines and blank lines should be skipped

1|10.0.0.1|failed|0
EOF
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"remote": "10.0.0.2:9002"'
assert_not_contains "$endpoints" "10.0.0.1"

test_that "keeps multiple healthy targets, appending each to the filtered list"
_make_rule_file_ex 1 8015 'BALANCE_MODE=roundrobin' \
    'TARGET_STATES=10.0.0.5:9001,10.0.0.6:9002,10.0.0.7:9003' 'WEIGHTS=1,1,1' 'FAILOVER_ENABLED=true'
cat > /etc/realm/health/health_status.conf <<'EOF'
1|10.0.0.5|failed|0
EOF
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"remote": "10.0.0.6:9002"'
assert_contains "$endpoints" '"extra_remotes": ["10.0.0.7:9003"]'
assert_not_contains "$endpoints" "10.0.0.5"

test_that "keeps the first target if every node in the group is marked failed"
_make_rule_file_ex 1 8014 'BALANCE_MODE=roundrobin' \
    'TARGET_STATES=10.0.0.3:9001,10.0.0.4:9002' 'WEIGHTS=1,1' 'FAILOVER_ENABLED=true'
cat > /etc/realm/health/health_status.conf <<'EOF'
1|10.0.0.3|failed|0
1|10.0.0.4|failed|0
EOF
endpoints="$(generate_endpoints_from_rules)"
assert_contains "$endpoints" '"remote": "10.0.0.3:9001"'
assert_not_contains "$endpoints" "10.0.0.4"

end_describe

describe "generate_complete_config / generate_network_config"

test_that "wraps endpoints JSON with a network block, written to the given path"
out_path="$(mktemp /tmp/xwpf-test-config.XXXXXX.json)"
generate_complete_config '{"listen":":8001"}' "$out_path"
assert_file_exists "$out_path"
assert_contains "$(cat "$out_path")" '"endpoints"'
assert_contains "$(cat "$out_path")" '"listen":":8001"'
rm -f "$out_path"

test_that "defaults to no_tcp=false, use_udp=true when no prior config exists"
assert_contains "$(generate_network_config)" '"use_udp": true'

test_that "falls back to a hardcoded default network block if generate_network_config ever returns empty"
generate_network_config() { :; }
out_path="$(mktemp /tmp/xwpf-test-config.XXXXXX.json)"
generate_complete_config '{"listen":":8001"}' "$out_path"
assert_contains "$(cat "$out_path")" '"no_tcp": false, "use_udp": true'
rm -f "$out_path"
# unset -f alone would leave the function undefined for the rest of this
# file (there's no way to "pop" an override) — re-source to restore the
# real generate_network_config for the tests that follow.
source "$XWPF_REPO_ROOT/lib/core.sh"

end_describe

# generate_network_config hardcodes "/etc/realm/config.json" rather than
# accepting a path argument, so exercising the merge branch means writing to
# that real path — guarded by XWPF_ALLOW_SYSTEM_WRITES like the other real
# system-path fixtures in tests/helpers/env.sh.
_setup_real_config() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    # Serialize against other unit test files that also write real
    # /etc/realm/config.json in parallel (install_realm, generate_realm_config).
    xwpf_lock_realm_config
    mkdir -p /etc/realm
}
_teardown_real_config() {
    rm -f /etc/realm/config.json
    xwpf_unlock_realm_config
}

describe "generate_network_config: merges an existing proxy protocol config" _setup_real_config _teardown_real_config

test_that "carries forward send_proxy settings from an existing config.json"
cat > /etc/realm/config.json <<'EOF'
{
    "network": {
        "no_tcp": false,
        "use_udp": true,
        "send_proxy": true,
        "send_proxy_version": 2
    },
    "endpoints": []
}
EOF
out="$(generate_network_config)"
assert_contains "$out" '"send_proxy": true'
assert_contains "$out" '"send_proxy_version": 2'
assert_contains "$out" '"use_udp": true'

test_that "falls back to the base network when the existing config has no proxy fields"
cat > /etc/realm/config.json <<'EOF'
{
    "network": {
        "no_tcp": false,
        "use_udp": true
    },
    "endpoints": []
}
EOF
out="$(generate_network_config)"
assert_contains "$out" '"use_udp": true'
assert_not_contains "$out" "send_proxy"

end_describe

ptyunit_test_summary
