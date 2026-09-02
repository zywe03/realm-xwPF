#!/usr/bin/env bash
# Unit tests for the higher-level service-management wrappers in lib/realm.sh
# that aren't already exercised end-to-end by the integration suite:
# service_stop/service_restart's failure paths, generate_service_file's
# OpenRC branch, and generate_realm_config's role-2 (server) rule-summary
# display branch.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"

INIT_SYSTEM="systemd"

_setup() { xwpf_reset_mock_systemd_state; }

describe "service_stop" _setup

test_that "reports success when svc_stop succeeds"
touch "$XWPF_MOCK_STATE_DIR/realm.active"
out=$(service_stop 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "Realm 服务已停止"

test_that "reports failure when svc_stop fails"
out=$(XWPF_MOCK_SYSTEMCTL_STOP_FAIL=1 service_stop 2>&1)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "Realm 服务停止失败"

end_describe

_service_restart_setup() {
    # generate_realm_config (called inside service_restart) writes real
    # /etc/realm/config.json; serialize against other unit test files
    # touching that same real path in parallel.
    xwpf_lock_realm_config
    xwpf_reset_mock_systemd_state
}
_service_restart_teardown() {
    rm -f /etc/realm/config.json
    xwpf_unlock_realm_config
}

describe "service_restart" _service_restart_setup _service_restart_teardown

test_that "reports success when svc_restart succeeds against a seeded unit"
xwpf_seed_realm_service_file
RULES_DIR="$(mktemp -d /tmp/xwpf-svcmgmt-rules.XXXXXX)"
out=$(service_restart 2>&1)
rc=$?
rm -rf "$RULES_DIR"
rm -f /etc/systemd/system/realm.service
assert_eq "0" "$rc"
assert_contains "$out" "Realm 服务重启成功"

test_that "reports failure and shows status detail when svc_restart fails"
RULES_DIR="$(mktemp -d /tmp/xwpf-svcmgmt-rules.XXXXXX)"
out=$(XWPF_MOCK_SYSTEMCTL_RESTART_FAIL=1 service_restart 2>&1)
rc=$?
rm -rf "$RULES_DIR"
assert_eq "1" "$rc"
assert_contains "$out" "Realm 服务重启失败"

end_describe

describe "generate_service_file"

test_that "generates a systemd unit by default"
out=$(generate_service_file 2>&1)
rm -f /etc/systemd/system/realm.service
assert_contains "$out" "systemd 服务文件已生成"

test_that "generates an OpenRC init script when INIT_SYSTEM=openrc"
if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" = "1" ]; then
    out=$(INIT_SYSTEM="openrc" generate_service_file 2>&1)
    rc_ok=$?
    file_exists=false
    [ -f /etc/init.d/realm ] && file_exists=true
    rm -f /etc/init.d/realm
    assert_eq "0" "$rc_ok"
    assert_contains "$out" "OpenRC 服务文件已生成"
    assert_true test "$file_exists" = "true"
fi

end_describe

_realm_config_setup() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    xwpf_lock_realm_config
    RULES_DIR="$(mktemp -d /tmp/xwpf-svcmgmt-rules.XXXXXX)"
}
_realm_config_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f /etc/realm/config.json
    xwpf_unlock_realm_config
}

_first_install_setup() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    xwpf_lock_realm_config
    xwpf_reset_mock_systemd_state
}
_first_install_teardown() {
    rm -f /etc/realm/config.json /etc/systemd/system/realm.service
    xwpf_unlock_realm_config
}

describe "restart_realm_service: fresh-install branch (no prior service, not an update)" _first_install_setup _first_install_teardown

test_that "falls straight through to start_empty_service when neither was_running nor is_update is set"
# Only assert on captured output here, not on /etc/realm/config.json's
# existence: that's a real path other unit test files also write to and
# clean up in parallel, so checking for it after the fact is racy.
out=$(restart_realm_service false false 2>&1)
assert_contains "$out" "正在初始化配置以完成安装"

end_describe

describe "generate_realm_config: role-2 (server) rule summary display" _realm_config_setup _realm_config_teardown

test_that "shows the FORWARD_TARGET-based summary line for a role-2 rule"
cat > "${RULES_DIR}/rule-1.conf" <<'EOF'
RULE_ID=1
RULE_NAME=server-rule
LISTEN_PORT=8020
RULE_ROLE=2
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
FORWARD_TARGET=127.0.0.1:9200
ENABLED=true
SECURITY_LEVEL=standard
EOF
out=$(generate_realm_config 2>&1)
assert_contains "$out" "server-rule"
assert_contains "$out" "9200"

end_describe

ptyunit_test_summary
