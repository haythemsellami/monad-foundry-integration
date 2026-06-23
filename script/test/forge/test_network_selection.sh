#!/bin/bash

# Forge coverage for v1.7 canonical `network = "monad"` selection and the
# deprecated `--monad` / `monad = true` aliases.

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

run_ok() {
    local label="$1"
    shift
    local output status
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        pass "$label"
    else
        echo "$output"
        fail "$label"
    fi
}

check_config() {
    local label="$1"
    local profile="$2"
    local output

    output=$(FOUNDRY_PROFILE="$profile" forge config --json)
    if echo "$output" | jq -e '.network == "monad" and .hardfork == "monad:MonadNine" and (has("monad") | not)' >/dev/null; then
        pass "$label serializes as canonical network=monad without legacy monad key"
    else
        echo "$output"
        fail "$label did not serialize as canonical Monad config"
    fi
}

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  FORGE NETWORK SELECTION TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

cd "$PROJECT_ROOT"

DEFAULT_CONFIG=$(forge config --json)
if echo "$DEFAULT_CONFIG" | jq -e '.network == "monad" and .hardfork == "monad:MonadNine"' >/dev/null; then
    pass "default profile infers Monad network from namespaced hardfork"
else
    echo "$DEFAULT_CONFIG"
    fail "default profile did not infer Monad network"
fi

check_config "profile.network_monad" "network_monad"
check_config "profile.legacy_monad_alias" "legacy_monad_alias"

run_ok "forge test --network monad selects Monad EVM" \
    forge test \
        --network monad \
        --match-path test/Mip4ReserveBalanceTest.t.sol \
        --match-contract MonadNineMip4ReserveBalanceTest \
        --match-test test_cleanCallReturnsFalse

run_ok "forge test --monad legacy alias selects Monad EVM" \
    forge test \
        --monad \
        --match-path test/Mip4ReserveBalanceTest.t.sol \
        --match-contract MonadNineMip4ReserveBalanceTest \
        --match-test test_cleanCallReturnsFalse

run_ok "FOUNDRY_PROFILE=network_monad executes Monad precompile test" \
    env FOUNDRY_PROFILE=network_monad forge test \
        --match-path test/Mip4ReserveBalanceTest.t.sol \
        --match-contract MonadNineMip4ReserveBalanceTest \
        --match-test test_cleanCallReturnsFalse

run_ok "FOUNDRY_PROFILE=legacy_monad_alias executes Monad precompile test" \
    env FOUNDRY_PROFILE=legacy_monad_alias forge test \
        --match-path test/Mip4ReserveBalanceTest.t.sol \
        --match-contract MonadNineMip4ReserveBalanceTest \
        --match-test test_cleanCallReturnsFalse

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
