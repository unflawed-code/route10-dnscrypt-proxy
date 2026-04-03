#!/bin/bash
# Safety tests for dnsmasq cutover logic in start.sh

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0
FAKE_DATE_SEQUENCE=""

say_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASS=$((PASS + 1))
}

say_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        say_pass "$msg"
    else
        say_fail "$msg"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

reset_state() {
    UCI_SERVERS=$'127.0.0.1#5053\n127.0.0.1#5054\n127.0.0.1#5055'
    UCI_NORESOLV='0'
    UCI_ALLSERVERS='1'
    UCI_COMMITS=0
    DNSMASQ_RESTARTS=0
    DNSMASQ_TEST_OK=1
    DNSMASQ_RUNTIME_OK=1
}

reset_main_state() {
    BUILD_RUN_CONFIG_CALLS=0
    WAIT_FOR_DNSCRYPT_RESOLUTION_CONFIG=""
    NETSTAT_SHOWS_PORT=0
    PS_HAS_DNSCRYPT=0
}

date() {
    if [ "$1" = "+%s" ]; then
        if [ -n "$FAKE_DATE_SEQUENCE" ]; then
            local current="${FAKE_DATE_SEQUENCE%% *}"
            if [ "$FAKE_DATE_SEQUENCE" = "$current" ]; then
                FAKE_DATE_SEQUENCE="$current"
            else
                FAKE_DATE_SEQUENCE="${FAKE_DATE_SEQUENCE#* }"
            fi
            printf '%s\n' "$current"
            return 0
        fi
        command date "+%s"
        return 0
    fi

    command date "$@"
}

uci() {
    local quiet=0
    if [ "${1:-}" = "-q" ]; then
        quiet=1
        shift
    fi

    case "$1" in
        get)
            case "$2" in
                dhcp.@dnsmasq\[0\].server) printf '%s\n' "$UCI_SERVERS" ;;
                dhcp.@dnsmasq\[0\].noresolv) printf '%s\n' "$UCI_NORESOLV" ;;
                dhcp.@dnsmasq\[0\].allservers) printf '%s\n' "$UCI_ALLSERVERS" ;;
                *)
                    [ "$quiet" = "1" ] || echo "unsupported get: $2" >&2
                    return 1
                    ;;
            esac
            ;;
        set)
            case "$2" in
                dhcp.@dnsmasq\[0\].noresolv=*) UCI_NORESOLV="${2#*=}" ;;
                dhcp.@dnsmasq\[0\].allservers=*) UCI_ALLSERVERS="${2#*=}" ;;
                *)
                    echo "unsupported set: $2" >&2
                    return 1
                    ;;
            esac
            ;;
        delete)
            case "$2" in
                dhcp.@dnsmasq\[0\].server) UCI_SERVERS="" ;;
                dhcp.@dnsmasq\[0\].noresolv) UCI_NORESOLV="" ;;
                dhcp.@dnsmasq\[0\].allservers) UCI_ALLSERVERS="" ;;
                *)
                    [ "$quiet" = "1" ] || echo "unsupported delete: $2" >&2
                    return 1
                    ;;
            esac
            ;;
        add_list)
            case "$2" in
                dhcp.@dnsmasq\[0\].server=*)
                    local value="${2#*=}"
                    if [ -n "$UCI_SERVERS" ]; then
                        UCI_SERVERS="${UCI_SERVERS}"$'\n'"${value}"
                    else
                        UCI_SERVERS="${value}"
                    fi
                    ;;
                *)
                    echo "unsupported add_list: $2" >&2
                    return 1
                    ;;
            esac
            ;;
        commit)
            [ "$2" = "dhcp" ] || return 1
            UCI_COMMITS=$((UCI_COMMITS + 1))
            ;;
        *)
            echo "unsupported uci cmd: $1" >&2
            return 1
            ;;
    esac
}

dnsmasq() {
    [ "${1:-}" = "--test" ] || return 1
    [ "$DNSMASQ_TEST_OK" = "1" ]
}

dnsmasq_service() {
    [ "${1:-}" = "restart" ] || return 1
    DNSMASQ_RESTARTS=$((DNSMASQ_RESTARTS + 1))
    return 0
}

https_dns_proxy_service() {
    return 0
}

nslookup_stub() {
    [ "$DNSMASQ_RUNTIME_OK" = "1" ]
}

sleep() {
    :
}

export DNSCRYPT_START_LIB_ONLY=1
export DNSMASQ_SERVICE=dnsmasq_service
export HTTPS_DNS_PROXY_SERVICE=https_dns_proxy_service
export NSLOOKUP_CMD=nslookup_stub
export SCRIPT_DIR="$PROJECT_ROOT"

# shellcheck source=/dev/null
. "$PROJECT_ROOT/scripts/start.sh"

build_run_config() {
    BUILD_RUN_CONFIG_CALLS=$((BUILD_RUN_CONFIG_CALLS + 1))
}

wait_for_dnscrypt_resolution() {
    WAIT_FOR_DNSCRYPT_RESOLUTION_CONFIG="${1:-}"
    return 0
}

ps() {
    if [ "${PS_HAS_DNSCRYPT:-0}" = "1" ]; then
        echo "123 root dnscrypt-proxy -config /tmp/dnscrypt-proxy.run.toml"
    fi
    return 0
}

netstat() {
    if [ "${1:-}" = "-ln" ] && [ "${NETSTAT_SHOWS_PORT:-0}" = "1" ]; then
        echo "tcp 0 0 127.0.0.1:5059 0.0.0.0:* LISTEN"
    fi
    return 0
}

echo "=== Running dnsmasq cutover safety tests ==="

reset_state
if reconfigure_dnsmasq_safely; then
    assert_eq "127.0.0.1#5059" "$UCI_SERVERS" "cutover removes stale upstreams and leaves only dnscrypt"
    assert_eq "1" "$UCI_NORESOLV" "cutover forces noresolv=1"
    assert_eq "0" "$UCI_ALLSERVERS" "cutover disables allservers"
    assert_eq "1" "$DNSMASQ_RESTARTS" "cutover restarts dnsmasq once on success"
else
    say_fail "cutover success path returned failure"
fi

reset_state
DNSMASQ_RUNTIME_OK=0
if reconfigure_dnsmasq_safely; then
    say_fail "cutover failure path unexpectedly succeeded"
else
    assert_eq $'127.0.0.1#5053\n127.0.0.1#5054\n127.0.0.1#5055' "$UCI_SERVERS" "rollback restores previous upstream servers"
    assert_eq "0" "$UCI_NORESOLV" "rollback restores previous noresolv value"
    assert_eq "1" "$UCI_ALLSERVERS" "rollback restores previous allservers value"
    assert_eq "2" "$DNSMASQ_RESTARTS" "rollback restarts dnsmasq after restoring state"
fi

reset_state
reset_main_state
PS_HAS_DNSCRYPT=1
UCI_SERVERS="127.0.0.1#5059"
UCI_NORESOLV="1"
UCI_ALLSERVERS="0"
if main; then
    assert_eq "0" "$BUILD_RUN_CONFIG_CALLS" "main skips run-config rebuild when dnscrypt is already running"
    assert_eq "/tmp/dnscrypt-proxy/dnscrypt-proxy.run.toml" "$WAIT_FOR_DNSCRYPT_RESOLUTION_CONFIG" "main validates the active run config for already-running dnscrypt"
else
    say_fail "already-running validation path returned failure"
fi

reset_main_state
NETSTAT_SHOWS_PORT=1
if wait_for_dnscrypt_bind; then
    say_pass "wait_for_dnscrypt_bind succeeds when listener is visible without netstat -p"
else
    say_fail "wait_for_dnscrypt_bind should succeed when listener is present"
fi

reset_main_state
if wait_for_dnscrypt_bind; then
    say_fail "wait_for_dnscrypt_bind should fail when process is absent"
else
    say_pass "wait_for_dnscrypt_bind fails fast when dnscrypt process exits before binding"
fi

FAKE_DATE_SEQUENCE="1704067200"
if wait_for_sane_clock; then
    say_pass "wait_for_sane_clock succeeds immediately when clock is already sane"
else
    say_fail "wait_for_sane_clock should succeed when clock is already sane"
fi

FAKE_DATE_SEQUENCE="100 100 100 100 100 100"
CLOCK_WAIT_TIMEOUT_SEC=5
CLOCK_WAIT_INTERVAL_SEC=1
if wait_for_sane_clock; then
    say_fail "wait_for_sane_clock should fail when clock never becomes sane"
else
    say_pass "wait_for_sane_clock fails cleanly when clock never becomes sane"
fi

reset_state
reset_main_state
wait_for_sane_clock() { return 1; }
if main; then
    say_fail "main should fail when clock is not sane before startup"
else
    assert_eq "0" "$BUILD_RUN_CONFIG_CALLS" "main does not build config or start dnscrypt before clock is sane"
fi

if [ "$FAIL" -eq 0 ]; then
    echo -e "\n${GREEN}=== ALL TESTS PASSED ===${NC}"
    exit 0
fi

echo -e "\n${RED}=== TESTS FAILED ===${NC}"
exit 1
