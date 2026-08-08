#!/bin/sh
# Stand-in for the real `realm` binary. install_realm() only needs something
# executable that answers --version/--help and stays running under `-c <config>`
# (the ExecStart command in the generated systemd unit); it never needs to
# actually relay traffic in this test suite.
case "${1:-}" in
    --version|-v)
        echo "realm 2.9.4 (ptyunit test fixture)"
        exit 0
        ;;
    --help)
        echo "mock realm - fissible/ptyunit test fixture"
        exit 0
        ;;
    *)
        exec sleep infinity
        ;;
esac
