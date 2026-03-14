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

# Keep script parsing stable when using Monad nightly builds.
export FOUNDRY_DISABLE_NIGHTLY_WARNING="${FOUNDRY_DISABLE_NIGHTLY_WARNING:-1}"

is_rate_limited_file() {
    local logfile="$1"
    grep -Eq '429|Too Many Requests' "$logfile"
}

run_and_capture() {
    local logfile="$1"
    shift

    "$@" 2>&1 | tee "$logfile"
    return ${PIPESTATUS[0]}
}

run_forge_tests_with_retry() {
    local logfile="$1"
    local max_retries=3
    local attempt=1
    local status=0

    while [ $attempt -le $max_retries ]; do
        : >"$logfile"
        forge test --no-match-contract Mip 2>&1 | tee "$logfile"
        status=${PIPESTATUS[0]}

        if [ $status -eq 0 ]; then
            return 0
        fi

        if ! is_rate_limited_file "$logfile"; then
            return $status
        fi

        echo "  forge test hit RPC rate limits; retrying ($attempt/$max_retries)..." >&2
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
    done

    return $status
}

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
FORGE_LOG=$(mktemp)
run_forge_tests_with_retry "$FORGE_LOG"
FORGE_OUTPUT=$(cat "$FORGE_LOG")
rm -f "$FORGE_LOG"

# Count pass/fail
FORGE_PASSED=$(echo "$FORGE_OUTPUT" | grep -c '^\[PASS\]' || true)
FORGE_FAILED=$(echo "$FORGE_OUTPUT" | grep -c '^\[FAIL' || true)

PASSED=$((PASSED + FORGE_PASSED))
FAILED=$((FAILED + FORGE_FAILED))

echo -e "  Forge summary: ${GREEN}${FORGE_PASSED} passed${NC}, ${RED}${FORGE_FAILED} failed${NC}"

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
    output_file=$(mktemp)

    echo "  Running $script_name..."

    if run_and_capture "$output_file" "$script"; then
        echo -e "  ${GREEN}✓${NC} $script_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $script_name"
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("chisel: $script_name")
    fi
    rm -f "$output_file"
done

echo ""

# ============================================================================
# MIP-3 MEMORY TESTS
# ============================================================================
echo -e "${YELLOW}[MIP-3 MEMORY TESTS]${NC}"

MIP3_LOG=$(mktemp)
run_and_capture "$MIP3_LOG" "$PROJECT_ROOT/script/forge/test_mip3.sh" || true
MIP3_OUTPUT=$(cat "$MIP3_LOG")
rm -f "$MIP3_LOG"

# Parse pass/fail from the mip3 script output
MIP3_PASSED=$(echo "$MIP3_OUTPUT" | grep -c 'PASS' || true)
MIP3_FAILED=$(echo "$MIP3_OUTPUT" | grep -c 'FAIL' || true)

PASSED=$((PASSED + MIP3_PASSED))
FAILED=$((FAILED + MIP3_FAILED))

echo -e "  MIP-3 summary: ${GREEN}${MIP3_PASSED} passed${NC}, ${RED}${MIP3_FAILED} failed${NC}"

if [[ $MIP3_FAILED -gt 0 ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name=$(echo "$line" | sed 's/.*FAIL //')
        FAILED_TESTS+=("mip3: $name")
    done <<< "$(echo "$MIP3_OUTPUT" | grep 'FAIL' || true)"
fi

echo ""

# ============================================================================
# MIP-4 RESERVE BALANCE TESTS
# ============================================================================
echo -e "${YELLOW}[MIP-4 RESERVE BALANCE TESTS]${NC}"

MIP4_LOG=$(mktemp)
run_and_capture "$MIP4_LOG" "$PROJECT_ROOT/script/forge/test_mip4.sh" || true
MIP4_OUTPUT=$(cat "$MIP4_LOG")
rm -f "$MIP4_LOG"

MIP4_PASSED=$(echo "$MIP4_OUTPUT" | grep -c 'PASS' || true)
MIP4_FAILED=$(echo "$MIP4_OUTPUT" | grep -c 'FAIL' || true)

PASSED=$((PASSED + MIP4_PASSED))
FAILED=$((FAILED + MIP4_FAILED))

echo -e "  MIP-4 summary: ${GREEN}${MIP4_PASSED} passed${NC}, ${RED}${MIP4_FAILED} failed${NC}"

if [[ $MIP4_FAILED -gt 0 ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name=$(echo "$line" | sed 's/.*FAIL //')
        FAILED_TESTS+=("mip4: $name")
    done <<< "$(echo "$MIP4_OUTPUT" | grep 'FAIL' || true)"
fi

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
    output_file=$(mktemp)

    echo "  Running $script_name..."

    if run_and_capture "$output_file" "$script"; then
        echo -e "  ${GREEN}✓${NC} $script_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $script_name"
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("anvil: $script_name")
    fi
    rm -f "$output_file"
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
    output_file=$(mktemp)

    echo "  Running $script_name..."

    if run_and_capture "$output_file" env MONAD_RPC_URL="$MONAD_RPC_URL" "$script"; then
        echo -e "  ${GREEN}✓${NC} $script_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $script_name"
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("anvil-fork: $script_name")
    fi
    rm -f "$output_file"
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
