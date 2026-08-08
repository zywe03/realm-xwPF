#!/usr/bin/env bash
# Shared setup for xwPF's ptyunit test suite. Source this before sourcing any
# lib/*.sh file or spawning xwPF.sh under pty_run.py.
#
# IMPORTANT: xwPF writes to real system paths by design (/etc/realm,
# /usr/local/bin, /etc/systemd/system/...). This suite is only safe to run
# inside the throwaway container built from tests/Dockerfile — never on a
# bare host. See tests/run.sh.
#
# Deliberately no `set -u` here: it's sourced into the same shell as
# lib/*.sh, which relies on unset associative-array keys reading as empty
# under default bash semantics (e.g. lib/realm.sh's port_configs lookups).

XWPF_TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XWPF_REPO_ROOT="$(cd "$XWPF_TEST_HELPERS_DIR/../.." && pwd)"
export XWPF_MOCKS_DIR="$XWPF_TEST_HELPERS_DIR/../mocks/bin"

# Put mocks first on PATH so systemctl/curl/wget resolve to our stubs.
export PATH="$XWPF_MOCKS_DIR:$PATH"

# Isolated, per-test-run state for the mock systemctl.
export XWPF_MOCK_STATE_DIR="$(mktemp -d /tmp/xwpf-mock-systemd.XXXXXX)"

# Build the offline install fixture once per test run: a tarball containing
# a single executable named `realm`, matching what install_realm() expects
# after `tar -xzf`.
xwpf_build_fake_realm_tarball() {
    local out_dir
    out_dir="$(mktemp -d /tmp/xwpf-fake-realm.XXXXXX)"
    cp "$XWPF_REPO_ROOT/tests/fixtures/fake-realm.sh" "$out_dir/realm"
    chmod +x "$out_dir/realm"
    ( cd "$out_dir" && tar -czf realm.tar.gz realm )
    echo "$out_dir/realm.tar.gz"
}

xwpf_reset_mock_systemd_state() {
    rm -rf "$XWPF_MOCK_STATE_DIR"
    mkdir -p "$XWPF_MOCK_STATE_DIR"
}

# xwPF.sh's default (non-"install") entrypoint sources libs from the
# *installed* location ($INSTALL_DIR/lib = /usr/local/bin/lib), hardcoded in
# xwPF.sh, not from the repo checkout. Integration tests that drive the
# interactive menu need that location seeded first. Guarded by
# XWPF_ALLOW_SYSTEM_WRITES (set only in tests/Dockerfile) so this can never
# touch a real host's /usr/local/bin or /etc/realm.
xwpf_seed_installed_files() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /usr/local/bin: XWPF_ALLOW_SYSTEM_WRITES!=1 (integration tests must run in tests/Dockerfile)" >&2
        return 1
    fi
    mkdir -p /usr/local/bin/lib
    # Symlinked rather than copied: xwPF.sh's non-install entrypoint always
    # sources from $INSTALL_DIR/lib, so pty_run.py's coverage tracer records
    # hits against /usr/local/bin/lib/*.sh. coverage_report.py resolves each
    # traced path with realpath() before matching it against --src, so a
    # symlink back to the repo checkout is what lets integration-test runs
    # actually count toward coverage. A real install would download
    # independent copies, but the bytes sourced are identical either way —
    # only the coverage tool's path-matching cares about the distinction.
    for f in "$XWPF_REPO_ROOT"/lib/*.sh; do
        ln -sf "$f" "/usr/local/bin/lib/$(basename "$f")"
    done
    ln -sf "$XWPF_REPO_ROOT/xwPF.sh" /usr/local/bin/xwPF.sh
    chmod +x "$XWPF_REPO_ROOT/xwPF.sh"
    ln -sf /usr/local/bin/xwPF.sh /usr/local/bin/pf
}

# Write a rule-N.conf fixture directly into the real RULES_DIR
# (/etc/realm/rules), for integration tests that need a pre-existing rule
# without scripting the full interactive_add_rule flow.
xwpf_seed_rule() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    local id="$1" port="$2" enabled="${3:-true}"
    mkdir -p /etc/realm/rules
    cat > "/etc/realm/rules/rule-${id}.conf" <<EOF
RULE_ID=${id}
RULE_NAME=test-rule-${id}
LISTEN_PORT=${port}
RULE_ROLE=1
REMOTE_HOST=127.0.0.1
REMOTE_PORT=9000
ENABLED=${enabled}
SECURITY_LEVEL=standard
EOF
}

# Place the fake realm binary fixture at the real REALM_PATH
# (/usr/local/bin/realm), for integration tests that need show_brief_status
# and service_restart/service_stop to see an "installed" realm without
# driving the full install flow.
xwpf_seed_fake_realm_binary() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /usr/local/bin: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    cp "$XWPF_REPO_ROOT/tests/fixtures/fake-realm.sh" /usr/local/bin/realm
    chmod +x /usr/local/bin/realm
}

# Write the systemd unit file at the real SYSTEMD_PATH, as generate_service_file()
# would after a completed install. Needed by tests that simulate an
# already-installed host and then exercise restart/stop: service_restart()
# only regenerates config.json, not the unit file, and the mocked systemctl
# (like real systemd) refuses to start/restart a unit that was never generated.
xwpf_seed_realm_service_file() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to write to /etc/systemd/system: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/realm.service <<'EOF'
[Unit]
Description=realm-xwpf
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.json
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
}

# Reset all real-path state the app touches, between integration test files.
xwpf_clean_system_state() {
    if [ "${XWPF_ALLOW_SYSTEM_WRITES:-}" != "1" ]; then
        echo "refusing to clean /usr/local/bin or /etc/realm: XWPF_ALLOW_SYSTEM_WRITES!=1" >&2
        return 1
    fi
    rm -rf /usr/local/bin/xwPF.sh /usr/local/bin/lib /usr/local/bin/pf /usr/local/bin/realm \
           /etc/realm /etc/systemd/system/realm.service
}
