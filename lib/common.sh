#!/bin/ash
# Shared utilities and configuration for Route10 DNSCrypt-Proxy scripts

# This script is intended to be sourced by other scripts in the project.
# It handles common tasks related to volatile system files and folders.

log() {
    echo "$@"
}

# Build a merged setup config from conf/setup.toml + conf/setup-custom.toml (if present).
# Output: /tmp/dnscrypt-proxy/setup.run.toml
# If setup-custom.toml is absent, no merged file is written (setup.toml is used directly).
build_setup_run_config() {
    local base="$SCRIPT_DIR/conf/setup.toml"
    local custom="$SCRIPT_DIR/conf/setup-custom.toml"
    local run_config="/tmp/dnscrypt-proxy/setup.run.toml"

    [ -f "$base" ] || return 0

    mkdir -p /tmp/dnscrypt-proxy

    if [ -f "$custom" ]; then
        log "Merging setup-custom.toml overrides into setup.run.toml..."
        rm -f "$run_config"

        # Root-level keys: custom first, then base (minus any keys the custom already defines)
        awk '/^\[/ {exit} {print}' "$custom" > "$run_config" 2>/dev/null || true

        # Collect the key names defined in custom's root section
        local custom_root_keys
        custom_root_keys=$(awk '/^\[/ {exit} /^[a-zA-Z]/ {sub(/ *=.*/, ""); print}' "$custom" 2>/dev/null || true)

        # Append base root keys, skipping any already defined by custom
        awk '/^\[/ {exit} {print}' "$base" | \
            while IFS= read -r line; do
                local skip=0
                for ck in $custom_root_keys; do
                    case "$line" in
                        "${ck} ="*|"${ck}="*) skip=1; break ;;
                    esac
                done
                [ "$skip" -eq 0 ] && echo "$line"
            done >> "$run_config" 2>/dev/null || true

        echo "" >> "$run_config"
        echo "# --- BASE SECTIONS ---" >> "$run_config"
        sed -n '/^\[/,$p' "$base" >> "$run_config" 2>/dev/null || true

        echo "" >> "$run_config"
        echo "# --- CUSTOM SECTIONS ---" >> "$run_config"
        sed -n '/^\[/,$p' "$custom" >> "$run_config" 2>/dev/null || true
    else
        # No custom override; remove any stale merged file so get_config reads setup.toml
        rm -f "$run_config"
    fi
}

# Helper to read configuration from conf/setup.toml (or setup.run.toml if present)
# Usage: get_config ".key.path" [default_value]
get_config() {
    local key="$1"
    local default="${2:-}"
    local value
    local toml_file

    # Prefer the merged run config when it exists (built by build_setup_run_config)
    if [ -f "/tmp/dnscrypt-proxy/setup.run.toml" ]; then
        toml_file="/tmp/dnscrypt-proxy/setup.run.toml"
    elif [ -f "$SCRIPT_DIR/conf/setup.toml" ]; then
        toml_file="$SCRIPT_DIR/conf/setup.toml"
    else
        echo "$default"
        return
    fi

    # SCRIPT_DIR is expected to be defined by the caller (project root)
    if [ -f "$SCRIPT_DIR/lib/get_config.lua" ]; then
        value=$(LUA_PATH="$SCRIPT_DIR/lib/?.lua;;" lua "$SCRIPT_DIR/lib/get_config.lua" "$toml_file" "$key" 2>/dev/null)

        if [ -z "$value" ]; then
            echo "$default"
        else
            echo "$value"
        fi
    else
        echo "$default"
    fi
}

# Ensure volatile directories and configuration persist after reboot
setup_system_integration() {
    local script_dir="$1"

    # Ensure logrotate state directory exists (volatile /var/lib)
    if [ ! -d "/var/lib" ]; then
        log "Creating /var/lib for logrotate state..."
        mkdir -p /var/lib
    fi
    # Ensure temporary runtime directory exists (volatile /tmp)
    if [ ! -d "/tmp/dnscrypt-proxy" ]; then
        log "Creating /tmp/dnscrypt-proxy for runtime configuration..."
        mkdir -p /tmp/dnscrypt-proxy
    fi

    # Ensure logrotate config is installed (survives reboot if /etc is volatile)
    local logrotate_src="$script_dir/conf/dnscrypt-proxy.logrotate"
    local logrotate_dest="/etc/logrotate.d/dnscrypt-proxy"

    if [ -f "$logrotate_src" ]; then
        if [ ! -f "$logrotate_dest" ] || ! cmp -s "$logrotate_src" "$logrotate_dest"; then
            log "Configuring system logrotate integration..."
            cp "$logrotate_src" "$logrotate_dest"
            chmod 644 "$logrotate_dest"
        fi
    fi
}
