#!/bin/ash
# Route10 DNSCrypt-Proxy Setup Script
# Downloads, extracts, and configures dnscrypt-proxy for OpenWrt (ARMv8/aarch64)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/setup.conf"
VERSION="v1.0.0"

if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "Error: setup.conf not found in $SCRIPT_DIR!"
    exit 1
fi

# Default release archive name if not specified in setup.conf
RELEASE_ARCHIVE_NAME="${RELEASE_ARCHIVE_NAME:-route10-dnscrypt-proxy-arm64.tar.gz}"

echo "=== Route10 DNSCrypt-Proxy Setup ($VERSION) ==="

COMPILED_BINARY="$SCRIPT_DIR/dnscrypt-proxy"
SKIP_DOWNLOAD=0

if [ -f "$COMPILED_BINARY" ]; then
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

if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
    # 1. Prepare temp directory
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR"

    # 2. Download and extract DNSCrypt-Proxy
    echo "Downloading DNSCrypt-Proxy v${DNSCRYPT_VERSION}..."
    curl -L -s -o dnscrypt.tar.gz "$DNSCRYPT_DOWNLOAD_URL"
    
    echo "Extracting DNSCrypt-Proxy..."
    tar -xzf dnscrypt.tar.gz
    cp linux-arm64/dnscrypt-proxy ./dnscrypt-proxy

    # 3. Optional: Download UPX and compress binary to save space
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

    # 4. Install binary to current directory
    echo "Installing dnscrypt-proxy to ${SCRIPT_DIR}..."
    cp ./dnscrypt-proxy "$SCRIPT_DIR/"
    chmod +x "$SCRIPT_DIR/dnscrypt-proxy"
    
    # 5. Clean up temp files
    echo "Cleaning up temp files..."
    cd /
    rm -rf "$TMP_DIR"
fi

# 6. Ensure start script and binary are executable
chmod +x "$SCRIPT_DIR/start.sh"
chmod +x "$SCRIPT_DIR/dnscrypt-proxy" 2>/dev/null || true

# 7. Compress and save release artifact
echo "Compressing installed files for backup/release in $TMP_DIR..."
# Clean up any existing archive in the repo to save flash space
rm -f "$SCRIPT_DIR/$RELEASE_ARCHIVE_NAME"
# Ensure TMP_DIR exists
mkdir -p "$TMP_DIR"
cd "$SCRIPT_DIR"
tar -czf "$TMP_DIR/$RELEASE_ARCHIVE_NAME" dnscrypt-proxy dnscrypt-proxy.toml start.sh setup.sh setup.conf LICENSE

# 9. Configure post-cfg.sh integration
echo "Configuring boot integration in $POST_CFG..."

if [ ! -f "$POST_CFG" ]; then
    echo "Creating new $POST_CFG..."
    echo "#!/bin/ash" > "$POST_CFG"
    chmod 700 "$POST_CFG"
fi

# Check if the dns script is already in post-cfg.sh
if ! grep -q "$SCRIPT_DIR/start.sh" "$POST_CFG"; then
    tmp_post=$(mktemp)
    awk -v cmd="$SCRIPT_DIR/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &" 'NR==1 {print; print "\n    # Start DNSCrypt-Proxy in background after boot\n    # "cmd"\n"; next} 1' "$POST_CFG" > "$tmp_post"
    cat "$tmp_post" > "$POST_CFG"
    rm -f "$tmp_post"
    echo "Added DNSCrypt startup hook to $POST_CFG (commented out by default, backgrounded)."
else
    echo "DNSCrypt startup hook already exists in $POST_CFG."
fi

echo "=== Setup Complete ==="
echo "DNSCrypt-Proxy is installed in $SCRIPT_DIR."
echo "Backup archive saved as $TMP_DIR/$RELEASE_ARCHIVE_NAME"
echo "To enable on boot, uncomment '$SCRIPT_DIR/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &' in $POST_CFG."
