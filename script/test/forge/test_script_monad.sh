#!/bin/bash

# Forge script coverage for MonadEvmNetwork routing in simulation and broadcast mode.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PORT=9658
RPC="http://127.0.0.1:$PORT"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
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

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  FORGE SCRIPT MONAD TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

cd "$PROJECT_ROOT"

run_ok "forge script simulation uses --network monad" \
    forge script script/MonadV17Compatibility.s.sol:MonadReserveBalanceScript \
        --network monad

anvil --network monad --hardfork MonadNine --port "$PORT" >/dev/null 2>&1 &
ANVIL_PID=$!

if ! wait_for_rpc "$RPC"; then
    fail "Monad Anvil failed to start for script broadcast"
else
    pass "Monad Anvil started for script broadcast"
fi

if [[ $FAILED -eq 0 ]]; then
    run_ok "forge script broadcast uses Monad EVM over RPC" \
        forge script script/MonadV17Compatibility.s.sol:MonadReserveBalanceScript \
            --network monad \
            --rpc-url "$RPC" \
            --private-key "$PRIVATE_KEY" \
            --broadcast
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
