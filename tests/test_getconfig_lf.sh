#!/bin/ash
# Diagnostic test for get_config on the router. Run from /cfg/dnscrypt-proxy.
# Tests that get_config reads from setup.run.toml (when present) or falls back to setup.toml.

SCRIPT_DIR=/cfg/dnscrypt-proxy
. "$SCRIPT_DIR/lib/common.sh"

echo "=== Testing get_config ==="

# Build the merged setup config first (creates setup.run.toml if setup-custom.toml is present)
build_setup_run_config

echo "--- Test 1: version ---"
result=$(get_config ".dnscrypt.version")
echo "VERSION: '$result'"

echo "--- Test 2: filter_dir ---"
result=$(get_config ".settings.filter_dir")
echo "FILTER_DIR: '$result'"

echo "--- Test 3: blocked_names (array) ---"
result=$(get_config ".sources.blocked_names")
echo "BLOCKED_NAMES: ($(echo "$result" | wc -l | tr -d ' ') URLs)"

echo "--- Test 4: setup.run.toml presence ---"
if [ -f "/tmp/dnscrypt-proxy/setup.run.toml" ]; then
    echo "setup.run.toml EXISTS (setup-custom.toml override is active)"
else
    echo "setup.run.toml absent (reading setup.toml directly)"
fi

echo "--- Test 5: raw Lua parse ---"
LUA_PATH="$SCRIPT_DIR/lib/?.lua;;" lua -e "
    local toml = require('toml')
    local status, data = pcall(toml.parse, '$SCRIPT_DIR/setup.toml')
    if not status then print('PARSE ERROR: ' .. tostring(data)); os.exit(1) end
    print('version: ' .. tostring(data.dnscrypt.version))
    if data.sources and data.sources.blocked_names then
        for _, v in ipairs(data.sources.blocked_names) do print('source: ' .. v) end
    else
        print('NO SOURCES FOUND')
    end
"
echo "=== Done ==="
