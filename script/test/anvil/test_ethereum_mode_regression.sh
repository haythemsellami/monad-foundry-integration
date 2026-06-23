#!/bin/bash

# Negative regression checks: plain Ethereum Anvil must not inherit Monad
# precompiles, code-size limits, or nodeInfo metadata.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PORT=9659
RPC="http://127.0.0.1:$PORT"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RESERVE_BALANCE="0x0000000000000000000000000000000000001001"
DIPPED_SELECTOR="0x3a61584e"

PASSED=0
FAILED=0
ANVIL_PID=""

cleanup() {
    if [[ -n "${ANVIL_PID:-}" ]]; then
        kill "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

wait_for_rpc() {
    local rpc="$1"
    for _ in $(seq 1 40); do
        if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  ETHEREUM MODE NEGATIVE REGRESSION TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

anvil --port "$PORT" >/dev/null 2>&1 &
ANVIL_PID=$!

if ! wait_for_rpc "$RPC"; then
    fail "plain Anvil failed to start"
    exit 1
fi

INFO=$(cast rpc anvil_nodeInfo --rpc-url "$RPC")
NETWORK=$(echo "$INFO" | jq -r '.network // empty')
HARDFORK=$(echo "$INFO" | jq -r '.hardFork // .hard_fork // empty')

if [[ -z "$NETWORK" || "$NETWORK" == "null" ]]; then
    pass "plain Anvil nodeInfo does not advertise Monad network"
else
    fail "plain Anvil advertised unexpected network: $NETWORK"
fi

if [[ "$HARDFORK" != Monad* ]]; then
    pass "plain Anvil hardfork is not a Monad hardfork ($HARDFORK)"
else
    fail "plain Anvil used Monad hardfork: $HARDFORK"
fi

RAW=$(cast rpc eth_call "{\"to\":\"$RESERVE_BALANCE\",\"data\":\"$DIPPED_SELECTOR\"}" latest --rpc-url "$RPC")
if [[ "$RAW" == "0x" || "$RAW" == '"0x"' ]]; then
    pass "0x1001 reserve-balance precompile is absent in Ethereum mode"
else
    fail "0x1001 returned Monad-style data in Ethereum mode: $RAW"
fi

cd "$PROJECT_ROOT"

set +e
DEPLOY_OUTPUT=$(forge create src/LargeContract.sol:OversizedContract \
    --private-key "$PRIVATE_KEY" \
    --rpc-url "$RPC" \
    --broadcast 2>&1)
DEPLOY_STATUS=$?
set -e

if [[ $DEPLOY_STATUS -ne 0 ]] && echo "$DEPLOY_OUTPUT" | grep -Eiq 'CreateContractSizeLimit|max code size|code size|EIP-170|exceed'; then
    pass "Ethereum mode rejects the oversized runtime contract"
elif [[ $DEPLOY_STATUS -ne 0 ]]; then
    fail "oversized contract failed for an unexpected reason: $DEPLOY_OUTPUT"
else
    fail "Ethereum mode accepted an oversized runtime contract"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
