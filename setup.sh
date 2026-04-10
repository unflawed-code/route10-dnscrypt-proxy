#!/bin/ash
# Route10 DNSCrypt-Proxy Setup Script
# Downloads, extracts, and configures dnscrypt-proxy for OpenWrt (ARMv8/aarch64)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="v1.1.0"
CRON_FILE="/etc/crontabs/root"
UPDATER_CRON=""
FILTER_CRON=""
BOOT_HOOK_CMD="$SCRIPT_DIR/proxy.sh start >/var/log/dnscrypt-proxy-boot.log 2>&1 &"
BOOT_HOOK_PREFIX="# "
NON_INTERACTIVE=0
SKIP_DOWNLOAD=0

normalize_crlf_file() {
    [ -f "$1" ] || return 0
    sed -i 's/\r$//' "$1" 2>/dev/null || true
}

normalize_project_line_endings() {
    local candidate

    for candidate in \
        "${SCRIPT_DIR}/"*.sh \
        "${SCRIPT_DIR}/"*.toml \
        "${SCRIPT_DIR}/"*.lua \
        "${SCRIPT_DIR}/conf/"*.sh \
        "${SCRIPT_DIR}/conf/"*.toml \
        "${SCRIPT_DIR}/conf/"*.lua \
        "${SCRIPT_DIR}/conf/"*.txt \
        "${SCRIPT_DIR}/conf/"*.logrotate \
        "${SCRIPT_DIR}/lib/"*.sh \
        "${SCRIPT_DIR}/lib/"*.toml \
        "${SCRIPT_DIR}/lib/"*.lua \
        "${SCRIPT_DIR}/scripts/"*.sh \
        "${SCRIPT_DIR}/scripts/"*.toml \
        "${SCRIPT_DIR}/scripts/"*.lua
    do
        [ -f "$candidate" ] || continue
        normalize_crlf_file "$candidate"
    done
}

normalize_project_line_endings

cron_or_default() {
    local value="$1"
    local fallback="$2"
    local key_name="${3:-cron}"

    # BusyBox cron expects exactly 5 schedule fields.
    if [ -z "$value" ]; then
        echo "$fallback"
        return 0
    fi

    if [ "$(printf '%s\n' "$value" | awk '{ print NF }')" = "5" ]; then
        echo "$value"
    else
        echo "Warning: Invalid cron expression for $key_name ('$value'). Falling back to '$fallback'." >&2
        echo "$fallback"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --non-interactive|-n)
            NON_INTERACTIVE=1
            ;;
        --keep-binary)
            SKIP_DOWNLOAD=1
            ;;
        --skip-download)
            SKIP_DOWNLOAD=1
            ;;
        *)
            ;;
    esac
    shift
done

if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    . "$SCRIPT_DIR/lib/common.sh"
else
    echo "Error: common.sh not found!"
    exit 1
fi

# Build merged setup config (setup.toml + setup-custom.toml if present)
build_setup_run_config

# Load configuration from TOML
DNSCRYPT_VERSION=$(get_config ".dnscrypt.version" "2.1.15")
DNSCRYPT_DOWNLOAD_URL=$(get_config ".dnscrypt.download_url" "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VERSION}/dnscrypt-proxy-linux_arm64-${DNSCRYPT_VERSION}.tar.gz")
UPX_VERSION=$(get_config ".upx.version" "5.1.1")
UPX_DOWNLOAD_URL=$(get_config ".upx.download_url" "https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-arm64_linux.tar.xz")
COMPRESS_BINARY=$(get_config ".settings.compress_binary" "1")
TMP_DIR=$(get_config ".settings.tmp_dir" "/tmp/dnscrypt-setup")
POST_CFG=$(get_config ".settings.post_cfg" "/cfg/post-cfg.sh")
FILTER_UPDATE_CRON=$(get_config ".settings.filter_update_cron" "0 4 * * *")
ENABLE_AUTO_UPDATE=$(get_config ".settings.enable_auto_update" "0")
UPDATER_CHECK_CRON=$(get_config ".settings.updater_check_cron" "35 4 * * *")
FILTER_UPDATE_CRON="$(cron_or_default "$FILTER_UPDATE_CRON" "0 4 * * *" "settings.filter_update_cron")"
UPDATER_CHECK_CRON="$(cron_or_default "$UPDATER_CHECK_CRON" "35 4 * * *" "settings.updater_check_cron")"
UPDATER_CRON="$UPDATER_CHECK_CRON /bin/ash $SCRIPT_DIR/proxy.sh updater check >/dev/null 2>&1"
FILTER_CRON="$FILTER_UPDATE_CRON /bin/ash $SCRIPT_DIR/proxy.sh update-filters -f >/dev/null 2>&1"

is_enabled() {
    case "${1:-0}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

update_uci_version() {
    command -v uci >/dev/null 2>&1 || return 0
    [ -f "/etc/config/dnscrypt-proxy" ] || touch "/etc/config/dnscrypt-proxy"
    if ! uci -q get dnscrypt-proxy.system >/dev/null 2>&1; then
        uci set dnscrypt-proxy.system=system
    fi
    uci set dnscrypt-proxy.system.version="$VERSION"
    uci set dnscrypt-proxy.system.dnscrypt="$DNSCRYPT_VERSION"
    uci commit dnscrypt-proxy >/dev/null 2>&1 || true
}

# Default release archive name
RELEASE_ARCHIVE_NAME="route10-dnscrypt-proxy-arm64.tar.gz"

echo "=== Route10 DNSCrypt-Proxy Setup ($VERSION) ==="

COMPILED_BINARY="$SCRIPT_DIR/dnscrypt-proxy"

if [ -f "$COMPILED_BINARY" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$SKIP_DOWNLOAD" -eq 1 ]; then
        echo "Non-interactive mode: keeping existing dnscrypt-proxy binary."
        SKIP_DOWNLOAD=1
    else
        printf "Found existing compiled binary 'dnscrypt-proxy'. Overwrite it with a fresh download? [y/N]: "
        read -r overwrite_binary
        case "$overwrite_binary" in
            [nN]|[nN][oO]|"")
                echo "Skipping download and compilation. Using existing binary."
                SKIP_DOWNLOAD=1
                ;;
            *)
                echo "Overwriting existing binary..."
                ;;
        esac
    fi
fi

if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
    # Prepare temp directory
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR"

    # Download and extract DNSCrypt-Proxy
    echo "Downloading DNSCrypt-Proxy v${DNSCRYPT_VERSION}..."
    curl -L -s -o dnscrypt.tar.gz "$DNSCRYPT_DOWNLOAD_URL"
    
    echo "Extracting DNSCrypt-Proxy..."
    tar -xzf dnscrypt.tar.gz
    cp linux-arm64/dnscrypt-proxy ./dnscrypt-proxy

    # Optional: Download UPX and compress binary to save space
    if [ "$COMPRESS_BINARY" = "1" ]; then
        echo "Downloading UPX v${UPX_VERSION} for binary compression..."
        if curl -L -s -o upx.tar.xz "$UPX_DOWNLOAD_URL"; then
            echo "Extracting UPX..."
            # Busybox tar might need xz, fallback to unxz if available
            unxz -c upx.tar.xz | tar -xf - 2>/dev/null || tar -xf upx.tar.xz || echo "Warning: UPX extract failed"
            
            UPX_BIN="./upx-${UPX_VERSION}-arm64_linux/upx"
            if [ -x "$UPX_BIN" ]; then
                echo "Compressing dnscrypt-proxy binary (~15MB -> ~5MB)..."
                $UPX_BIN --best ./dnscrypt-proxy || true
            else
                echo "Warning: UPX binary not found or not executable. Skipping compression."
            fi
        else
            echo "Warning: Failed to download UPX. Skipping compression."
        fi
    fi

    # Install binary to current directory
    echo "Installing dnscrypt-proxy to ${SCRIPT_DIR}..."
    cp ./dnscrypt-proxy "$SCRIPT_DIR/"
    chmod +x "$SCRIPT_DIR/dnscrypt-proxy"
    
    # Clean up temp files
    echo "Cleaning up temp files..."
    cd /
    rm -rf "$TMP_DIR"
fi

# Ensure start script and binary are executable
chmod +x "$SCRIPT_DIR/proxy.sh" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/start.sh"
chmod +x "$SCRIPT_DIR/dnscrypt-proxy" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/update-filters.sh" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/updater.sh" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/uninstall.sh" 2>/dev/null || true

# Configure post-cfg.sh integration
echo "Configuring boot integration in $POST_CFG..."

if [ ! -f "$POST_CFG" ]; then
    echo "Creating new $POST_CFG..."
    echo "#!/bin/ash" > "$POST_CFG"
    chmod 700 "$POST_CFG"
fi

# Configure post-cfg.sh integration
echo "Configuring boot integration in $POST_CFG..."

if [ ! -f "$POST_CFG" ]; then
    echo "Creating new $POST_CFG..."
    echo "#!/bin/ash" > "$POST_CFG"
    chmod 700 "$POST_CFG"
fi

# Replace legacy boot entries with the canonical proxy entry
if grep -Eq "^[[:space:]]*${SCRIPT_DIR}/start\\.sh >/var/log/dnscrypt-proxy-boot\\.log 2>&1 &[[:space:]]*$|^[[:space:]]*${SCRIPT_DIR}/scripts/start\\.sh >/var/log/dnscrypt-proxy-boot\\.log 2>&1 &[[:space:]]*$|^[[:space:]]*${SCRIPT_DIR}/proxy\\.sh start >/var/log/dnscrypt-proxy-boot\\.log 2>&1 &[[:space:]]*$" "$POST_CFG"; then
    BOOT_HOOK_PREFIX=""
elif grep -Eq "^[[:space:]]*#[[:space:]]*${SCRIPT_DIR}/start\\.sh >/var/log/dnscrypt-proxy-boot\\.log 2>&1 &[[:space:]]*$|^[[:space:]]*#[[:space:]]*${SCRIPT_DIR}/scripts/start\\.sh >/var/log/dnscrypt-proxy-boot\\.log 2>&1 &[[:space:]]*$|^[[:space:]]*#[[:space:]]*${SCRIPT_DIR}/proxy\\.sh start >/var/log/dnscrypt-proxy-boot\\.log 2>&1 &[[:space:]]*$" "$POST_CFG"; then
    BOOT_HOOK_PREFIX="# "
fi

echo "Canonicalizing DNSCrypt boot hook in $POST_CFG..."
cp "$POST_CFG" "${POST_CFG}.bak"
tmp_clean=$(mktemp)
tmp_post=$(mktemp)

awk \
    -v root_entry="$SCRIPT_DIR/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &" \
    -v scripts_entry="$SCRIPT_DIR/scripts/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &" \
    -v proxy_entry="$BOOT_HOOK_CMD" '
    function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
    }
    {
        line = trim($0)
        if (line == "# Start DNSCrypt-Proxy in background after boot" || line == "Start DNSCrypt-Proxy in background after boot") next
        if (line == root_entry || line == "# " root_entry) next
        if (line == scripts_entry || line == "# " scripts_entry) next
        if (line == proxy_entry || line == "# " proxy_entry) next
        print
    }
' "$POST_CFG" > "$tmp_clean"

{
    head -n 1 "$tmp_clean"
    printf '\n%s\n%s%s\n\n' \
        "# Start DNSCrypt-Proxy in background after boot" \
        "$BOOT_HOOK_PREFIX" \
        "$BOOT_HOOK_CMD"
    tail -n +2 "$tmp_clean" | awk 'BEGIN { started = 0 } /[^[:space:]]/ { started = 1 } started { print }'
} | awk '{ lines[NR] = $0 } END { while (NR > 0 && lines[NR] ~ /^[[:space:]]*$/) NR--; for (i = 1; i <= NR; i++) print lines[i]; print "" }' > "$tmp_post"

if ! cmp -s "$POST_CFG" "$tmp_post" 2>/dev/null; then
    cat "$tmp_post" > "$POST_CFG"
    echo "Successfully updated $POST_CFG."
else
    echo "DNSCrypt startup hook already canonical."
fi

rm -f "$tmp_clean" "$tmp_post" "${POST_CFG}.bak"

# System integration (volatile files/dirs) is handled by common.sh
if command -v setup_system_integration >/dev/null 2>&1; then
    setup_system_integration "$SCRIPT_DIR"
fi

# Replace legacy cron entries with canonical proxy cron entries
if [ -f "$CRON_FILE" ]; then
    grep -Fv "proxy.sh updater check" "$CRON_FILE" 2>/dev/null | \
        grep -Fv "updater.sh check" | \
        grep -Fv "proxy.sh update-filters" | \
        grep -Fv "update-filters.sh -f" > "${CRON_FILE}.tmp" || true
    if is_enabled "$ENABLE_AUTO_UPDATE" && [ -f "$SCRIPT_DIR/scripts/updater.sh" ]; then
        echo "$UPDATER_CRON" >> "${CRON_FILE}.tmp"
    fi
    echo "$FILTER_CRON" >> "${CRON_FILE}.tmp"
    if ! cmp -s "$CRON_FILE" "${CRON_FILE}.tmp" 2>/dev/null; then
        mv "${CRON_FILE}.tmp" "$CRON_FILE"
        /etc/init.d/cron restart >/dev/null 2>&1 || true
        if is_enabled "$ENABLE_AUTO_UPDATE" && [ -f "$SCRIPT_DIR/scripts/updater.sh" ]; then
            echo "Configured updater cron: $UPDATER_CRON"
        else
            echo "Updater cron disabled (settings.enable_auto_update=$ENABLE_AUTO_UPDATE)"
        fi
        echo "Configured filter cron: $FILTER_CRON"
    else
        rm -f "${CRON_FILE}.tmp"
    fi
fi

update_uci_version

# Clean up temp files
if [ -d "$TMP_DIR" ]; then
    echo "Cleaning up temp files in $TMP_DIR..."
    rm -rf "$TMP_DIR"
fi

echo "=== Setup Complete ==="
echo "DNSCrypt-Proxy is installed in $SCRIPT_DIR."

# Only show the "uncomment" message if the hook is actually commented out
if grep -q "^[[:space:]]*#[[:space:]]*$SCRIPT_DIR/proxy.sh start" "$POST_CFG" && ! grep -q "^[[:space:]]*$SCRIPT_DIR/proxy.sh start" "$POST_CFG"; then
    echo "To enable on boot, uncomment '$SCRIPT_DIR/proxy.sh start >/var/log/dnscrypt-proxy-boot.log 2>&1 &' in $POST_CFG."
fi
