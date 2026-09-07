#!/usr/bin/env bash
# tests/run-in-container.sh — the actual test run, executed as the
# Dockerfile's CMD. Not meant to be run outside the container: see
# tests/run.sh for the command to use locally or in CI.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

overall_rc=0

echo "== unit tests (parallel) =="
bash tests/ptyunit/run.sh --unit
[ $? -eq 0 ] || overall_rc=1

echo ""
echo "== integration tests (sequential: real shared /etc/realm, /usr/local/bin state) =="
bash tests/ptyunit/run.sh --integration --jobs 1
[ $? -eq 0 ] || overall_rc=1

exit "$overall_rc"
