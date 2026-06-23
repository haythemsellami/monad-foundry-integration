#!/bin/bash

# Verifies Monad cheatcode calls do not pollute Forge gas reports while real
# user contracts are still reported.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PASSED=0
FAILED=0

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

assert_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if grep -Fq "$needle" <<<"$haystack"; then
        pass "$label contains '$needle'"
    else
        echo "$haystack"
        fail "$label missing '$needle'"
    fi
}

assert_not_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if grep -Fq "$needle" <<<"$haystack"; then
        echo "$haystack"
        fail "$label unexpectedly contains '$needle'"
    else
        pass "$label does not contain '$needle'"
    fi
}

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  FORGE MONAD GAS REPORT TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

cd "$PROJECT_ROOT"

set +e
OUTPUT=$(forge test \
    --network monad \
    --match-contract GasReportMonadCheatcodeTest \
    --gas-report \
    2>&1)
STATUS=$?
set -e

if [[ $STATUS -eq 0 ]]; then
    pass "forge test --gas-report succeeded under --network monad"
else
    echo "$OUTPUT"
    fail "forge gas report command failed"
fi

if [[ $STATUS -eq 0 ]]; then
    assert_contains "gas report output" "$OUTPUT" "GasReportSubject"
    assert_contains "gas report output" "$OUTPUT" "touchStorage"
    assert_not_contains "gas report output" "$OUTPUT" "MonadVM"
    assert_not_contains "gas report output" "$OUTPUT" "0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
