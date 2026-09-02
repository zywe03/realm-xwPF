#!/usr/bin/env bash
# Unit tests for rule-file bookkeeping in lib/rules.sh: ID generation,
# numeric-order listing, reading fields back out of a rule-N.conf file, and
# gap-closing reorder. These functions all read/write through the $RULES_DIR
# global, so tests point it at a throwaway temp directory rather than the
# real /etc/realm/rules.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"

# Write a minimal rule-N.conf fixture. read_rule_file() just `source`s it, so
# it only needs to be valid bash assignments.
_make_rule_file() {
    local id="$1" port="$2" role="${3:-1}"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=test-rule-${id}
LISTEN_PORT=${port}
RULE_ROLE=${role}
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
EOF
}

_setup_rules_dir() {
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
}

_teardown_rules_dir() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
}

describe "generate_rule_id" _setup_rules_dir _teardown_rules_dir

test_that "starts at 1 with no existing rules"
assert_eq "1" "$(generate_rule_id)"

test_that "returns max existing ID + 1"
_make_rule_file 1 8001
_make_rule_file 2 8002
assert_eq "3" "$(generate_rule_id)"

test_that "is based on the highest ID, not the count of files"
_make_rule_file 5 8005
assert_eq "6" "$(generate_rule_id)"

end_describe

describe "get_sorted_rule_files" _setup_rules_dir _teardown_rules_dir

test_that "orders by numeric ID, not lexical glob order"
_make_rule_file 2 8002
_make_rule_file 10 8010
_make_rule_file 1 8001
result="$(get_sorted_rule_files)"
assert_eq "${RULES_DIR}/rule-1.conf
${RULES_DIR}/rule-2.conf
${RULES_DIR}/rule-10.conf" "$result"

end_describe

describe "read_rule_file" _setup_rules_dir _teardown_rules_dir

test_that "populates fields from the rule file and returns success"
_make_rule_file 1 8001 "2"
assert_true read_rule_file "${RULES_DIR}/rule-1.conf"
assert_eq "8001" "$LISTEN_PORT"
assert_eq "2" "$RULE_ROLE"
assert_eq "test-rule-1" "$RULE_NAME"

test_that "defaults MPTCP_MODE/PROXY_MODE to off when absent from the file"
assert_eq "off" "$MPTCP_MODE"
assert_eq "off" "$PROXY_MODE"

test_that "fails for a missing file"
assert_false read_rule_file "${RULES_DIR}/rule-999.conf"

end_describe

describe "reorder_rule_ids" _setup_rules_dir _teardown_rules_dir

test_that "closes gaps and renumbers sequentially by port"
_make_rule_file 1 8001
_make_rule_file 5 8005
reorder_rule_ids
result="$(get_sorted_rule_files)"
assert_eq "${RULES_DIR}/rule-1.conf
${RULES_DIR}/rule-2.conf" "$result"
read_rule_file "${RULES_DIR}/rule-2.conf"
assert_eq "8005" "$LISTEN_PORT"

test_that "is a no-op when IDs are already sequential"
_setup_rules_dir
_make_rule_file 1 8001
_make_rule_file 2 8002
assert_true reorder_rule_ids

end_describe

ptyunit_test_summary
