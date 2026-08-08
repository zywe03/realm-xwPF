#!/usr/bin/env bash
# Wrapper so pty_run.py (which only forwards keystrokes, not argv) can drive
# `xwPF.sh --generate-config-only` against the real installed entrypoint.
exec bash /usr/local/bin/xwPF.sh --generate-config-only
