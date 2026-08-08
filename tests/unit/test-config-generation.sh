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

describe "generate_endpoints_from_rules" _setup _teardown

test_that "produces no endpoints when the rules dir is empty"
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
    mkdir -p /etc/realm
}
_teardown_real_config() {
    rm -f /etc/realm/config.json
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
