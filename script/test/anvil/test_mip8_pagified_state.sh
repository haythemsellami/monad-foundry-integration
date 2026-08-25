#!/bin/bash
#
# Verifies MIP-8 storage page pricing through Anvil's RPC execution path.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT_TEN=9565
PORT_NINE=9566
RPC_TEN="http://127.0.0.1:$PORT_TEN"
RPC_NINE="http://127.0.0.1:$PORT_NINE"
PROBE_ADDRESS="0x0000000000000000000000000000000000002004"
READ_SAME_PAGE="0x5a5f5450607f54505a90035f5260205ff3"
READ_DIFFERENT_PAGE="0x5a5f5450608054505a90035f5260205ff3"
WRITE_SAME_PAGE="0x5a60015f5560016001555a90035f5260205ff3"
WRITE_DIFFERENT_PAGE="0x5a60015f5560016080555a90035f5260205ff3"
PASSED=0
FAILED=0
PIDS=()

cast() { command cast --allow-project-env "$@"; }
anvil() { command anvil --allow-project-env "$@"; }

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

probe_gas() {
    local rpc="$1"
    local code="$2"
    local result

    cast rpc anvil_setCode "$PROBE_ADDRESS" "$code" --rpc-url "$rpc" >/dev/null
    result=$(cast call "$PROBE_ADDRESS" --data 0x --rpc-url "$rpc")
    cast to-dec "$result"
}

check_hardfork() {
    local label="$1"
    local rpc="$2"
    local expected="$3"
    local info hardfork

    info=$(cast rpc anvil_nodeInfo --rpc-url "$rpc")
    hardfork=$(echo "$info" | jq -r '.hardFork // .hard_fork // empty')
    if [[ "$hardfork" == "$expected" ]]; then
        pass "$label reports $expected"
    else
        fail "$label reported hardfork '$hardfork', expected '$expected'"
    fi
}

check_deltas() {
    local label="$1"
    local rpc="$2"
    local expected_read="$3"
    local expected_write="$4"
    local read_same read_different write_same write_different read_delta write_delta

    read_same=$(probe_gas "$rpc" "$READ_SAME_PAGE")
    read_different=$(probe_gas "$rpc" "$READ_DIFFERENT_PAGE")
    write_same=$(probe_gas "$rpc" "$WRITE_SAME_PAGE")
    write_different=$(probe_gas "$rpc" "$WRITE_DIFFERENT_PAGE")
    read_delta=$((read_different - read_same))
    write_delta=$((write_different - write_same))

    if [[ $read_delta -eq $expected_read ]]; then
        pass "$label read-page delta is $expected_read gas"
    else
        fail "$label read-page delta is $read_delta gas, expected $expected_read"
    fi

    if [[ $write_delta -eq $expected_write ]]; then
        pass "$label write-page delta is $expected_write gas"
    else
        fail "$label write-page delta is $write_delta gas, expected $expected_write"
    fi
}

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  MIP-8 ANVIL RPC TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

anvil --network monad --hardfork MonadTen --port "$PORT_TEN" >/dev/null 2>&1 &
PIDS+=("$!")
anvil --network monad --hardfork MonadNine --port "$PORT_NINE" >/dev/null 2>&1 &
PIDS+=("$!")

if ! wait_for_rpc "$RPC_TEN"; then
    fail "MonadTen Anvil failed to start"
fi
if ! wait_for_rpc "$RPC_NINE"; then
    fail "MonadNine Anvil failed to start"
fi

if [[ $FAILED -eq 0 ]]; then
    check_hardfork "MonadTen Anvil" "$RPC_TEN" "MonadTen"
    check_hardfork "MonadNine Anvil" "$RPC_NINE" "MonadNine"
    check_deltas "MonadTen" "$RPC_TEN" 8000 10800
    check_deltas "MonadNine" "$RPC_NINE" 0 0
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
