#!/bin/sh
# Test for TOML merging logic used in start.sh and common.sh

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILED=1; }
section() { echo -e "\n${YELLOW}--- $1 ---${NC}"; }

# ---------------------------------------------------------------------------
# Shared merge function (mirrors start.sh build_run_config logic)
# ---------------------------------------------------------------------------
merge_proxy_config() {
    local base="$1"
    local custom1="$2"
    local custom2="$3"
    local run_config="$4"

    rm -f "$run_config"

    # --- ROOT KEYS LAYER ---
    if [ -f "$custom2" ]; then
        awk '/^\[/ {exit} {print}' "$custom2" > "$run_config" 2>/dev/null || true
    fi

    _get_keys() {
        [ -f "$1" ] || return
        awk '/^\[/ {exit} /^[a-z_]+[ ]*=/ {split($1, a, "="); print a[1]}' "$1" | tr -d ' '
    }

    if [ -f "$custom1" ]; then
        local existing_keys=$(_get_keys "$run_config")
        if [ -n "$existing_keys" ]; then
            local pattern=$(echo "$existing_keys" | sed 's/^/^/; s/$/ =/' | tr '\n' '|')
            awk '/^\[/ {exit} {print}' "$custom1" | grep -vE "${pattern%|}" >> "$run_config" 2>/dev/null || true
        else
            awk '/^\[/ {exit} {print}' "$custom1" >> "$run_config" 2>/dev/null || true
        fi
    fi

    local existing_keys=$(_get_keys "$run_config")
    if [ -n "$existing_keys" ]; then
        local pattern=$(echo "$existing_keys" | sed 's/^/^/; s/$/ =/' | tr '\n' '|')
        awk '/^\[/ {exit} {print}' "$base" | grep -vE "${pattern%|}" >> "$run_config" 2>/dev/null || true
    else
        awk '/^\[/ {exit} {print}' "$base" >> "$run_config" 2>/dev/null || true
    fi

    # --- SECTIONS LAYER ---
    echo -e "\n# --- BASE SECTIONS ---" >> "$run_config"
    sed -n '/^\[/,$p' "$base" >> "$run_config" 2>/dev/null || true

    if [ -f "$custom1" ]; then
        echo -e "\n# --- CUSTOM.TOML SECTIONS ---" >> "$run_config"
        sed -n '/^\[/,$p' "$custom1" >> "$run_config" 2>/dev/null || true
    fi

    if [ -f "$custom2" ]; then
        echo -e "\n# --- DNSCRYPT-PROXY-CUSTOM.TOML SECTIONS ---" >> "$run_config"
        sed -n '/^\[/,$p' "$custom2" >> "$run_config" 2>/dev/null || true
    fi
}

# Shared setup config merge function (mirrors common.sh build_setup_run_config logic)
merge_setup_config() {
    local base_toml="$1"
    local custom_toml="$2"
    local run_config="$3"

    rm -f "$run_config"
    if [ -f "$custom_toml" ]; then
        awk '/^\[/ {exit} {print}' "$custom_toml" > "$run_config" 2>/dev/null || true
        local custom_root_keys
        custom_root_keys=$(awk '/^\[/ {exit} /^[a-zA-Z]/ {sub(/ *=.*/, ""); print}' "$custom_toml" 2>/dev/null || true)
        awk '/^\[/ {exit} {print}' "$base_toml" | \
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
        sed -n '/^\[/,$p' "$base_toml" >> "$run_config" 2>/dev/null || true
        echo "" >> "$run_config"
        echo "# --- CUSTOM SECTIONS ---" >> "$run_config"
        sed -n '/^\[/,$p' "$custom_toml" >> "$run_config" 2>/dev/null || true
    else
        cp "$base_toml" "$run_config"
    fi
}

# ---------------------------------------------------------------------------
# Test Scenario 1: custom.toml overrides dnscrypt-proxy.toml (baseline)
# ---------------------------------------------------------------------------
section "Scenario 1: custom.toml overrides dnscrypt-proxy.toml"

T1=$(mktemp -d)
cat > "$T1/dnscrypt-proxy.toml" <<'EOF'
server_names = ['cloudflare']
listen_addresses = ['127.0.0.1:5059']
ipv6_servers = true

[sources]
  [sources.'public-resolvers']
  urls = ['https://example.com']
EOF

cat > "$T1/custom.toml" <<'EOF'
server_names = ['custom-dns']

[anonymized_dns]
routes = [
    { server_name='custom-dns', via=['anon-proxy'] }
]
EOF

merge_proxy_config "$T1/dnscrypt-proxy.toml" "$T1/custom.toml" "" "$T1/run.toml"

grep -q "server_names = \['custom-dns'\]" "$T1/run.toml" && pass "Custom server_names present" || fail "Custom server_names missing"
grep -q "server_names = \['cloudflare'\]" "$T1/run.toml" && fail "Base server_names still present (should be overridden)" || pass "Base server_names correctly removed"
grep -q "listen_addresses = \['127.0.0.1:5059'\]" "$T1/run.toml" && pass "Base listen_addresses preserved" || fail "Base listen_addresses lost"
grep -q "\[sources\]" "$T1/run.toml" && pass "Base [sources] section preserved" || fail "Base [sources] section lost"
grep -q "\[anonymized_dns\]" "$T1/run.toml" && pass "Custom [anonymized_dns] section included" || fail "Custom [anonymized_dns] section missing"
rm -rf "$T1"

# ---------------------------------------------------------------------------
# Test Scenario 2: dnscrypt-proxy-custom.toml takes precedence over custom.toml
# ---------------------------------------------------------------------------
section "Scenario 2: dnscrypt-proxy-custom.toml takes precedence over custom.toml"

T2=$(mktemp -d)
cat > "$T2/dnscrypt-proxy.toml" <<'EOF'
server_names = ['cloudflare']
listen_addresses = ['127.0.0.1:5059']

[sources]
  [sources.'public-resolvers']
  urls = ['https://example.com']
EOF

cat > "$T2/custom.toml" <<'EOF'
server_names = ['custom-dns']

[anonymized_dns]
routes = [
    { server_name='custom-dns', via=['anon-proxy'] }
]
EOF

cat > "$T2/dnscrypt-proxy-custom.toml" <<'EOF'
server_names = ['device-specific-dns']

[anonymized_dns]
routes = [
    { server_name='device-specific-dns', via=['anon-device'] }
]
EOF

# Test layered merge (Base + Custom1 + Custom2)
merge_proxy_config "$T2/dnscrypt-proxy.toml" "$T2/custom.toml" "$T2/dnscrypt-proxy-custom.toml" "$T2/run.toml"

grep -q "server_names = \['device-specific-dns'\]" "$T2/run.toml" && pass "dnscrypt-proxy-custom.toml server_names used" || fail "dnscrypt-proxy-custom.toml server_names missing"
grep -q "server_names = \['custom-dns'\]" "$T2/run.toml" && fail "custom.toml server_names should be overridden by dnscrypt-proxy-custom.toml" || pass "custom.toml server_names correctly overridden"
grep -q "server_names = \['cloudflare'\]" "$T2/run.toml" && fail "Base server_names should be overridden" || pass "Base server_names correctly overridden"

# Verify sections from both are present (concatenated)
grep -q "anon-device" "$T2/run.toml" && pass "dnscrypt-proxy-custom.toml [anonymized_dns] present" || fail "dnscrypt-proxy-custom.toml [anonymized_dns] missing"
grep -q "anon-proxy" "$T2/run.toml" && pass "custom.toml [anonymized_dns] section also present (merged via concatenation)" || fail "custom.toml [anonymized_dns] section missing"
rm -rf "$T2"

# ---------------------------------------------------------------------------
# Test Scenario 3: No override file — dnscrypt-proxy.toml copied as-is
# ---------------------------------------------------------------------------
section "Scenario 3: No override — dnscrypt-proxy.toml copied as-is"

T3=$(mktemp -d)
cat > "$T3/dnscrypt-proxy.toml" <<'EOF'
server_names = ['cloudflare']
listen_addresses = ['127.0.0.1:5059']
EOF

merge_proxy_config "$T3/dnscrypt-proxy.toml" "" "" "$T3/run.toml"

grep -q "server_names = \['cloudflare'\]" "$T3/run.toml" && pass "Base server_names preserved (no override)" || fail "Base server_names missing (no override)"
grep -q "listen_addresses = \['127.0.0.1:5059'\]" "$T3/run.toml" && pass "Base listen_addresses preserved (no override)" || fail "Base listen_addresses missing (no override)"
rm -rf "$T3"

# ---------------------------------------------------------------------------
# Test Scenario 4: setup-custom.toml overrides setup.toml sections
# ---------------------------------------------------------------------------
section "Scenario 4: setup-custom.toml overrides setup.toml"

T4=$(mktemp -d)
cat > "$T4/setup.toml" <<'EOF'
[settings]
filter_dir = "/a/dnscrypt-proxy"
block_logging = "0"
compress_binary = "1"

[sources]
blocked_names = [
    "https://example.com/blocklist.txt"
]
EOF

cat > "$T4/setup-custom.toml" <<'EOF'
[settings]
filter_dir = "/custom/path"
EOF

merge_setup_config "$T4/setup.toml" "$T4/setup-custom.toml" "$T4/run.toml"

# Both [settings] blocks will be present; the custom one at the end overrides per tinytoml merge behaviour
grep -q "filter_dir = \"/custom/path\"" "$T4/run.toml" && pass "setup-custom.toml filter_dir present in merged file" || fail "setup-custom.toml filter_dir missing from merged file"
grep -q "block_logging = \"0\"" "$T4/run.toml" && pass "Base block_logging preserved" || fail "Base block_logging lost"
grep -q "\[sources\]" "$T4/run.toml" && pass "Base [sources] section preserved" || fail "Base [sources] section lost"
grep -q "CUSTOM SECTIONS" "$T4/run.toml" && pass "Custom sections marker present" || fail "Custom sections marker missing"
rm -rf "$T4"

# ---------------------------------------------------------------------------
# Test Scenario 5: setup-custom.toml absent — setup.toml used directly
# ---------------------------------------------------------------------------
section "Scenario 5: No setup-custom.toml — setup.toml used directly"

T5=$(mktemp -d)
cat > "$T5/setup.toml" <<'EOF'
[settings]
filter_dir = "/a/dnscrypt-proxy"
EOF

# No custom file — merge_setup_config should just copy base
merge_setup_config "$T5/setup.toml" "$T5/nonexistent-custom.toml" "$T5/run.toml"

grep -q "filter_dir = \"/a/dnscrypt-proxy\"" "$T5/run.toml" && pass "Base filter_dir present when no custom file" || fail "Base filter_dir missing when no custom file"
# Ensure no custom sections marker was added
grep -q "CUSTOM SECTIONS" "$T5/run.toml" && fail "Custom sections marker should not appear when no custom file" || pass "No spurious custom sections marker"
rm -rf "$T5"

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}=== ALL TESTS PASSED ===${NC}"
    exit 0
else
    echo -e "${RED}=== TESTS FAILED ===${NC}"
    exit 1
fi
