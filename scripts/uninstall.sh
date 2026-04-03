#!/bin/ash
# Route10 DNSCrypt-Proxy Uninstall Script

set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$(basename "$SELF_DIR")" = "scripts" ]; then
    PROJECT_DIR="$(dirname "$SELF_DIR")"
else
    PROJECT_DIR="$SELF_DIR"
fi
SCRIPT_DIR="$PROJECT_DIR"
PORT=5059
CRON_FILE="/etc/crontabs/root"
SETUP_BASE="$SCRIPT_DIR/conf/setup.toml"
SETUP_CUSTOM="$SCRIPT_DIR/conf/setup-custom.toml"

log() {
    echo "[uninstall] $*"
}

get_setting_value() {
    local key="$1"
    local default="$2"
    local val=""

    if [ -f "$SETUP_CUSTOM" ]; then
        val=$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$SETUP_CUSTOM" | head -n 1 | tr -d '\r')
    fi
    if [ -z "$val" ] && [ -f "$SETUP_BASE" ]; then
        val=$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$SETUP_BASE" | head -n 1 | tr -d '\r')
    fi
    [ -n "$val" ] || val="$default"
    echo "$val"
}

POST_CFG="$(get_setting_value "post_cfg" "/cfg/post-cfg.sh")"
FILTER_DIR="$(get_setting_value "filter_dir" "/a/dnscrypt-proxy")"

is_dnsmasq_dnscrypt_only() {
    local servers
    local count
    servers="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
    count="$(printf '%s\n' "$servers" | sed '/^$/d' | wc -l | tr -d ' ')"
    [ "${count:-0}" = "1" ] || return 1
    printf '%s\n' "$servers" | grep -Fx "127.0.0.1#$PORT" >/dev/null 2>&1 || return 1
    [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)" = "1" ] || return 1
    return 0
}

cleanup_post_cfg_hook() {
    [ -f "$POST_CFG" ] || return 0
    sed -i "\|$SCRIPT_DIR/proxy.sh start >/var/log/dnscrypt-proxy-boot.log 2>&1 &|d" "$POST_CFG" 2>/dev/null || true
    sed -i "\|# $SCRIPT_DIR/proxy.sh start >/var/log/dnscrypt-proxy-boot.log 2>&1 &|d" "$POST_CFG" 2>/dev/null || true
    sed -i "\|$SCRIPT_DIR/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &|d" "$POST_CFG" 2>/dev/null || true
    sed -i "\|# $SCRIPT_DIR/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &|d" "$POST_CFG" 2>/dev/null || true
    sed -i "\|Start DNSCrypt-Proxy in background after boot|d" "$POST_CFG" 2>/dev/null || true
}

cleanup_cron_entries() {
    [ -f "$CRON_FILE" ] || return 0
    grep -Fv "proxy.sh update-filters" "$CRON_FILE" | grep -Fv "update-filters.sh -f" | grep -Fv "proxy.sh updater check" | grep -Fv "updater.sh check" > "${CRON_FILE}.tmp" || true
    if [ -f "${CRON_FILE}.tmp" ]; then
        mv "${CRON_FILE}.tmp" "$CRON_FILE"
        /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
}

FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
    FORCE=1
fi

if [ "$FORCE" -eq 0 ]; then
    printf "WARNING: This will remove DNSCrypt-Proxy integration and stop the service.\n"
    printf "Are you sure you want to proceed? (y/N): "
    read -r answer
    case "$answer" in
        [yY][eE][sS]|[yY]) ;;
        *)
            echo "Uninstall cancelled."
            exit 0
            ;;
    esac
fi

log "Stopping dnscrypt-proxy..."
killall dnscrypt-proxy 2>/dev/null || true

log "Removing startup hook from $POST_CFG..."
cleanup_post_cfg_hook

log "Removing project cron entries..."
cleanup_cron_entries

if is_dnsmasq_dnscrypt_only; then
    log "Reverting dnsmasq from DNSCrypt-only mode..."
    uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
    uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || uci -q delete dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
    uci -q delete dhcp.@dnsmasq[0].allservers 2>/dev/null || true
    uci commit dhcp 2>/dev/null || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
else
    log "dnsmasq is not in DNSCrypt-only mode. Leaving its upstream settings unchanged."
fi

if [ -x /etc/init.d/https-dns-proxy ]; then
    log "Starting https-dns-proxy..."
    /etc/init.d/https-dns-proxy start >/dev/null 2>&1 || true
fi

if [ -d "$FILTER_DIR" ]; then
    log "Removing blocklist cache in $FILTER_DIR..."
    rm -f "$FILTER_DIR/dnscrypt-blocked-names.txt" "$FILTER_DIR/dnscrypt-blocked-names.txt.tmp" 2>/dev/null || true
fi

log "Removing runtime cache and merged config..."
rm -rf /tmp/dnscrypt-proxy /tmp/dnscrypt-setup 2>/dev/null || true
rm -f /etc/logrotate.d/dnscrypt-proxy 2>/dev/null || true

log "Uninstall complete. Project files in $SCRIPT_DIR were not deleted."
