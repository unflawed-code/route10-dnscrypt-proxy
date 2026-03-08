#!/bin/bash
# Test for TOML merging logic used in start.sh

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "=== Running TOML Merge Logic Test ==="

# 1. Setup temporary test files
TEST_DIR=$(mktemp -d)
BASE_TOML="$TEST_DIR/dnscrypt-proxy.toml"
CUSTOM_TOML="$TEST_DIR/custom.toml"
RUN_CONFIG="$TEST_DIR/dnscrypt-proxy.run.toml"

cat > "$BASE_TOML" <<EOF
server_names = ['cloudflare']
listen_addresses = ['127.0.0.1:5059']
ipv6_servers = true

[sources]
  [sources.'public-resolvers']
  urls = ['https://example.com']
EOF

cat > "$CUSTOM_TOML" <<EOF
server_names = ['custom-dns']

[anonymized_dns]
routes = [
    { server_name='custom-dns', via=['anon-proxy'] }
]
EOF

# 2. Execute the exact logic from start.sh
echo "Testing merge logic..."

# 1. Extract and place CUSTOM root keys first
awk '/^\[/ {exit} {print}' "$CUSTOM_TOML" > "$RUN_CONFIG" 2>/dev/null || true

# 2. Extract and place BASE root keys (minus overrides)
awk '/^\[/ {exit} {print}' "$BASE_TOML" | \
    grep -v '^server_names =' >> "$RUN_CONFIG" 2>/dev/null || true

# 3. Append BASE sections
echo -e "\n# --- BASE SECTIONS ---" >> "$RUN_CONFIG"
sed -n '/^\[/,$p' "$BASE_TOML" >> "$RUN_CONFIG" 2>/dev/null || true

# 4. Append CUSTOM sections
echo -e "\n# --- CUSTOM SECTIONS ---" >> "$RUN_CONFIG"
sed -n '/^\[/,$p' "$CUSTOM_TOML" >> "$RUN_CONFIG" 2>/dev/null || true

# 3. Verifications
FAILED=0

# Check if custom server_names exists at the top
if grep -q "server_names = \['custom-dns'\]" "$RUN_CONFIG"; then
    echo -e "${GREEN}[PASS]${NC} Custom server_names present."
else
    echo -e "${RED}[FAIL]${NC} Custom server_names missing."
    FAILED=1
fi

# Check if base server_names is gone
if grep -q "server_names = \['cloudflare'\]" "$RUN_CONFIG"; then
    echo -e "${RED}[FAIL]${NC} Base server_names still present (should be overridden)."
    FAILED=1
else
    echo -e "${GREEN}[PASS]${NC} Base server_names successfully overridden."
fi

# Check if base listen_addresses is preserved
if grep -q "listen_addresses = \['127.0.0.1:5059'\]" "$RUN_CONFIG"; then
    echo -e "${GREEN}[PASS]${NC} Base listen_addresses preserved."
else
    echo -e "${RED}[FAIL]${NC} Base listen_addresses lost."
    FAILED=1
fi

# Check if [sources] section from base exists
if grep -q "\[sources\]" "$RUN_CONFIG"; then
    echo -e "${GREEN}[PASS]${NC} Base sections preserved."
else
    echo -e "${RED}[FAIL]${NC} Base sections lost."
    FAILED=1
fi

# Check if [anonymized_dns] section from custom exists
if grep -q "\[anonymized_dns\]" "$RUN_CONFIG"; then
    echo -e "${GREEN}[PASS]${NC} Custom sections included."
else
    echo -e "${RED}[FAIL]${NC} Custom sections missing."
    FAILED=1
fi

# 4. Final Result
if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}=== ALL TESTS PASSED ===${NC}"
    rm -rf "$TEST_DIR"
    exit 0
else
    echo -e "\n${RED}=== TESTS FAILED ===${NC}"
    echo "Generated config for review: $RUN_CONFIG"
    exit 1
fi
