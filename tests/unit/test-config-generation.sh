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

end_describe

ptyunit_test_summary
