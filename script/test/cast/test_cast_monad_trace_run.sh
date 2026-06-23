#!/bin/bash

# Cast regression coverage for Monad network routing and trace decoding.
# Covers both `cast call --trace` and `cast run` replay for the MIP-4
# reserve-balance precompile introduced in MonadNine.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT=9657
RPC="http://127.0.0.1:$PORT"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RESERVE_BALANCE="0x0000000000000000000000000000000000001001"
DIPPED_SELECTOR="0x3a61584e"
ANVIL_PID=""
PASSED=0
FAILED=0

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

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  CAST MONAD TRACE/RUN TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

anvil --network monad --hardfork MonadNine --port "$PORT" >/dev/null 2>&1 &
ANVIL_PID=$!

if ! wait_for_rpc "$RPC"; then
    fail "Monad Anvil failed to start"
    exit 1
fi
pass "Monad Anvil started for Cast tests"

TRACE_OUTPUT=$(cast call "$RESERVE_BALANCE" --data "$DIPPED_SELECTOR" --rpc-url "$RPC" --trace 2>&1)
assert_contains "cast call --trace" "$TRACE_OUTPUT" "Traces:"
assert_contains "cast call --trace" "$TRACE_OUTPUT" "ReserveBalance::dippedIntoReserve()"
assert_contains "cast call --trace" "$TRACE_OUTPUT" "[Return] false"

SEND_JSON=$(cast send "$RESERVE_BALANCE" "$DIPPED_SELECTOR" \
    --rpc-url "$RPC" \
    --private-key "$PRIVATE_KEY" \
    --gas-limit 100000 \
    --json 2>&1)

TX_HASH=$(echo "$SEND_JSON" | jq -r '.transactionHash // .transaction_hash // empty')
if [[ -n "$TX_HASH" ]]; then
    pass "sent reserve-balance transaction for replay"
else
    echo "$SEND_JSON"
    fail "could not extract transaction hash from cast send output"
fi

if [[ -n "$TX_HASH" ]]; then
    RUN_OUTPUT=$(cast run "$TX_HASH" --rpc-url "$RPC" --quick 2>&1)
    assert_contains "cast run replay" "$RUN_OUTPUT" "Transaction successfully executed."
    assert_contains "cast run replay" "$RUN_OUTPUT" "ReserveBalance::dippedIntoReserve()"
    assert_contains "cast run replay" "$RUN_OUTPUT" "[Return] false"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
