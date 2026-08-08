#!/usr/bin/env bash
# Unit tests for get_transport_config() in lib/core.sh — the function that
# picks realm's remote_transport/listen_transport string based on security
# level and role (1 = relay/client, 2 = exit/server). Getting the client and
# server sides to agree on this string is the whole point of the security
# level menu, so it's worth locking down explicitly.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTS_DIR/ptyunit/assert.sh"
source "$TESTS_DIR/helpers/env.sh"
source "$XWPF_REPO_ROOT/lib/core.sh"
source "$XWPF_REPO_ROOT/lib/ui.sh"

describe "get_transport_config: standard"

test_that "produces no transport override for either role"
assert_eq "" "$(get_transport_config "standard" "" "" "" "1" "" "")"
assert_eq "" "$(get_transport_config "standard" "" "" "" "2" "" "")"

end_describe

describe "get_transport_config: ws"

test_that "relay side (role 1) uses remote_transport with defaults"
assert_eq '"remote_transport": "ws;host=www.tesla.com;path=/ws"' \
    "$(get_transport_config "ws" "" "" "" "1" "" "")"

test_that "exit side (role 2) uses listen_transport with defaults"
assert_eq '"listen_transport": "ws;host=www.tesla.com;path=/ws"' \
    "$(get_transport_config "ws" "" "" "" "2" "" "")"

test_that "honors custom ws path and host"
assert_eq '"remote_transport": "ws;host=example.com;path=/custom"' \
    "$(get_transport_config "ws" "" "" "" "1" "/custom" "example.com")"

end_describe

describe "get_transport_config: tls_self"

test_that "relay side is insecure with default SNI"
assert_eq '"remote_transport": "tls;sni=www.tesla.com;insecure"' \
    "$(get_transport_config "tls_self" "" "" "" "1" "" "")"

test_that "exit side uses servername with default SNI"
assert_eq '"listen_transport": "tls;servername=www.tesla.com"' \
    "$(get_transport_config "tls_self" "" "" "" "2" "" "")"

end_describe

describe "get_transport_config: tls_ca"

test_that "relay side (role 1) uses sni with default SNI"
assert_eq '"remote_transport": "tls;sni=www.tesla.com"' \
    "$(get_transport_config "tls_ca" "" "" "" "1" "" "")"

test_that "relay side (role 1) honors a custom sni"
assert_eq '"remote_transport": "tls;sni=example.com"' \
    "$(get_transport_config "tls_ca" "example.com" "" "" "1" "" "")"

test_that "exit side is empty without cert/key paths"
assert_eq "" "$(get_transport_config "tls_ca" "" "" "" "2" "" "")"

test_that "exit side includes cert/key once both are provided"
assert_eq '"listen_transport": "tls;cert=/etc/realm/cert.pem;key=/etc/realm/key.pem"' \
    "$(get_transport_config "tls_ca" "" "/etc/realm/cert.pem" "/etc/realm/key.pem" "2" "" "")"

end_describe

describe "get_transport_config: ws_tls_self"

test_that "relay side (role 1) is insecure with default host/path/sni"
assert_eq '"remote_transport": "ws;host=www.tesla.com;path=/ws;tls;sni=www.tesla.com;insecure"' \
    "$(get_transport_config "ws_tls_self" "" "" "" "1" "" "")"

test_that "exit side (role 2) uses servername with default host/path/sni"
assert_eq '"listen_transport": "ws;host=www.tesla.com;path=/ws;tls;servername=www.tesla.com"' \
    "$(get_transport_config "ws_tls_self" "" "" "" "2" "" "")"

test_that "honors custom ws host/path and sni"
assert_eq '"remote_transport": "ws;host=example.com;path=/custom;tls;sni=sni.example.com;insecure"' \
    "$(get_transport_config "ws_tls_self" "sni.example.com" "" "" "1" "/custom" "example.com")"

end_describe

describe "get_transport_config: ws_tls_ca"

test_that "relay side (role 1) uses sni with default host/path/sni"
assert_eq '"remote_transport": "ws;host=www.tesla.com;path=/ws;tls;sni=www.tesla.com"' \
    "$(get_transport_config "ws_tls_ca" "" "" "" "1" "" "")"

test_that "exit side is empty without cert/key paths"
assert_eq "" "$(get_transport_config "ws_tls_ca" "" "" "" "2" "" "")"

test_that "exit side includes cert/key once both are provided"
assert_eq '"listen_transport": "ws;host=www.tesla.com;path=/ws;tls;cert=/etc/realm/cert.pem;key=/etc/realm/key.pem"' \
    "$(get_transport_config "ws_tls_ca" "" "/etc/realm/cert.pem" "/etc/realm/key.pem" "2" "" "")"

end_describe

describe "get_transport_config: unknown level"

test_that "falls back to empty string"
assert_eq "" "$(get_transport_config "bogus" "" "" "" "1" "" "")"

end_describe

describe "get_security_display"

test_that "standard reads as default transport"
assert_eq "默认传输" "$(get_security_display "standard" "" "")"

test_that "tls_self falls back to the default SNI domain when unset"
assert_eq "TLS自签证书 (SNI: www.tesla.com)" "$(get_security_display "tls_self" "" "")"

end_describe

ptyunit_test_summary
