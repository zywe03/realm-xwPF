# tests/Dockerfile — throwaway sandbox for xwPF's ptyunit test suite.
#
# xwPF writes to real system paths by design (/etc/realm, /usr/local/bin,
# /etc/systemd/system/...), so the suite only ever runs inside this
# container, never on a bare host. See tests/run.sh, which is the single
# command used both locally and in CI.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        curl \
        wget \
        tar \
        bc \
        jq \
        iproute2 \
        procps \
        ca-certificates \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Only integration-test helpers (tests/helpers/env.sh) that opt in via this
# flag are allowed to write to /usr/local/bin or /etc/realm — a guard
# against ever running the same helpers against a real host.
ENV XWPF_ALLOW_SYSTEM_WRITES=1

WORKDIR /repo
COPY . .

CMD ["bash", "tests/run-in-container.sh"]
