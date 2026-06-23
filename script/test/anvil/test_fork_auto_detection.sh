#!/bin/bash

# Verifies Forge infers Monad execution from a forked Monad Anvil endpoint
# without passing --monad or --network monad to forge test.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PORT=9660
RPC="http://127.0.0.1:$PORT"
TMP_PROJECT=""
ANVIL_PID=""
PASSED=0
FAILED=0

cleanup() {
    if [[ -n "${ANVIL_PID:-}" ]]; then
        kill "$ANVIL_PID" 2>/dev/null || true
    fi
    if [[ -n "${TMP_PROJECT:-}" ]]; then
        rm -rf "$TMP_PROJECT"
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
echo -e "${CYAN}  FORK AUTO-DETECTION TESTS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

anvil --network monad --hardfork MonadNine --port "$PORT" >/dev/null 2>&1 &
ANVIL_PID=$!

if ! wait_for_rpc "$RPC"; then
    fail "source Monad Anvil failed to start"
    exit 1
fi

INFO=$(cast rpc anvil_nodeInfo --rpc-url "$RPC")
if echo "$INFO" | jq -e '.network == "monad" and ((.hardFork // .hard_fork) == "MonadNine")' >/dev/null; then
    pass "source Anvil advertises Monad network metadata"
else
    fail "source Anvil did not advertise Monad metadata: $INFO"
fi

TMP_PROJECT=$(mktemp -d)
mkdir -p "$TMP_PROJECT/test"

cat >"$TMP_PROJECT/foundry.toml" <<EOF
[profile.default]
src = "src"
test = "test"
out = "out"
libs = ["$PROJECT_ROOT/lib"]
solc_version = "0.8.28"
optimizer = false
via_ir = false
EOF

cat >"$TMP_PROJECT/test/ForkDetectMonadTest.t.sol" <<'EOF'
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface IReserveBalance {
    function dippedIntoReserve() external returns (bool);
}

contract ForkDetectMonadTest is Test {
    address constant RESERVE_BALANCE = address(0x0000000000000000000000000000000000001001);

    function test_fork_infers_monad_network_from_node_info() public {
        (bool success, bytes memory ret) =
            RESERVE_BALANCE.call(abi.encodeWithSelector(IReserveBalance.dippedIntoReserve.selector));

        assertTrue(success, "Forge should infer Monad network from fork nodeInfo");
        assertEq(ret.length, 32, "Monad reserve-balance precompile must return a bool");
        assertFalse(abi.decode(ret, (bool)), "clean fork transaction should not dip into reserve");
    }
}
EOF

set +e
OUTPUT=$(forge test --root "$TMP_PROJECT" --fork-url "$RPC" --match-contract ForkDetectMonadTest -vv 2>&1)
STATUS=$?
set -e

if [[ $STATUS -eq 0 ]]; then
    pass "forge test inferred Monad from fork without --network or --monad"
else
    echo "$OUTPUT"
    fail "forge test did not infer Monad from fork"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
