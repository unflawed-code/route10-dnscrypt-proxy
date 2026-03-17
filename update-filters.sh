#!/bin/sh
# update-filters.sh
# Downloads the latest DNS blocklists and restarts dnscrypt-proxy

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    . "$SCRIPT_DIR/lib/common.sh"
else
    echo "Error: common.sh not found!"
    exit 1
fi

# Build merged setup config (setup.toml + setup-custom.toml if present)
build_setup_run_config

# Load configuration from TOML
BLOCKED_NAMES_SOURCES=$(get_config ".sources.blocked_names")

if [ -z "$BLOCKED_NAMES_SOURCES" ]; then
    echo "Error: BLOCKED_NAMES_SOURCES is not defined in setup.toml"
    exit 1
fi

FORCE=0
if [ "${1:-}" = "-f" ]; then
    FORCE=1
fi

FILTER_DIR=$(get_config ".settings.filter_dir" "/tmp/dnscrypt-proxy")
mkdir -p "$FILTER_DIR"
FILTER_DEST="$FILTER_DIR/dnscrypt-blocked-names.txt"
TMP_DEST="${FILTER_DEST}.tmp"
STALENESS_HOURS=$(get_config ".settings.filter_staleness_hours" "12")
STALENESS_SEC=$(( STALENESS_HOURS * 3600 ))

# Check if the existing blocklist is still fresh
if [ "$FORCE" -eq 0 ] && [ -s "$FILTER_DEST" ]; then
    file_age=$(( $(date +%s) - $(date -r "$FILTER_DEST" +%s 2>/dev/null || echo 0) ))
    if [ "$file_age" -lt "$STALENESS_SEC" ]; then
        hours_ago=$(( file_age / 3600 ))
        echo "Blocklist is only ${hours_ago}h old (< ${STALENESS_HOURS}h). Skipping download. Use -f to force."
        exit 0
    fi
fi

# Connectivity check: verify DNS resolution works before proceeding.
# If DNS is broken (e.g. dnsmasq was disrupted by another cron job),
# run start.sh to restore DNS and then continue with the update.
if ! nslookup cdn.jsdelivr.net 127.0.0.1 >/dev/null 2>&1; then
    echo "DNS resolution failed. Running start.sh to restore DNS..."
    DNSCRYPT_SKIP_FILTER_BOOT_UPDATE=1 "$SCRIPT_DIR/start.sh"
    sleep 5
    if ! nslookup cdn.jsdelivr.net 127.0.0.1 >/dev/null 2>&1; then
        echo "Error: DNS still broken after running start.sh. Aborting filter update."
        exit 1
    fi
    echo "DNS restored successfully. Continuing with filter update..."
fi

echo "Downloading latest blocklists..."
> "$TMP_DEST"

for url in $BLOCKED_NAMES_SOURCES; do
    [ -z "$url" ] && continue
    echo " -> Fetching: $url"
    curl -sS -L "$url" >> "$TMP_DEST" || echo "Warning: Failed to fetch $url"
    echo "" >> "$TMP_DEST"
done

if [ -s "$TMP_DEST" ]; then
    mv "$TMP_DEST" "$FILTER_DEST"
    echo "Blocklists successfully merged and saved to $FILTER_DEST"
    
    # Signal dnscrypt-proxy to reload its blocklist without a full restart
    echo "Sending SIGHUP to dnscrypt-proxy to reload filters..."
    kill -HUP "$(pgrep dnscrypt-proxy)" 2>/dev/null || echo "Warning: dnscrypt-proxy not running, blocklist will apply on next start."
else
    echo "Error: Failed to download the blocklists or all responses were empty."
    rm -f "$TMP_DEST"
    exit 1
fi
