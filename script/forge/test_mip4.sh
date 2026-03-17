#!/bin/bash
#
# MIP-4 Integration Test Runner
#
# Runs the MIP-4 reserve-balance suite under both Monad hardfork profiles.
#
# Usage: ./script/forge/test_mip4.sh

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
echo -e "${CYAN}  MIP-4 RESERVE BALANCE INTEGRATION TESTS${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# ==========================================================================
# Section 1: MonadNine exact assertions
# ==========================================================================
echo -e "${YELLOW}[MonadNine — Exact MIP-4 Assertions]${NC}"

NINE_OUTPUT=$(FOUNDRY_PROFILE=monad_nine forge test \
    --match-contract MonadNineMip4ReserveBalanceTest \
    -vv 2>&1) || true

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
    --match-contract MonadEightMip4RegressionTest \
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
