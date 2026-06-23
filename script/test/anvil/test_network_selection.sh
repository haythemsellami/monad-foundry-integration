#!/bin/bash

# Verifies canonical Anvil v1.7 network selection is equivalent to the
# deprecated --monad alias for Monad execution-critical behavior.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT_NETWORK=9655
PORT_ALIAS=9656
RPC_NETWORK="http://127.0.0.1:$PORT_NETWORK"
RPC_ALIAS="http://127.0.0.1:$PORT_ALIAS"
RESERVE_BALANCE="0x0000000000000000000000000000000000001001"
PASSED=0
FAILED=0
PIDS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
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

check_node_info() {
    local label="$1"
    local rpc="$2"
    local expected_hardfork="$3"
    local info network hardfork

    info=$(cast rpc anvil_nodeInfo --rpc-url "$rpc")
    network=$(echo "$info" | jq -r '.network // empty')
    hardfork=$(echo "$info" | jq -r '.hardFork // .hard_fork // empty')

    if [[ "$network" == "monad" && "$hardfork" == "$expected_hardfork" ]]; then
        pass "$label nodeInfo reports network=monad hardfork=$expected_hardfork"
    else
        fail "$label nodeInfo mismatch: network=$network hardfork=$hardfork info=$info"
    fi
}

check_reserve_balance() {
    local label="$1"
    local rpc="$2"
    local result

    result=$(cast call "$RESERVE_BALANCE" "dippedIntoReserve()(bool)" --rpc-url "$rpc" 2>&1 || true)
    if echo "$result" | grep -q "false"; then
        pass "$label exposes MonadNine reserve-balance precompile"
    else
        fail "$label reserve-balance call failed or returned unexpected data: $result"
    fi
}

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  ANVIL NETWORK SELECTION TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

anvil --network monad --hardfork MonadNine --port "$PORT_NETWORK" >/dev/null 2>&1 &
PIDS+=("$!")
anvil --monad --hardfork MonadNine --port "$PORT_ALIAS" >/dev/null 2>&1 &
PIDS+=("$!")

if wait_for_rpc "$RPC_NETWORK"; then
    pass "anvil --network monad starts"
else
    fail "anvil --network monad failed to start"
fi

if wait_for_rpc "$RPC_ALIAS"; then
    pass "anvil --monad legacy alias starts"
else
    fail "anvil --monad failed to start"
fi

if [[ $FAILED -eq 0 ]]; then
    check_node_info "canonical --network monad" "$RPC_NETWORK" "MonadNine"
    check_node_info "legacy --monad" "$RPC_ALIAS" "MonadNine"
    check_reserve_balance "canonical --network monad" "$RPC_NETWORK"
    check_reserve_balance "legacy --monad" "$RPC_ALIAS"

    CHAIN_NETWORK=$(cast chain-id --rpc-url "$RPC_NETWORK")
    CHAIN_ALIAS=$(cast chain-id --rpc-url "$RPC_ALIAS")
    if [[ "$CHAIN_NETWORK" == "$CHAIN_ALIAS" ]]; then
        pass "canonical and legacy Monad Anvil use the same chain id ($CHAIN_NETWORK)"
    else
        fail "canonical and legacy chain ids differ: $CHAIN_NETWORK vs $CHAIN_ALIAS"
    fi
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
