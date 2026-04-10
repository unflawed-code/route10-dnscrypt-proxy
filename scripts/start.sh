#!/bin/ash
# Wrapper to start dnscrypt-proxy and configure dnsmasq robustly

if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    PROJECT_DIR="$SCRIPT_DIR"
else
    SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ "$(basename "$SELF_DIR")" = "scripts" ]; then
        PROJECT_DIR="$(dirname "$SELF_DIR")"
    else
        PROJECT_DIR="$SELF_DIR"
    fi
fi
SCRIPT_DIR="$PROJECT_DIR"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
LOG_FILE=/var/log/dnscrypt-proxy.log
PORT=5059
VERSION="v1.1.0"
RUN_CONFIG="/tmp/dnscrypt-proxy/dnscrypt-proxy.run.toml"
DNSMASQ_SECTION="dhcp.@dnsmasq[0]"
DNSMASQ_SERVICE="${DNSMASQ_SERVICE:-/etc/init.d/dnsmasq}"
HTTPS_DNS_PROXY_SERVICE="${HTTPS_DNS_PROXY_SERVICE:-/etc/init.d/https-dns-proxy}"
NSLOOKUP_CMD="${NSLOOKUP_CMD:-nslookup}"
CLOCK_SANE_MIN_EPOCH="${CLOCK_SANE_MIN_EPOCH:-1704067200}"
CLOCK_WAIT_TIMEOUT_SEC="${CLOCK_WAIT_TIMEOUT_SEC:-300}"
CLOCK_WAIT_INTERVAL_SEC="${CLOCK_WAIT_INTERVAL_SEC:-5}"
START_LOCK_DIR="/tmp/dnscrypt-proxy/start.lock"
START_LOCK_PID_FILE="${START_LOCK_DIR}/pid"

# Load configuration and common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    . "$SCRIPT_DIR/lib/common.sh"
else
    echo "Error: common.sh not found!"
    exit 1
fi

cron_or_default() {
    local value="$1"
    local fallback="$2"
    local key_name="${3:-cron}"

    if [ -z "$value" ]; then
        echo "$fallback"
        return 0
    fi

    if [ "$(printf '%s\n' "$value" | awk '{ print NF }')" = "5" ]; then
        echo "$value"
    else
        log "Warning: Invalid cron expression for $key_name ('$value'). Falling back to '$fallback'."
        echo "$fallback"
    fi
}

# Build merged setup config (setup.toml + setup-custom.toml if present)
build_setup_run_config

# Load configuration from TOML
FILTER_UPDATE_CRON=$(get_config ".settings.filter_update_cron" "0 4 * * *")
ENABLE_AUTO_UPDATE=$(get_config ".settings.enable_auto_update" "0")
UPDATER_CHECK_CRON=$(get_config ".settings.updater_check_cron" "35 4 * * *")
FILTER_UPDATE_CRON="$(cron_or_default "$FILTER_UPDATE_CRON" "0 4 * * *" "settings.filter_update_cron")"
UPDATER_CHECK_CRON="$(cron_or_default "$UPDATER_CHECK_CRON" "35 4 * * *" "settings.updater_check_cron")"
BLOCKED_NAMES_SOURCES=$(get_config ".sources.blocked_names")
BLOCK_LOGGING=$(get_config ".settings.block_logging" "0")
FILTER_DIR=$(get_config ".settings.filter_dir" "/tmp/dnscrypt-proxy")

BACKUP_DNSMASQ_SERVERS=""
BACKUP_DNSMASQ_NORESOLV=""
BACKUP_DNSMASQ_ALLSERVERS=""

set_uci_option_or_delete() {
    local option="$1"
    local value="$2"
    if [ -n "$value" ]; then
        uci set "${option}=${value}"
    else
        uci -q delete "$option" 2>/dev/null || true
    fi
}

is_enabled() {
    case "${1:-0}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

backup_dnsmasq_state() {
    BACKUP_DNSMASQ_SERVERS="$(uci -q get ${DNSMASQ_SECTION}.server 2>/dev/null || true)"
    BACKUP_DNSMASQ_NORESOLV="$(uci -q get ${DNSMASQ_SECTION}.noresolv 2>/dev/null || true)"
    BACKUP_DNSMASQ_ALLSERVERS="$(uci -q get ${DNSMASQ_SECTION}.allservers 2>/dev/null || true)"
}

restore_dnsmasq_state() {
    local old_ifs
    local server

    uci -q delete "${DNSMASQ_SECTION}.server" 2>/dev/null || true
    if [ -n "$BACKUP_DNSMASQ_SERVERS" ]; then
        old_ifs="$IFS"
        IFS='
'
        for server in $BACKUP_DNSMASQ_SERVERS; do
            [ -n "$server" ] || continue
            uci add_list "${DNSMASQ_SECTION}.server=${server}"
        done
        IFS="$old_ifs"
    fi
    set_uci_option_or_delete "${DNSMASQ_SECTION}.noresolv" "$BACKUP_DNSMASQ_NORESOLV"
    set_uci_option_or_delete "${DNSMASQ_SECTION}.allservers" "$BACKUP_DNSMASQ_ALLSERVERS"
    uci commit dhcp
}

dnsmasq_uses_dnscrypt_only() {
    local servers
    local count
    servers="$(uci -q get ${DNSMASQ_SECTION}.server 2>/dev/null || true)"
    count="$(printf '%s\n' "$servers" | sed '/^$/d' | wc -l | tr -d ' ')"
    [ "${count:-0}" = "1" ] || return 1
    printf '%s\n' "$servers" | grep -Fx "127.0.0.1#$PORT" >/dev/null 2>&1 || return 1
    [ "$(uci -q get ${DNSMASQ_SECTION}.noresolv 2>/dev/null || true)" = "1" ] || return 1
    [ "$(uci -q get ${DNSMASQ_SECTION}.allservers 2>/dev/null || true)" != "1" ] || return 1
    return 0
}

apply_dnscrypt_dnsmasq_state() {
    uci -q delete "${DNSMASQ_SECTION}.server" 2>/dev/null || true
    uci set "${DNSMASQ_SECTION}.noresolv=1"
    uci set "${DNSMASQ_SECTION}.allservers=0"
    uci add_list "${DNSMASQ_SECTION}.server=127.0.0.1#$PORT"
    uci commit dhcp
}

validate_dnsmasq_runtime() {
    local retries=3
    local retry=0

    while [ "$retry" -lt "$retries" ]; do
        if "$NSLOOKUP_CMD" openwrt.org 127.0.0.1 >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        retry=$((retry + 1))
    done

    return 1
}

rollback_dnsmasq_cutover() {
    log "Restoring previous dnsmasq upstream configuration..."
    restore_dnsmasq_state
    "$DNSMASQ_SERVICE" restart >/dev/null 2>&1 || true
}

reconfigure_dnsmasq_safely() {
    backup_dnsmasq_state
    apply_dnscrypt_dnsmasq_state

    if ! dnsmasq --test >/dev/null 2>&1; then
        log "CRITICAL ERROR: dnsmasq configuration test failed after DNSCrypt cutover."
        rollback_dnsmasq_cutover
        return 1
    fi

    if ! "$DNSMASQ_SERVICE" restart >/dev/null 2>&1; then
        log "CRITICAL ERROR: dnsmasq restart failed after DNSCrypt cutover."
        rollback_dnsmasq_cutover
        return 1
    fi

    if ! validate_dnsmasq_runtime; then
        log "CRITICAL ERROR: dnsmasq failed live DNS validation after DNSCrypt cutover."
        rollback_dnsmasq_cutover
        return 1
    fi

    return 0
}

build_run_config() {
    mkdir -p "$(dirname "$RUN_CONFIG")"
    rm -f "$RUN_CONFIG"

    local base="$PROJECT_DIR/conf/dnscrypt-proxy.toml"
    local custom1="$PROJECT_DIR/conf/custom.toml"
    local custom2="$PROJECT_DIR/conf/dnscrypt-proxy-custom.toml"

    log "Building layered run configuration (Base < custom.toml < dnscrypt-key-custom.toml)..."

    # --- ROOT KEYS LAYER ---
    # Start with the highest priority root keys (including comments)
    if [ -f "$custom2" ]; then
        awk '/^\[/ {exit} {print}' "$custom2" > "$RUN_CONFIG" 2>/dev/null || true
    fi

    # Extract keys already defined in the current run config to enable filtering
    _get_keys() {
        [ -f "$1" ] || return
        awk '/^\[/ {exit} /^[a-z_]+[ ]*=/ {split($1, a, "="); print a[1]}' "$1" | tr -d ' '
    }

    # Layer in custom.toml root keys (filtering out duplicates found in custom2)
    if [ -f "$custom1" ]; then
        local existing_keys=$(_get_keys "$RUN_CONFIG")
        if [ -n "$existing_keys" ]; then
            local pattern=$(echo "$existing_keys" | sed 's/^/^/; s/$/ =/' | tr '\n' '|')
            awk '/^\[/ {exit} {print}' "$custom1" | grep -vE "${pattern%|}" >> "$RUN_CONFIG" 2>/dev/null || true
        else
            awk '/^\[/ {exit} {print}' "$custom1" >> "$RUN_CONFIG" 2>/dev/null || true
        fi
    fi

    # Layer in Base root keys (filtering out duplicates from BOTH custom levels)
    local existing_keys=$(_get_keys "$RUN_CONFIG")
    if [ -n "$existing_keys" ]; then
        local pattern=$(echo "$existing_keys" | sed 's/^/^/; s/$/ =/' | tr '\n' '|')
        awk '/^\[/ {exit} {print}' "$base" | grep -vE "${pattern%|}" >> "$RUN_CONFIG" 2>/dev/null || true
    else
        awk '/^\[/ {exit} {print}' "$base" >> "$RUN_CONFIG" 2>/dev/null || true
    fi

    # --- SECTIONS LAYER ---
    # Concatenate sections in order of increasing priority. last key wins.
    echo -e "\n# --- BASE SECTIONS ---" >> "$RUN_CONFIG"
    sed -n '/^\[/,$p' "$base" >> "$RUN_CONFIG" 2>/dev/null || true

    if [ -f "$custom1" ]; then
        echo -e "\n# --- CUSTOM.TOML SECTIONS ---" >> "$RUN_CONFIG"
        sed -n '/^\[/,$p' "$custom1" >> "$RUN_CONFIG" 2>/dev/null || true
    fi

    if [ -f "$custom2" ]; then
        echo -e "\n# --- DNSCRYPT-PROXY-CUSTOM.TOML SECTIONS ---" >> "$RUN_CONFIG"
        sed -n '/^\[/,$p' "$custom2" >> "$RUN_CONFIG" 2>/dev/null || true
    fi

    # Handle DNS Filtering (Blocklist)
    local tmp_base="$FILTER_DIR"
    mkdir -p "$tmp_base"
    local filter_dest="$tmp_base/dnscrypt-blocked-names.txt"

    if [ -n "$BLOCKED_NAMES_SOURCES" ] && [ -s "$filter_dest" ]; then
        log "Enabling DNS blocklist..."
        echo -e "\n# --- AUTO-GENERATED BLOCKLIST ---" >> "$RUN_CONFIG"
        echo "[blocked_names]" >> "$RUN_CONFIG"
        echo "blocked_names_file = '$filter_dest'" >> "$RUN_CONFIG"

        if [ "${BLOCK_LOGGING:-0}" != "0" ]; then
            echo "log_file = '/var/log/dnscrypt-blocked.log'" >> "$RUN_CONFIG"
            echo "log_format = 'tsv'" >> "$RUN_CONFIG"
        fi
    fi
}

setup_cron_job() {
    local cron_file="/etc/crontabs/root"
    local filter_job_cmd="/bin/ash $PROJECT_DIR/proxy.sh update-filters -f >/dev/null 2>&1"
    local updater_job_cmd="/bin/ash $PROJECT_DIR/proxy.sh updater check >/dev/null 2>&1"
    local filter_job_schedule="${FILTER_UPDATE_CRON:-0 4 * * *}"
    local updater_job_schedule="${UPDATER_CHECK_CRON:-35 4 * * *}"
    local changed=0

    touch "$cron_file" 2>/dev/null || return 0

    if [ -n "$BLOCKED_NAMES_SOURCES" ] && ! grep -Fxq "$filter_job_schedule $filter_job_cmd" "$cron_file"; then
        sed -i "\|proxy.sh update-filters|d" "$cron_file" 2>/dev/null || true
        sed -i "\|update-filters.sh -f|d" "$cron_file" 2>/dev/null || true
        log "Configuring cron job for filter updates ($filter_job_schedule)..."
        echo "$filter_job_schedule $filter_job_cmd" >> "$cron_file"
        changed=1
    fi

    if grep -q "proxy.sh updater check\|updater.sh check" "$cron_file" 2>/dev/null; then
        sed -i "\|proxy.sh updater check|d" "$cron_file" 2>/dev/null || true
        sed -i "\|updater.sh check|d" "$cron_file" 2>/dev/null || true
        changed=1
    fi

    if is_enabled "$ENABLE_AUTO_UPDATE" && [ -f "$SCRIPTS_DIR/updater.sh" ] && ! grep -Fxq "$updater_job_schedule $updater_job_cmd" "$cron_file"; then
        log "Configuring cron job for updater checks ($updater_job_schedule)..."
        echo "$updater_job_schedule $updater_job_cmd" >> "$cron_file"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
}

clock_is_sane() {
    local now
    now="$(date +%s 2>/dev/null || echo 0)"
    case "$now" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$now" -ge "$CLOCK_SANE_MIN_EPOCH" ]
}

wait_for_sane_clock() {
    local waited=0

    if clock_is_sane; then
        return 0
    fi

    while [ "$waited" -lt "$CLOCK_WAIT_TIMEOUT_SEC" ]; do
        log "Waiting for system clock/NTP sync (${waited}s/${CLOCK_WAIT_TIMEOUT_SEC}s)..."
        sleep "$CLOCK_WAIT_INTERVAL_SEC"
        waited=$((waited + CLOCK_WAIT_INTERVAL_SEC))
        if clock_is_sane; then
            return 0
        fi
    done

    return 1
}

wait_for_dnscrypt_bind() {
    local max_retries=3
    local retry=0

    while [ "$retry" -lt "$max_retries" ]; do
        if netstat -ln 2>/dev/null | grep -Eq "127\\.0\\.0\\.1:$PORT|0\\.0\\.0\\.0:$PORT|\\[::1\\]:$PORT|:::$PORT"; then
            return 0
        fi
        if ! ps | grep -q "[d]nscrypt-proxy -config"; then
            return 1
        fi
        log "Waiting for dnscrypt-proxy to bind to port $PORT (Attempt $((retry + 1))/$max_retries)..."
        sleep 3
        retry=$((retry + 1))
    done

    return 1
}

wait_for_dnscrypt_resolution() {
    local max_retries=15
    local retry=0
    local config_path="${1:-$RUN_CONFIG}"

    while [ "$retry" -lt "$max_retries" ]; do
        if "$PROJECT_DIR/dnscrypt-proxy" -resolve google.com -config "$config_path" >/dev/null 2>&1; then
            return 0
        fi
        log "Waiting for DNSCrypt to establish upstream connection (Attempt $((retry + 1))/$max_retries)..."
        sleep 4
        retry=$((retry + 1))
    done

    return 1
}

ensure_allowed_names_file() {
    [ -f "$RUN_CONFIG" ] || return 0
    local allowed_file
    local fallback_file
    allowed_file="$(sed -n "s/^[[:space:]]*allowed_names_file[[:space:]]*=[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$RUN_CONFIG" | head -n 1)"
    [ -n "$allowed_file" ] || return 0
    [ -f "$allowed_file" ] && return 0

    mkdir -p "$(dirname "$allowed_file")" 2>/dev/null || true
    if : > "$allowed_file" 2>/dev/null; then
        log "Created missing allowed_names file: $allowed_file"
        return 0
    fi

    # Optional whitelist should never block startup. Use a safe writable fallback.
    fallback_file="/tmp/dnscrypt-proxy/allowed-names.fallback.txt"
    mkdir -p "/tmp/dnscrypt-proxy" 2>/dev/null || true
    : > "$fallback_file" 2>/dev/null || true
    if [ -f "$fallback_file" ]; then
        sed -i "s#^[[:space:]]*allowed_names_file[[:space:]]*=.*#allowed_names_file = '$fallback_file'#" "$RUN_CONFIG" 2>/dev/null || true
        log "Whitelist path '$allowed_file' is unavailable; using fallback '$fallback_file'."
    else
        log "Warning: whitelist path '$allowed_file' is unavailable and fallback creation failed; continuing without guaranteed allowlist file."
    fi
}

release_start_lock() {
    if [ -d "$START_LOCK_DIR" ] && [ "$(cat "$START_LOCK_PID_FILE" 2>/dev/null || true)" = "$$" ]; then
        rm -rf "$START_LOCK_DIR" 2>/dev/null || true
    fi
}

acquire_start_lock() {
    local lock_pid

    mkdir -p "/tmp/dnscrypt-proxy" 2>/dev/null || true

    if mkdir "$START_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$START_LOCK_PID_FILE" 2>/dev/null || true
        trap release_start_lock EXIT INT TERM
        return 0
    fi

    lock_pid="$(cat "$START_LOCK_PID_FILE" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$START_LOCK_DIR" 2>/dev/null || true
        if mkdir "$START_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$START_LOCK_PID_FILE" 2>/dev/null || true
            trap release_start_lock EXIT INT TERM
            log "Recovered stale DNSCrypt startup lock."
            return 0
        fi
    fi

    log "Another DNSCrypt start instance is already running. Exiting."
    return 1
}

main() {
    local force_restart=0
    local dnscrypt_already_running=0
    local active_config="$RUN_CONFIG"

    if [ "${1:-}" = "-f" ]; then
        log "Force restart requested. Killing existing dnscrypt-proxy processes..."
        killall dnscrypt-proxy 2>/dev/null || true
        sleep 2
        force_restart=1
    fi

    if ! acquire_start_lock; then
        return 0
    fi

    log "--- DNSCrypt Startup Sequence Initiated ($VERSION) ---"

    # Re-create volatile integrations early so they persist across reboot even
    # if DNS startup later aborts due clock/network readiness.
    setup_system_integration "$SCRIPT_DIR"
    setup_cron_job

    if [ "$force_restart" -eq 0 ] && ps | grep -q "[d]nscrypt-proxy -config"; then
        dnscrypt_already_running=1
        log "dnscrypt-proxy is already running. Validating service and dnsmasq cutover state..."
        active_config="/tmp/dnscrypt-proxy/dnscrypt-proxy.run.toml"
    fi

    if ! wait_for_sane_clock; then
        log "CRITICAL ERROR: System clock is still not sane after ${CLOCK_WAIT_TIMEOUT_SEC}s."
        log "Aborting to prevent internet loss. Your current DNS remains fully intact."
        if [ "$dnscrypt_already_running" -eq 0 ]; then
            killall dnscrypt-proxy 2>/dev/null || true
        fi
        return 1
    fi

    if [ "$dnscrypt_already_running" -eq 0 ]; then
        mkdir -p "/tmp/dnscrypt-proxy"
        build_run_config
        ensure_allowed_names_file
        log "Starting dnscrypt-proxy..."
        "$PROJECT_DIR/dnscrypt-proxy" -config "$RUN_CONFIG" > "$LOG_FILE" 2>&1 &

        if ! wait_for_dnscrypt_bind; then
            log "ERROR: dnscrypt-proxy failed to start or bind to port $PORT after retries."
            log "Aborting. Your current DNS remains fully intact."
            return 1
        fi

        log "DNSCrypt-Proxy started and bound to port $PORT."
    fi

    log "Testing if DNSCrypt is successfully connected to upstream relays..."
    if ! wait_for_dnscrypt_resolution "$active_config"; then
        log "CRITICAL ERROR: DNSCrypt failed to establish an upstream connection in time."
        log "This is usually caused by the router clock (NTP) not being synced yet."
        log "Aborting to prevent internet loss. Your current DNS remains fully intact."
        if [ "$dnscrypt_already_running" -eq 0 ]; then
            killall dnscrypt-proxy 2>/dev/null || true
        fi
        return 1
    fi

    log "Success: DNSCrypt is actively resolving queries independently."

    if [ -n "$BLOCKED_NAMES_SOURCES" ] && [ "${DNSCRYPT_SKIP_FILTER_BOOT_UPDATE:-0}" != "1" ]; then
        log "Blocklist sources detected: $(printf '%s\n' "$BLOCKED_NAMES_SOURCES" | sed '/^$/d' | wc -l | tr -d ' ')"
        log "Refreshing DNS blocklists after DNSCrypt is live..."
        /bin/ash "$PROJECT_DIR/proxy.sh" update-filters >/dev/null 2>&1 || log "Warning: blocklist refresh failed; will retry via cron."
    fi

    # Robustly stop https-dns-proxy without redundant logs
    if [ -x "$HTTPS_DNS_PROXY_SERVICE" ]; then
        "$HTTPS_DNS_PROXY_SERVICE" stop >/dev/null 2>&1 || true
    fi

    if dnsmasq_uses_dnscrypt_only && validate_dnsmasq_runtime; then
        log "dnsmasq is already using DNSCrypt cleanly. No cutover needed."
        return 0
    fi

    log "Reconfiguring dnsmasq to use DNSCrypt..."
    if ! reconfigure_dnsmasq_safely; then
        log "Cutover aborted. Previous dnsmasq upstreams were restored."
        return 1
    fi

    log "Dnsmasq successfully reconfigured to use DNSCrypt."
    log "DNS cutover complete."
    return 0
}

if [ "${DNSCRYPT_START_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi
