#!/bin/bash

# Monad Foundry Integration - Full Test Suite Runner

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
FAILED_TESTS=()

# Navigate to project root (parent of script/)
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  MONAD FOUNDRY INTEGRATION TESTS${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# ============================================================================
# FORGE TESTS
# ============================================================================
echo -e "${YELLOW}[FORGE TESTS]${NC}"

# Run forge test and capture output
# Exclude Mip contracts — they require specific profiles and are run by their own script, e.g test_mip3.sh
FORGE_OUTPUT=$(forge test --no-match-contract Mip 2>&1)

# Parse and display results
echo "$FORGE_OUTPUT" | while IFS= read -r line; do
    if [[ $line =~ ^\[PASS\] ]]; then
        test_name=$(echo "$line" | sed 's/\[PASS\] //' | cut -d'(' -f1 | xargs)
        echo -e "  ${GREEN}✓${NC} $test_name"
    elif [[ $line =~ ^\[FAIL ]]; then
        test_name=$(echo "$line" | sed 's/\[FAIL[^]]*\] //' | cut -d'(' -f1 | xargs)
        echo -e "  ${RED}✗${NC} $test_name"
    fi
done

# Count pass/fail
FORGE_PASSED=$(echo "$FORGE_OUTPUT" | grep -c '^\[PASS\]' || true)
FORGE_FAILED=$(echo "$FORGE_OUTPUT" | grep -c '^\[FAIL' || true)

PASSED=$((PASSED + FORGE_PASSED))
FAILED=$((FAILED + FORGE_FAILED))

# Track failed tests
if [[ $FORGE_FAILED -gt 0 ]]; then
    while IFS= read -r line; do
        test_name=$(echo "$line" | sed 's/\[FAIL[^]]*\] //' | cut -d'(' -f1 | xargs)
        FAILED_TESTS+=("forge: $test_name")
    done <<< "$(echo "$FORGE_OUTPUT" | grep '^\[FAIL')"
fi

echo ""

# ============================================================================
# CHISEL TESTS
# ============================================================================
echo -e "${YELLOW}[CHISEL TESTS]${NC}"

# Run chisel tests (no anvil needed)
for script in "$PROJECT_ROOT"/script/test/chisel/*.sh; do
    [[ -f "$script" ]] || continue
    script_name=$(basename "$script")

    if "$script" &>/tmp/chisel_test_output.txt; then
        echo -e "  ${GREEN}✓${NC} $script_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $script_name"
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("chisel: $script_name")
        tail -20 /tmp/chisel_test_output.txt
    fi
done

echo ""

# ============================================================================
# MIP-3 MEMORY TESTS
# ============================================================================
echo -e "${YELLOW}[MIP-3 MEMORY TESTS]${NC}"

MIP3_OUTPUT=$("$PROJECT_ROOT/script/forge/test_mip3.sh" 2>&1) || true

# Parse pass/fail from the mip3 script output
MIP3_PASSED=$(echo "$MIP3_OUTPUT" | grep -c 'PASS' || true)
MIP3_FAILED=$(echo "$MIP3_OUTPUT" | grep -c 'FAIL' || true)

# Display individual results
while IFS= read -r line; do
    if [[ $line =~ PASS ]]; then
        name=$(echo "$line" | sed 's/.*PASS //')
        echo -e "  ${GREEN}✓${NC} $name"
    elif [[ $line =~ FAIL ]]; then
        name=$(echo "$line" | sed 's/.*FAIL //')
        echo -e "  ${RED}✗${NC} $name"
        FAILED_TESTS+=("mip3: $name")
    fi
done <<< "$(echo "$MIP3_OUTPUT" | grep -E '(PASS|FAIL)')"

PASSED=$((PASSED + MIP3_PASSED))
FAILED=$((FAILED + MIP3_FAILED))

echo ""

# ============================================================================
# MIP-4 RESERVE BALANCE TESTS
# ============================================================================
echo -e "${YELLOW}[MIP-4 RESERVE BALANCE TESTS]${NC}"

MIP4_OUTPUT=$("$PROJECT_ROOT/script/forge/test_mip4.sh" 2>&1) || true

MIP4_PASSED=$(echo "$MIP4_OUTPUT" | grep -c 'PASS' || true)
MIP4_FAILED=$(echo "$MIP4_OUTPUT" | grep -c 'FAIL' || true)

while IFS= read -r line; do
    if [[ $line =~ PASS ]]; then
        name=$(echo "$line" | sed 's/.*PASS //')
        echo -e "  ${GREEN}✓${NC} $name"
    elif [[ $line =~ FAIL ]]; then
        name=$(echo "$line" | sed 's/.*FAIL //')
        echo -e "  ${RED}✗${NC} $name"
        FAILED_TESTS+=("mip4: $name")
    fi
done <<< "$(echo "$MIP4_OUTPUT" | grep -E '(PASS|FAIL)')"

PASSED=$((PASSED + MIP4_PASSED))
FAILED=$((FAILED + MIP4_FAILED))

echo ""

# ============================================================================
# ANVIL TESTS
# ============================================================================
echo -e "${YELLOW}[ANVIL TESTS]${NC}"

# Start anvil if not running
ANVIL_PID=""
if ! cast chain-id --rpc-url http://localhost:8545 &>/dev/null; then
    echo -e "  ${CYAN}Starting anvil --monad...${NC}"
    anvil --monad &>/dev/null &
    ANVIL_PID=$!
    sleep 2
    if ! cast chain-id --rpc-url http://localhost:8545 &>/dev/null; then
        echo -e "  ${RED}✗${NC} Failed to start anvil --monad"
        exit 1
    fi
fi

# Run anvil tests
for script in "$PROJECT_ROOT"/script/test/anvil/*.sh; do
    [[ -f "$script" ]] || continue
    script_name=$(basename "$script")

    if "$script" &>/tmp/anvil_test_output.txt; then
        echo -e "  ${GREEN}✓${NC} $script_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $script_name"
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("anvil: $script_name")
        tail -20 /tmp/anvil_test_output.txt
    fi
done

# Cleanup anvil if we started it
[[ -n "$ANVIL_PID" ]] && kill $ANVIL_PID 2>/dev/null

echo ""

# ============================================================================
# ANVIL FORK TESTS (uses separate anvil instance with Monad fork)
# ============================================================================
echo -e "${YELLOW}[ANVIL FORK TESTS]${NC}"

# Check if MONAD_RPC_URL is set or use default
MONAD_RPC_URL="${MONAD_RPC_URL:-https://rpc.monad.xyz}"

# Run fork tests (each script manages its own anvil fork instance)
for script in "$PROJECT_ROOT"/script/test/anvil/fork/*.sh; do
    [[ -f "$script" ]] || continue
    script_name=$(basename "$script")

    if MONAD_RPC_URL="$MONAD_RPC_URL" "$script" &>/tmp/anvil_fork_test_output.txt; then
        echo -e "  ${GREEN}✓${NC} $script_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $script_name"
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("anvil-fork: $script_name")
        cat /tmp/anvil_fork_test_output.txt
    fi
done

echo ""

# ============================================================================
# SUMMARY
# ============================================================================
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo -e "  ${RED}Failed:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}•${NC} $test"
    done
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
