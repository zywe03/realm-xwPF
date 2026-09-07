#!/usr/bin/env bash
# Unit tests for the config export/import round trip in lib/rules.sh:
# export_config_package, export_config_with_view,
# validate_config_package_content, and import_config_package.
# export_config_package's destination directory is hardcoded to
# /usr/local/bin (not overridable via RULES_DIR-style injection), so these
# tests write a real, uniquely-timestamped tar.gz there and clean it up
# afterward; import_config_package restarts the real (mocked) systemd
# service, so this runs against xwpf_reset_mock_systemd_state.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"
source "$XWPF_REPO_ROOT/lib/server.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

INIT_SYSTEM="systemd"

_make_relay_rule() {
    local id="$1" port="$2"
    cat > "${RULES_DIR}/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=relay-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
BALANCE_MODE=off
TARGET_STATES=
WEIGHTS=
PROXY_MODE=off
EOF
}

_setup() {
    xwpf_lock_realm_config
    xwpf_reset_mock_systemd_state
    RULES_DIR="$(mktemp -d /tmp/xwpftestrules.XXXXXX)"
    mkdir -p /etc/realm
    rm -f "$MANAGER_CONF"
}

_teardown() {
    [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"
    rm -f "$MANAGER_CONF" /etc/realm/config.json /etc/systemd/system/realm.service
    rm -f /usr/local/bin/xwPF_config_*.tar.gz
    xwpf_unlock_realm_config
}

describe "export_config_package" _setup _teardown

test_that "reports nothing to export when there are no rules and no manager.conf"
out=$(export_config_package <<< "")
assert_contains "$out" "没有可导出的配置数据"

test_that "cancels on a non-y confirmation"
_make_relay_rule 1 8001
out=$(export_config_package <<< "n")
assert_contains "$out" "已取消导出操作"
assert_eq "0" "$(ls /usr/local/bin/xwPF_config_*.tar.gz 2>/dev/null | wc -l)"

test_that "on y confirmation, bundles the rule files and manager.conf into a tar.gz under /usr/local/bin"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
echo "MANAGER_STATE=test" > "$MANAGER_CONF"
out=$(export_config_package <<< "y")
assert_contains "$out" "配置包导出成功"
export_path=$(ls /usr/local/bin/xwPF_config_*.tar.gz 2>/dev/null | head -1)
assert_true test -n "$export_path"
extract_dir="$(mktemp -d)"
tar -xzf "$export_path" -C "$extract_dir"
assert_true test -f "${extract_dir}/xwPF_config/metadata.txt"
assert_eq "2" "$(ls "${extract_dir}/xwPF_config/rules"/rule-*.conf | wc -l)"
assert_true test -f "${extract_dir}/xwPF_config/manager.conf"
rm -rf "$extract_dir"

test_that "includes the health status file and MPTCP sysctl config when present"
_make_relay_rule 1 8001
HEALTH_STATUS_FILE="$(mktemp /tmp/xwpf-health.XXXXXX)"
echo "1|127.0.0.1:9000|healthy|0|3|2024-01-01|" > "$HEALTH_STATUS_FILE"
mkdir -p /etc/sysctl.d
echo "net.mptcp.enabled=1" > /etc/sysctl.d/90-enable-MPTCP.conf
out=$(export_config_package <<< "y")
export_path=$(ls /usr/local/bin/xwPF_config_*.tar.gz 2>/dev/null | head -1)
extract_dir="$(mktemp -d)"
tar -xzf "$export_path" -C "$extract_dir"
assert_true test -f "${extract_dir}/xwPF_config/health_status.conf"
assert_true test -f "${extract_dir}/xwPF_config/90-enable-MPTCP.conf"
rm -rf "$extract_dir"
rm -f /etc/sysctl.d/90-enable-MPTCP.conf "$HEALTH_STATUS_FILE"
unset HEALTH_STATUS_FILE

end_describe

describe "export_config_with_view" _setup _teardown

test_that "shows 'file does not exist' when CONFIG_PATH is missing, then returns on choice 0"
rm -f "$CONFIG_PATH"
out=$(export_config_with_view <<< "0")
assert_contains "$out" "配置文件不存在"

test_that "shows the config file contents when CONFIG_PATH exists"
echo '{"test": true}' > "$CONFIG_PATH"
out=$(export_config_with_view <<< "0")
assert_contains "$out" '"test": true'
rm -f "$CONFIG_PATH"

test_that "an invalid export choice is rejected"
out=$(export_config_with_view <<< "$(printf '9\n\n')")
assert_contains "$out" "无效选择"

test_that "choice 1 dispatches into export_config_package"
_make_relay_rule 1 8001
out=$(export_config_with_view <<< "$(printf '1\nn\n')")
assert_contains "$out" "导出配置包"

end_describe

describe "validate_config_package_content"

test_that "returns failure for a corrupt/non-tar file"
bad_file="$(mktemp)"
echo "not a tarball" > "$bad_file"
assert_false validate_config_package_content "$bad_file"
rm -f "$bad_file"

test_that "returns failure for a tar that has no metadata.txt"
work_dir="$(mktemp -d)"
mkdir -p "${work_dir}/somepkg"
touch "${work_dir}/somepkg/nothing.txt"
tar_file="$(mktemp --suffix=.tar.gz)"
tar -czf "$tar_file" -C "$work_dir" somepkg
assert_false validate_config_package_content "$tar_file"
rm -rf "$work_dir" "$tar_file"

test_that "returns the extracted config dir path for a valid package"
work_dir="$(mktemp -d)"
mkdir -p "${work_dir}/xwPF_config"
touch "${work_dir}/xwPF_config/metadata.txt"
tar_file="$(mktemp --suffix=.tar.gz)"
tar -czf "$tar_file" -C "$work_dir" xwPF_config
result=$(validate_config_package_content "$tar_file")
rc=$?
assert_eq "0" "$rc"
assert_contains "$result" "xwPF_config"
rm -rf "$work_dir" "$tar_file" "$(dirname "$result")"

end_describe

describe "import_config_package" _setup _teardown

test_that "cancels immediately on an empty package path"
out=$(import_config_package <<< "")
assert_contains "$out" "已取消操作"

test_that "reports a missing file for a nonexistent path"
out=$(import_config_package <<< "/tmp/does-not-exist-xwpf.tar.gz")
assert_contains "$out" "文件不存在"

test_that "reports an invalid package for a corrupt file"
bad_file="$(mktemp --suffix=.tar.gz)"
echo "not a tarball" > "$bad_file"
out=$(import_config_package <<< "$bad_file")
assert_contains "$out" "无效的配置包文件"
rm -f "$bad_file"

test_that "cancels on a non-y confirmation, leaving current rules untouched"
_make_relay_rule 1 8001
export_out=$(export_config_package <<< "y")
export_path=$(ls /usr/local/bin/xwPF_config_*.tar.gz 2>/dev/null | head -1)
rm -f "${RULES_DIR}/rule-1.conf"
_make_relay_rule 9 9009
out=$(import_config_package <<< "$(printf '%s\nn\n' "$export_path")")
assert_contains "$out" "已取消导入操作"
assert_true test -f "${RULES_DIR}/rule-9.conf"

test_that "on y confirmation, restores the exported rules and restarts the service"
_make_relay_rule 1 8001
_make_relay_rule 2 8002
export_out=$(export_config_package <<< "y")
export_path=$(ls /usr/local/bin/xwPF_config_*.tar.gz 2>/dev/null | head -1)
rm -f "${RULES_DIR}"/rule-*.conf
_make_relay_rule 9 9009
xwpf_seed_realm_service_file
out=$(import_config_package <<< "$(printf '%s\ny\n' "$export_path")")
assert_contains "$out" "配置导入成功，共恢复 2 个规则"
assert_true test -f "${RULES_DIR}/rule-1.conf"
assert_true test -f "${RULES_DIR}/rule-2.conf"
assert_false test -f "${RULES_DIR}/rule-9.conf"

test_that "restores manager.conf, health status file, and MPTCP sysctl config on import"
_make_relay_rule 1 8001
echo "MANAGER_STATE=test" > "$MANAGER_CONF"
HEALTH_STATUS_FILE="$(mktemp /tmp/xwpf-health.XXXXXX)"
echo "1|127.0.0.1:9000|healthy|0|3|2024-01-01|" > "$HEALTH_STATUS_FILE"
mkdir -p /etc/sysctl.d
echo "net.mptcp.enabled=1" > /etc/sysctl.d/90-enable-MPTCP.conf
export_config_package <<< "y" >/dev/null
export_path=$(ls /usr/local/bin/xwPF_config_*.tar.gz 2>/dev/null | head -1)
rm -f "$MANAGER_CONF" "$HEALTH_STATUS_FILE" /etc/sysctl.d/90-enable-MPTCP.conf
xwpf_seed_realm_service_file
out=$(import_config_package <<< "$(printf '%s\ny\n' "$export_path")")
assert_true test -f "$MANAGER_CONF"
assert_true test -f "$HEALTH_STATUS_FILE"
assert_true test -f /etc/sysctl.d/90-enable-MPTCP.conf
rm -f /etc/sysctl.d/90-enable-MPTCP.conf "$HEALTH_STATUS_FILE"
unset HEALTH_STATUS_FILE

test_that "restores MPTCP endpoint configuration when the package includes it"
work_dir="$(mktemp -d)"
mkdir -p "${work_dir}/xwPF_config/rules"
cat > "${work_dir}/xwPF_config/metadata.txt" <<EOF
EXPORT_TIME="2024-01-01 00:00:00"
SCRIPT_VERSION="1.0"
RULES_COUNT=1
PACKAGE_VERSION=1.0
HAS_MANAGER_CONF=false
EOF
cat > "${work_dir}/xwPF_config/rules/rule-1.conf" <<EOF
RULE_ID=1
RULE_NAME=relay-1
LISTEN_PORT=8001
RULE_ROLE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
ENABLED=true
SECURITY_LEVEL=standard
BALANCE_MODE=off
TARGET_STATES=
WEIGHTS=
PROXY_MODE=off
EOF
cat > "${work_dir}/xwPF_config/mptcp_endpoints.conf" <<EOF
10.0.0.5 dev eth0 subflow fullmesh
10.0.0.6 dev eth1 subflow backup
10.0.0.7 dev eth2 signal
EOF
tar_file="$(mktemp --suffix=.tar.gz)"
tar -czf "$tar_file" -C "$work_dir" xwPF_config
rm -rf "$work_dir"
xwpf_seed_realm_service_file
out=$(import_config_package <<< "$(printf '%s\ny\n' "$tar_file")")
assert_contains "$out" "MPTCP端点配置"
assert_true test -f "${RULES_DIR}/rule-1.conf"
rm -f "$tar_file"

test_that "reports import failure when the package contains no rules"
work_dir="$(mktemp -d)"
mkdir -p "${work_dir}/xwPF_config"
cat > "${work_dir}/xwPF_config/metadata.txt" <<EOF
EXPORT_TIME="2024-01-01 00:00:00"
SCRIPT_VERSION="1.0"
RULES_COUNT=0
PACKAGE_VERSION=1.0
HAS_MANAGER_CONF=false
EOF
tar_file="$(mktemp --suffix=.tar.gz)"
tar -czf "$tar_file" -C "$work_dir" xwPF_config
rm -rf "$work_dir"
out=$(import_config_package <<< "$(printf '%s\ny\n' "$tar_file")")
assert_contains "$out" "配置导入失败"
rm -f "$tar_file"

end_describe

ptyunit_test_summary
