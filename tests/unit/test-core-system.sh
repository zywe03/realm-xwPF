#!/usr/bin/env bash
# Unit tests for system-detection, dependency-check, and network/port
# helpers in lib/core.sh that weren't already covered by
# test-core-validators.sh. Functions that call `exit` on their failure path
# (check_dependencies "check", check_port_usage's decline branch) are always
# invoked through a `$(...)` command substitution, which forks its own
# subshell — that exit only ends the substitution, never this test process.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"

describe "check_root"

test_that "exits 1 with an error message when not run as root"
# check_root calls exit directly, so it must run in a child process (not
# this test process) to observe its exit code. runuser invokes the given
# command directly rather than the target user's login shell, so it works
# even though nobody's shell is /usr/sbin/nologin. --preserve-environment
# alone isn't enough for coverage tracing here: unlike integration tests
# (driven via pty_run.py, which sets BASH_ENV), the unit-test runner
# enables tracing with plain, unexported BASH_XTRACEFD/PS4 shell variables,
# so there's nothing in the environment for --preserve-environment to
# actually preserve into the new process tree. xwpf_traced_env writes its
# own BASH_ENV script (same recipe pty_run.py uses) so the runuser child
# gets traced too; xwpf_traced_env_cleanup removes it again afterward.
xwpf_traced_env
out=$(runuser -u nobody --preserve-environment -- bash -c "source '$XWPF_REPO_ROOT/lib/core.sh'; check_root" 2>&1)
rc=$?
xwpf_traced_env_cleanup
assert_eq "1" "$rc"
assert_contains "$out" "需要 root 权限"

end_describe

describe "detect_system" xwpf_backup_os_release xwpf_restore_os_release

test_that "identifies this container as Debian/apt-get/systemd"
detect_system
assert_eq "debian" "$DISTRO"
assert_eq "apt-get" "$PKG_MGR"
assert_eq "systemd" "$INIT_SYSTEM"

test_that "exits 1 when /etc/os-release is missing"
rm -f /etc/os-release
out=$(detect_system 2>&1)
rc=$?
xwpf_restore_os_release
assert_eq "1" "$rc"
assert_contains "$out" "缺少 /etc/os-release"

test_that "recognizes alpine as its own distro"
printf 'ID=alpine\nNAME=Alpine\nVERSION_ID=3.19\n' > /etc/os-release
detect_system
assert_eq "alpine" "$DISTRO"

test_that "recognizes centos-family IDs as the centos distro"
printf 'ID=rocky\nNAME=Rocky\nVERSION_ID=9\n' > /etc/os-release
detect_system
assert_eq "centos" "$DISTRO"

test_that "exits 1 for an unsupported distro ID"
printf 'ID=gentoo\nNAME=Gentoo\nVERSION_ID=1\n' > /etc/os-release
out=$(detect_system 2>&1)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "不支持的系统: gentoo"

test_that "exits 1 when no supported package manager is on PATH"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
out=$(PATH="$stub_bin" detect_system 2>&1)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "未找到支持的包管理器"
rm -rf "$stub_bin"

test_that "exits 1 when no supported init system is on PATH"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
ln -s "$(command -v apt-get)" "$stub_bin/apt-get"
out=$(PATH="$stub_bin" detect_system 2>&1)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "未找到支持的 init 系统"
rm -rf "$stub_bin"

end_describe

describe "_pkg_install"

test_that "dispatches to apt-get and reports success/failure per tool"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
cat > "$stub_bin/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stub_bin/apt-get"
ln -s "$(command -v jq)" "$stub_bin/jq"
PKG_MGR="apt-get"
out=$(PATH="$stub_bin" _pkg_install jq notreallyatool 2>&1)
assert_contains "$out" "jq 安装成功"
assert_contains "$out" "notreallyatool 安装失败"
rm -rf "$stub_bin"

test_that "dispatches to apk"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
cat > "$stub_bin/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stub_bin/apk"
ln -s "$(command -v jq)" "$stub_bin/jq"
PKG_MGR="apk"
out=$(PATH="$stub_bin" _pkg_install jq 2>&1)
assert_contains "$out" "jq 安装成功"
rm -rf "$stub_bin"

test_that "dispatches to yum/dnf via \$PKG_MGR"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
cat > "$stub_bin/dnf" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$stub_bin/dnf"
ln -s "$(command -v jq)" "$stub_bin/jq"
PKG_MGR="dnf"
out=$(PATH="$stub_bin" _pkg_install jq 2>&1)
assert_contains "$out" "jq 安装成功"
rm -rf "$stub_bin"
unset PKG_MGR

end_describe

describe "manage_dependencies / check_dependencies"

test_that "check mode prints nothing when all required tools are present"
# Note: check_dependencies has no explicit `return 0` on this path — its
# actual exit status here is 1 (the value of the final `[ "$mode" = "install" ]`
# test), a latent quirk harmless in practice because every real call site in
# lib/ui.sh invokes it as a bare statement and never inspects the return code.
assert_eq "" "$(check_dependencies)"

test_that "check mode reports the missing tool and exits 1"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
for t in curl wget tar grep cut bc; do ln -s "$(command -v "$t")" "$stub_bin/$t"; done
out=$(PATH="$stub_bin" check_dependencies 2>&1)
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "jq"
rm -rf "$stub_bin"

test_that "install mode reports missing tools and attempts to install them"
stub_bin="$(mktemp -d /tmp/xwpf-stubbin.XXXXXX)"
for t in curl wget tar grep cut bc; do ln -s "$(command -v "$t")" "$stub_bin/$t"; done
out=$(PATH="$stub_bin" manage_dependencies "install" 2>&1)
assert_contains "$out" "需要安装以下工具"
assert_contains "$out" "jq"
rm -rf "$stub_bin"

end_describe

describe "get_public_ip"

test_that "returns empty when both mocked upstream endpoints are unreachable (ipv4)"
assert_eq "" "$(get_public_ip ipv4)"

test_that "returns empty when both mocked upstream endpoints are unreachable (ipv6)"
assert_eq "" "$(get_public_ip ipv6)"

test_that "returns the IP from ipinfo.io when it resolves"
assert_eq "203.0.113.5" "$(XWPF_MOCK_PUBLIC_IP=203.0.113.5 get_public_ip ipv4)"

test_that "falls back to the cloudflare trace endpoint when ipinfo.io fails"
assert_eq "203.0.113.9" "$(XWPF_MOCK_PUBLIC_IP=203.0.113.9 XWPF_MOCK_PUBLIC_IP_SKIP_IPINFO=1 get_public_ip ipv4)"

end_describe

describe "validate_single_address"

test_that "accepts a bare IPv4 address"
assert_true validate_single_address "10.0.0.1"

test_that "accepts a domain name"
assert_true validate_single_address "example.com"

test_that "accepts localhost"
assert_true validate_single_address "localhost"

test_that "rejects a bare word with no TLD"
assert_false validate_single_address "notadomain"

end_describe

_setup_rules_dir() { RULES_DIR="$(mktemp -d /tmp/xwpf-initfield.XXXXXX)"; }
_teardown_rules_dir() { [ -n "${RULES_DIR:-}" ] && rm -rf "$RULES_DIR"; }

describe "init_rule_field" _setup_rules_dir _teardown_rules_dir

test_that "appends the field with its default when missing from a rule file"
cat > "$RULES_DIR/rule-1.conf" <<'EOF'
RULE_ID=1
EOF
init_rule_field "SECURITY_LEVEL" "standard"
assert_contains "$(cat "$RULES_DIR/rule-1.conf")" 'SECURITY_LEVEL="standard"'

test_that "leaves an existing field untouched"
cat > "$RULES_DIR/rule-2.conf" <<'EOF'
RULE_ID=2
SECURITY_LEVEL="custom"
EOF
init_rule_field "SECURITY_LEVEL" "standard"
assert_eq "1" "$(grep -c '^SECURITY_LEVEL=' "$RULES_DIR/rule-2.conf")"
assert_contains "$(cat "$RULES_DIR/rule-2.conf")" 'SECURITY_LEVEL="custom"'

end_describe

describe "init_rule_field: missing RULES_DIR"

test_that "is a no-op when RULES_DIR doesn't exist"
RULES_DIR="/tmp/xwpf-does-not-exist-$$"
assert_true init_rule_field "FOO" "bar"

end_describe

describe "restart_and_confirm"

test_that "batch mode short-circuits without calling service_restart"
service_restart() { echo "SHOULD NOT BE CALLED"; return 1; }
out=$(restart_and_confirm "测试" "batch")
rc=$?
assert_eq "0" "$rc"
assert_eq "" "$out"
unset -f service_restart

test_that "non-batch mode returns 0 and prints success when service_restart succeeds"
service_restart() { return 0; }
out=$(restart_and_confirm "测试" "")
assert_eq "0" "$?"
assert_contains "$out" "成功"
unset -f service_restart

test_that "non-batch mode returns 1 when service_restart fails"
service_restart() { return 1; }
assert_false restart_and_confirm "测试" ""
unset -f service_restart

end_describe

describe "check_port_usage"

test_that "returns 0 silently when the port is free"
out=$(check_port_usage "47999" 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_eq "" "$out"

test_that "reports success without prompting when realm itself already owns the port"
# ss reports the *kernel comm* of the listening process, which for a direct
# (non-shebang) ELF exec is the exec'd file's basename regardless of argv[0]
# — so copying python3 to a file literally named "realm" and exec'ing that
# is what makes ss -p's users:(("realm",...)) match real, not simulated.
realm_bin="$(mktemp -u /tmp/realm.XXXXXX)"
cp "$(command -v python3)" "$realm_bin"
"$realm_bin" -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48005))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
out=$(check_port_usage "48005" 2>&1)
rc=$?
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
rm -f "$realm_bin"
assert_eq "1" "$rc"
assert_contains "$out" "支持单端口中转多服务端配置"

test_that "prompts and cancels when the port is occupied by an unrelated process"
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48001))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
out=$(echo "n" | check_port_usage "48001" 2>&1)
rc=$?
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
assert_eq "1" "$rc"
assert_contains "$out" "已被其他服务占用"
assert_contains "$out" "配置已取消"

test_that "continues when the user confirms"
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48002))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
out=$(echo "y" | check_port_usage "48002" 2>&1)
rc=$?
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null
assert_eq "0" "$rc"
assert_contains "$out" "占用进程信息"

end_describe

describe "check_connectivity"

test_that "returns 1 immediately when the target is empty"
assert_false check_connectivity "" "80"

test_that "returns 1 immediately when the port is empty"
assert_false check_connectivity "127.0.0.1" ""

test_that "succeeds against a real open local port"
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 48010))
s.listen(1)
time.sleep(5)
" &
listener_pid=$!
sleep 0.3
assert_true check_connectivity "127.0.0.1" "48010" "2"
kill "$listener_pid" 2>/dev/null
wait "$listener_pid" 2>/dev/null

test_that "fails against a closed local port"
assert_false check_connectivity "127.0.0.1" "1" "2"

end_describe

ptyunit_test_summary
