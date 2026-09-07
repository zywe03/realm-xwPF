#!/usr/bin/env bash
# Wrapper so pty_run.py (which only forwards keystrokes, not argv) can drive
# `xwPF.sh install` — the real bootstrap entrypoint (equivalent to
# `curl ... | sudo bash -s install`), exercised here via the mocked curl,
# which serves lib/*.sh and xwPF.sh from this same checkout instead of GitHub.
exec bash "$XWPF_REPO_ROOT/xwPF.sh" install
