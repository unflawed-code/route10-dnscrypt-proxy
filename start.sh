#!/bin/ash
# Wrapper to start dnscrypt-proxy and configure dnsmasq robustly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Load configuration and common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    . "$SCRIPT_DIR/lib/common.sh"
else
    echo "Error: common.sh not found!"
    exit 1
fi

# Build merged setup config (setup.toml + setup-custom.toml if present)
build_setup_run_config

# Load configuration from TOML
FILTER_UPDATE_CRON=$(get_config ".settings.filter_update_cron" "0 4 * * *")
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

    local base="$SCRIPT_DIR/dnscrypt-proxy.toml"
    local custom1="$SCRIPT_DIR/custom.toml"
    local custom2="$SCRIPT_DIR/dnscrypt-proxy-custom.toml"

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

    if [ -n "$BLOCKED_NAMES_SOURCES" ]; then
        if [ ! -s "$filter_dest" ]; then
            log "Downloading DNS blocklists to RAM ($filter_dest)..."
            # Clear or create the destination file
            > "$filter_dest"
            
            # Loop through the multi-line string of URLs
            for url in $BLOCKED_NAMES_SOURCES; do
                [ -z "$url" ] && continue
                log " -> Fetching: $url"
                curl -sS -L "$url" >> "$filter_dest" || log "Warning: Failed to fetch $url"
                echo "" >> "$filter_dest" # Ensure newline between lists
            done
        fi
        
        if [ -s "$filter_dest" ]; then
            log "Enabling DNS blocklist..."
            echo -e "\n# --- AUTO-GENERATED BLOCKLIST ---" >> "$RUN_CONFIG"
            echo "[blocked_names]" >> "$RUN_CONFIG"
            echo "blocked_names_file = '$filter_dest'" >> "$RUN_CONFIG"
            
            if [ "${BLOCK_LOGGING:-0}" != "0" ]; then
                echo "log_file = '/var/log/dnscrypt-blocked.log'" >> "$RUN_CONFIG"
                echo "log_format = 'tsv'" >> "$RUN_CONFIG"
            fi
        fi
    fi
}

setup_cron_job() {
    local cron_file="/etc/crontabs/root"
    local job_cmd="$SCRIPT_DIR/update-filters.sh -f >/dev/null 2>&1"
    
    local job_schedule="${FILTER_UPDATE_CRON:-0 4 * * *}"
    if [ -n "$BLOCKED_NAMES_SOURCES" ]; then
        touch "$cron_file" 2>/dev/null || true
        if ! grep -Fxq "$job_schedule $job_cmd" "$cron_file"; then
            # Remove any existing entry for this script and re-add to ensure it matches current schedule/path
            sed -i "\|$SCRIPT_DIR/update-filters.sh|d" "$cron_file" 2>/dev/null || true
            log "Configuring cron job for filter updates ($job_schedule)..."
            echo "$job_schedule $job_cmd" >> "$cron_file"
            /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
        fi
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
        if "$SCRIPT_DIR/dnscrypt-proxy" -resolve google.com -config "$config_path" >/dev/null 2>&1; then
            return 0
        fi
        log "Waiting for DNSCrypt to establish upstream connection (Attempt $((retry + 1))/$max_retries)..."
        sleep 4
        retry=$((retry + 1))
    done

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

    log "--- DNSCrypt Startup Sequence Initiated ($VERSION) ---"

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
        log "Starting dnscrypt-proxy..."
        "$SCRIPT_DIR/dnscrypt-proxy" -config "$RUN_CONFIG" > "$LOG_FILE" 2>&1 &

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

    setup_system_integration
    setup_cron_job

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
