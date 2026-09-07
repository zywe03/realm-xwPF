#!/usr/bin/env bash
# tests/run.sh — run xwPF's full test suite in the throwaway Docker sandbox.
#
# This is the one command for running tests, whether by hand or in CI:
#
#   bash tests/run.sh
#
# xwPF writes to real system paths (/etc/realm, /usr/local/bin,
# /etc/systemd/system/...) by design, so tests never run on the bare host —
# always inside the container built from tests/Dockerfile.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="xwpf-tests"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found in PATH. Install Docker to run xwPF's test suite." >&2
    exit 1
fi

docker build -f "$REPO_ROOT/tests/Dockerfile" -t "$IMAGE_TAG" "$REPO_ROOT"
docker run --rm "$IMAGE_TAG"
