#!/bin/bash
#
# MIP-3 Integration Test Runner
#
# Runs the MIP-3 test suite under both Monad hardfork profiles and
# compares gas for the same memory probe (differential check).
#
# Usage: ./script/forge/test_mip3.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

cd "$(dirname "$0")/../.."

PASSED=0
FAILED=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAILED=$((FAILED + 1)); }

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  MIP-3 LINEAR MEMORY INTEGRATION TESTS${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# ==========================================================================
# Section 1: MonadNine exact assertions
# ==========================================================================
echo -e "${YELLOW}[MonadNine — Exact MIP-3 Assertions]${NC}"

NINE_OUTPUT=$(FOUNDRY_PROFILE=monad_nine forge test \
    --match-contract MonadNineMip3Test \
    -vv 2>&1) || true

# Parse results
while IFS= read -r line; do
    if [[ $line =~ \[PASS\] ]]; then
        name=$(echo "$line" | sed 's/\[PASS\] //' | cut -d'(' -f1 | xargs)
        pass "$name"
    elif [[ $line =~ \[FAIL ]]; then
        name=$(echo "$line" | sed 's/\[FAIL[^]]*\] //' | cut -d'(' -f1 | xargs)
        fail "$name"
    fi
done <<< "$NINE_OUTPUT"

echo ""

# ==========================================================================
# Section 2: MonadEight hardfork-gating
# ==========================================================================
echo -e "${YELLOW}[MonadEight — Hardfork-Gating Semantics]${NC}"

EIGHT_OUTPUT=$(FOUNDRY_PROFILE=monad_eight forge test \
    --match-contract MonadEightMip3RegressionTest \
    -vv 2>&1) || true

while IFS= read -r line; do
    if [[ $line =~ \[PASS\] ]]; then
        name=$(echo "$line" | sed 's/\[PASS\] //' | cut -d'(' -f1 | xargs)
        pass "$name"
    elif [[ $line =~ \[FAIL ]]; then
        name=$(echo "$line" | sed 's/\[FAIL[^]]*\] //' | cut -d'(' -f1 | xargs)
        fail "$name"
    fi
done <<< "$EIGHT_OUTPUT"

echo ""

# ==========================================================================
# Section 3: Differential gas comparison
# ==========================================================================
echo -e "${YELLOW}[Differential — MonadEight vs MonadNine Gas]${NC}"

# Helper: extract gas used for a specific test from forge output.
# Uses the "gas: N" field from the test result line.
# Compatible with macOS (no -P flag).
extract_gas() {
    local output="$1"
    local test_name="$2"
    echo "$output" | grep "$test_name" | sed -n 's/.*gas: \([0-9]*\).*/\1/p' | head -1
}

# Run the differential tests under both profiles.
# These are in the Mip3DifferentialTest contract.
DIFF_TESTS=("test_Differential_LargeMstore" "test_Differential_LargeMcopy" "test_Differential_HighOffsetCreate2")
DIFF_LABELS=("1 MB MSTORE" "1 MB MCOPY" "512 KB CREATE2")

NINE_DIFF_OUTPUT=$(FOUNDRY_PROFILE=monad_nine forge test \
    --match-contract Mip3DifferentialTest \
    -vv 2>&1) || true

EIGHT_DIFF_OUTPUT=$(FOUNDRY_PROFILE=monad_eight forge test \
    --match-contract Mip3DifferentialTest \
    -vv 2>&1) || true

for i in "${!DIFF_TESTS[@]}"; do
    test_name="${DIFF_TESTS[$i]}"
    label="${DIFF_LABELS[$i]}"

    NINE_GAS=$(extract_gas "$NINE_DIFF_OUTPUT" "$test_name")
    EIGHT_GAS=$(extract_gas "$EIGHT_DIFF_OUTPUT" "$test_name")

    if [[ -n "$EIGHT_GAS" && -n "$NINE_GAS" ]]; then
        echo "  $test_name"
        echo "    MonadEight gas: $EIGHT_GAS"
        echo "    MonadNine  gas: $NINE_GAS"
        if [[ "$EIGHT_GAS" -gt "$NINE_GAS" ]]; then
            pass "MonadEight ($EIGHT_GAS) > MonadNine ($NINE_GAS) for $label"
        else
            fail "Expected MonadEight > MonadNine for $label, got $EIGHT_GAS <= $NINE_GAS"
        fi
    else
        fail "$test_name: could not extract gas from one or both profiles"
    fi
done

echo ""

# ==========================================================================
# Summary
# ==========================================================================
TOTAL=$((PASSED + FAILED))
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}  All $TOTAL tests passed.${NC}"
else
    echo -e "${RED}  $FAILED/$TOTAL tests failed.${NC}"
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

exit $FAILED
