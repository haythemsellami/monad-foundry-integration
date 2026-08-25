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
ACCESS_LIST_SAME_PAGE="0x600254506001545000"
ACCESS_LIST_DIFFERENT_PAGE="0x608154506001545000"
SLOT_ONE="0x0000000000000000000000000000000000000000000000000000000000000001"
SLOT_TWO="0x0000000000000000000000000000000000000000000000000000000000000002"
SLOT_129="0x0000000000000000000000000000000000000000000000000000000000000081"
PASSED=0
FAILED=0
PIDS=()

CAST_PROJECT_ENV_ARG=""
ANVIL_PROJECT_ENV_ARG=""
if [[ $(command cast --help 2>&1) == *"--allow-project-env"* ]]; then
    CAST_PROJECT_ENV_ARG="--allow-project-env"
fi
if [[ $(command anvil --help 2>&1) == *"--allow-project-env"* ]]; then
    ANVIL_PROJECT_ENV_ARG="--allow-project-env"
fi

cast() {
    if [[ -n "$CAST_PROJECT_ENV_ARG" ]]; then
        command cast "$CAST_PROJECT_ENV_ARG" "$@"
    else
        command cast "$@"
    fi
}

anvil() {
    if [[ -n "$ANVIL_PROJECT_ENV_ARG" ]]; then
        command anvil "$ANVIL_PROJECT_ENV_ARG" "$@"
    else
        command anvil "$@"
    fi
}

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

estimate_gas() {
    local rpc="$1"
    local code="$2"
    local result

    cast rpc anvil_setCode "$PROBE_ADDRESS" "$code" --rpc-url "$rpc" >/dev/null
    result=$(cast rpc eth_estimateGas "{\"to\":\"$PROBE_ADDRESS\"}" latest --rpc-url "$rpc")
    cast to-dec "$(echo "$result" | jq -r '.')"
}

trace_gas() {
    local rpc="$1"
    local code="$2"
    local result

    cast rpc anvil_setCode "$PROBE_ADDRESS" "$code" --rpc-url "$rpc" >/dev/null
    result=$(cast rpc trace_call "{\"to\":\"$PROBE_ADDRESS\"}" '["trace"]' latest --rpc-url "$rpc")
    cast to-dec "$(echo "$result" | jq -r '.trace[0].result.gasUsed')"
}

create_access_list() {
    local rpc="$1"
    local code="$2"

    cast rpc anvil_setCode "$PROBE_ADDRESS" "$code" --rpc-url "$rpc" >/dev/null
    cast rpc eth_createAccessList "{\"to\":\"$PROBE_ADDRESS\"}" latest --rpc-url "$rpc"
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

check_rpc_deltas() {
    local label="$1"
    local rpc="$2"
    local expected_read="$3"
    local expected_write="$4"
    local method="$5"
    local probe="$6"
    local read_same read_different write_same write_different read_delta write_delta

    read_same=$("$probe" "$rpc" "$READ_SAME_PAGE")
    read_different=$("$probe" "$rpc" "$READ_DIFFERENT_PAGE")
    write_same=$("$probe" "$rpc" "$WRITE_SAME_PAGE")
    write_different=$("$probe" "$rpc" "$WRITE_DIFFERENT_PAGE")
    read_delta=$((read_different - read_same))
    write_delta=$((write_different - write_same))

    if [[ $read_delta -eq $expected_read ]]; then
        pass "$label $method read-page delta is $expected_read gas"
    else
        fail "$label $method read-page delta is $read_delta gas, expected $expected_read"
    fi

    if [[ $write_delta -eq $expected_write ]]; then
        pass "$label $method write-page delta is $expected_write gas"
    else
        fail "$label $method write-page delta is $write_delta gas, expected $expected_write"
    fi
}

check_access_list() {
    local label="$1"
    local rpc="$2"
    local expected_same_page_keys="$3"
    local expected_different_page_keys="$4"
    local expected_gas_delta="$5"
    local same_page different_page same_page_gas different_page_gas gas_delta

    same_page=$(create_access_list "$rpc" "$ACCESS_LIST_SAME_PAGE")
    different_page=$(create_access_list "$rpc" "$ACCESS_LIST_DIFFERENT_PAGE")

    if echo "$same_page" | jq -e \
        --arg address "$PROBE_ADDRESS" \
        --argjson keys "$expected_same_page_keys" \
        '(.accessList | length) == 1 and
         .accessList[0].address == $address and
         .accessList[0].storageKeys == $keys and
         (.error // null) == null' >/dev/null; then
        pass "$label eth_createAccessList returns expected same-page keys"
    else
        fail "$label eth_createAccessList returned unexpected same-page access list"
    fi

    if echo "$different_page" | jq -e \
        --arg address "$PROBE_ADDRESS" \
        --argjson keys "$expected_different_page_keys" \
        '(.accessList | length) == 1 and
         .accessList[0].address == $address and
         .accessList[0].storageKeys == $keys and
         (.error // null) == null' >/dev/null; then
        pass "$label eth_createAccessList preserves cross-page keys correctly"
    else
        fail "$label eth_createAccessList returned unexpected cross-page access list"
    fi

    same_page_gas=$(cast to-dec "$(echo "$same_page" | jq -r '.gasUsed')")
    different_page_gas=$(cast to-dec "$(echo "$different_page" | jq -r '.gasUsed')")
    gas_delta=$((different_page_gas - same_page_gas))

    if [[ $gas_delta -eq $expected_gas_delta ]]; then
        pass "$label eth_createAccessList gasUsed delta is $expected_gas_delta gas"
    else
        fail "$label eth_createAccessList gasUsed delta is $gas_delta gas, expected $expected_gas_delta"
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
    check_rpc_deltas "MonadTen" "$RPC_TEN" 8000 10800 "eth_estimateGas" estimate_gas
    check_rpc_deltas "MonadNine" "$RPC_NINE" 0 0 "eth_estimateGas" estimate_gas
    check_rpc_deltas "MonadTen" "$RPC_TEN" 8000 10800 "trace_call" trace_gas
    check_rpc_deltas "MonadNine" "$RPC_NINE" 0 0 "trace_call" trace_gas
    check_access_list \
        "MonadTen" \
        "$RPC_TEN" \
        "[\"$SLOT_ONE\"]" \
        "[\"$SLOT_ONE\",\"$SLOT_129\"]" \
        1900
    check_access_list \
        "MonadNine" \
        "$RPC_NINE" \
        "[\"$SLOT_ONE\",\"$SLOT_TWO\"]" \
        "[\"$SLOT_ONE\",\"$SLOT_129\"]" \
        0
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
