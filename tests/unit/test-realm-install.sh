#!/usr/bin/env bash
# Unit tests for lib/realm.sh's install_realm()/compare_and_ask_update(): the
# already-installed/version-compare/update-prompt branches, and the
# not-installed download-and-extract paths, that test-install-offline.sh's
# single fresh-offline-install run never exercises. install_realm calls
# `exit` directly on several failure paths, so every call here that can hit
# one of those runs in a subshell to avoid killing the test process.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/rules.sh"
source "$XWPF_REPO_ROOT/lib/realm.sh"

_setup() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /usr/local/bin: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    # install_realm's reinstall/update flows write real /etc/realm/config.json
    # (via restart_realm_service -> start_empty_service); serialize against
    # other unit test files touching that same real path in parallel.
    xwpf_lock_realm_config
    rm -f /usr/local/bin/realm
}
_teardown() {
    rm -f /usr/local/bin/realm
    # A successful install/reinstall always calls restart_realm_service(...,
    # true), which falls back to start_empty_service() whenever no unit file
    # was seeded — that writes real /etc/realm/config.json. Clean that up
    # (but only config.json, not the whole /etc/realm tree: other unit test
    # files run in parallel and keep their own fixtures under
    # /etc/realm/health and /etc/realm/rules). Deliberately NOT deleting the
    # generated /etc/systemd/system/realm.service here: it's a shared real
    # path other unit test files (test-realm-service-mgmt.sh) rely on being
    # present, and none of this file's own tests depend on its absence —
    # each test either seeds/removes it itself or never reaches a restart
    # call at all.
    rm -f /etc/realm/config.json
    xwpf_reset_mock_systemd_state
    [ -n "${_tarball:-}" ] && rm -rf "$(dirname "$_tarball")"
    _tarball=""
    xwpf_unlock_realm_config
}

describe "install_realm: already-installed branches" _setup _teardown

test_that "reinstalls when the existing binary fails --help (looks corrupted)"
printf '#!/bin/sh\nexit 1\n' > /usr/local/bin/realm
chmod +x /usr/local/bin/realm
_tarball="$(xwpf_build_fake_realm_tarball)"
out=$(install_realm <<< "$_tarball")
assert_contains "$out" "可能已损坏"
assert_contains "$out" "realm 安装成功"

test_that "does nothing further when the installed version already matches the latest"
xwpf_seed_fake_realm_binary
out=$(install_realm </dev/null 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "当前版本已是最新版本"
assert_not_contains "$out" "正在解压安装"

test_that "prompts to update on a version mismatch, and leaves the install alone on decline"
xwpf_seed_fake_realm_binary
get_latest_realm_version() { echo "v9.9.9"; }
out=$(install_realm <<< "n")
rc=$?
source "$XWPF_REPO_ROOT/lib/realm.sh"
assert_eq "0" "$rc"
assert_contains "$out" "发现新版本"
assert_contains "$out" "使用现有的 realm 安装"
assert_not_contains "$out" "正在解压安装"

test_that "accepts a prompted update and reinstalls from the given local package"
xwpf_seed_fake_realm_binary
get_latest_realm_version() { echo "v9.9.9"; }
_tarball="$(xwpf_build_fake_realm_tarball)"
out=$(install_realm <<< "$(printf 'y\n%s\n' "$_tarball")")
source "$XWPF_REPO_ROOT/lib/realm.sh"
assert_contains "$out" "将更新到最新版本"
assert_contains "$out" "realm 安装成功"

test_that "stops a running service before reinstalling, then restarts it"
xwpf_seed_fake_realm_binary
touch "$XWPF_MOCK_STATE_DIR/realm.active"
get_latest_realm_version() { echo "v9.9.9"; }
_tarball="$(xwpf_build_fake_realm_tarball)"
out=$(install_realm <<< "$(printf 'y\n%s\n' "$_tarball")" 2>&1)
source "$XWPF_REPO_ROOT/lib/realm.sh"
assert_contains "$out" "检测到realm服务正在运行"
assert_contains "$out" "realm服务已停止"
assert_contains "$out" "realm 安装成功"

test_that "falls back to the -v flag when --version isn't supported"
cat > /usr/local/bin/realm <<'EOF'
#!/bin/sh
case "${1:-}" in
    --help) echo "mock realm"; exit 0 ;;
    --version) exit 1 ;;
    -v) echo "realm 2.9.4 (via -v)"; exit 0 ;;
    *) exec sleep infinity ;;
esac
EOF
chmod +x /usr/local/bin/realm
out=$(install_realm </dev/null 2>&1)
assert_contains "$out" "via -v"
assert_contains "$out" "当前版本已是最新版本"

test_that "reports a version-check failure when neither --version nor -v work"
cat > /usr/local/bin/realm <<'EOF'
#!/bin/sh
case "${1:-}" in
    --help) echo "mock realm"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x /usr/local/bin/realm
get_latest_realm_version() { echo "v9.9.9"; }
out=$(install_realm <<< "n")
source "$XWPF_REPO_ROOT/lib/realm.sh"
assert_contains "$out" "版本检查失败"
assert_contains "$out" "架构不匹配"

test_that "aborts cleanly when the running service can't be safely stopped for an update"
xwpf_seed_fake_realm_binary
xwpf_seed_realm_service_file
mkdir -p "$XWPF_MOCK_STATE_DIR"
touch "$XWPF_MOCK_STATE_DIR/realm.active"
get_latest_realm_version() { echo "v9.9.9"; }
_tarball="$(xwpf_build_fake_realm_tarball)"
out=$(XWPF_MOCK_SYSTEMCTL_STOP_FAIL=1 install_realm <<< "$(printf 'y\n%s\n' "$_tarball")" 2>&1)
rc=$?
source "$XWPF_REPO_ROOT/lib/realm.sh"
rm -f /etc/systemd/system/realm.service
assert_eq "1" "$rc"
assert_contains "$out" "无法安全更新"

end_describe

describe "install_realm: not-installed / download branches" _setup _teardown

test_that "falls through to the online-download path and fails against the mocked-offline curl"
out=$( (install_realm <<< "") 2>&1 )
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "未检测到 realm 安装"
assert_contains "$out" "下载失败"

test_that "reports a missing local file, then falls back to the same failing online download"
out=$( (install_realm <<< "/no/such/file.tar.gz") 2>&1 )
rc=$?
assert_eq "1" "$rc"
assert_contains "$out" "文件不存在，继续在线下载"
assert_contains "$out" "下载失败"

test_that "reports an error for a CPU architecture with no supported release build"
_stub_bin="$(mktemp -d /tmp/xwpf-unamestub.XXXXXX)"
cat > "$_stub_bin/uname" <<'EOF'
#!/bin/sh
echo "sparc64"
EOF
chmod +x "$_stub_bin/uname"
out=$( (PATH="$_stub_bin:$PATH" install_realm <<< "") 2>&1 )
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "不支持的CPU架构: sparc64"

test_that "maps x86_64 to the x86_64-unknown-linux-gnu release asset name"
_stub_bin="$(mktemp -d /tmp/xwpf-unamestub.XXXXXX)"
printf '#!/bin/sh\necho "x86_64"\n' > "$_stub_bin/uname"
chmod +x "$_stub_bin/uname"
out=$( (PATH="$_stub_bin:$PATH" install_realm <<< "") 2>&1 )
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "realm-x86_64-unknown-linux-gnu.tar.gz"

test_that "maps aarch64 to the aarch64-unknown-linux-gnu release asset name"
_stub_bin="$(mktemp -d /tmp/xwpf-unamestub.XXXXXX)"
printf '#!/bin/sh\necho "aarch64"\n' > "$_stub_bin/uname"
chmod +x "$_stub_bin/uname"
out=$( (PATH="$_stub_bin:$PATH" install_realm <<< "") 2>&1 )
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "realm-aarch64-unknown-linux-gnu.tar.gz"

test_that "maps armv7l to the armv7-unknown-linux-gnueabihf release asset name"
_stub_bin="$(mktemp -d /tmp/xwpf-unamestub.XXXXXX)"
printf '#!/bin/sh\necho "armv7l"\n' > "$_stub_bin/uname"
chmod +x "$_stub_bin/uname"
out=$( (PATH="$_stub_bin:$PATH" install_realm <<< "") 2>&1 )
rc=$?
rm -rf "$_stub_bin"
assert_eq "1" "$rc"
assert_contains "$out" "realm-armv7-unknown-linux-gnueabihf.tar.gz"

test_that "uses the musl asset suffix when /etc/alpine-release is present"
if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" = "1" ]; then
    touch /etc/alpine-release
    out=$( (install_realm <<< "") 2>&1 )
    rc=$?
    rm -f /etc/alpine-release
    assert_eq "1" "$rc"
    assert_contains "$out" "-musl.tar.gz"
fi

test_that "auto-downloads and installs successfully when curl serves the release tarball"
_tarball="$(xwpf_build_fake_realm_tarball)"
out=$(XWPF_MOCK_REALM_DOWNLOAD="$_tarball" install_realm <<< "" 2>&1)
rc=$?
assert_eq "0" "$rc"
assert_contains "$out" "下载成功"
assert_contains "$out" "realm 安装成功"
assert_file_exists "/usr/local/bin/realm"

test_that "fails installation cleanly when the local package isn't a real tar archive"
_bad_file="$(mktemp /tmp/xwpf-notarball.XXXXXX)"
echo "not actually a tarball" > "$_bad_file"
out=$( (install_realm <<< "$_bad_file") 2>&1 )
rc=$?
rm -f "$_bad_file"
assert_eq "1" "$rc"
assert_contains "$out" "安装失败"

end_describe

describe "compare_and_ask_update"

test_that "treats an unparseable current version as v0.0.0, so any real version looks newer"
out=$(compare_and_ask_update "unknown build" "v1.0.0" <<< "n")
assert_contains "$out" "v0.0.0 → v1.0.0"

test_that "adds a missing v prefix to both versions before comparing"
assert_false compare_and_ask_update "2.9.4" "2.9.4"

end_describe

ptyunit_test_summary
