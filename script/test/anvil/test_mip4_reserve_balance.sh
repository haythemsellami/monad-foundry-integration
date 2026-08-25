#!/bin/bash
# =============================================================================
# Test: MIP-4 Reserve Balance via Anvil RPC
# =============================================================================
#
# Verifies MIP-4 through the full RPC/transaction pipeline:
#   1. 0x1001 returns false on MonadNine in a clean transaction context
#   2. 0x1001 is absent before MonadNine
#   3. Delegated sender can observe reserve-balance violation mid-transaction
#   4. Delegated sender can restore balance and observe false again
#   5. Child-frame violation is rolled back on revert
#
# This script manages its own anvil instances (ports 9555/9556).
#
# Usage: ./script/test/anvil/test_mip4_reserve_balance.sh
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/../../.."

DEPLOYER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
AUTH1_PK="0x0000000000000000000000000000000000000000000000000000000000000a11"
AUTH2_PK="0x0000000000000000000000000000000000000000000000000000000000000b22"
AUTH3_PK="0x0000000000000000000000000000000000000000000000000000000000000c33"
PORT_NINE=9555
PORT_EIGHT=9556
RPC_NINE="http://localhost:$PORT_NINE"
RPC_EIGHT="http://localhost:$PORT_EIGHT"
ANVIL_NINE_PID=""
ANVIL_EIGHT_PID=""
FUND_AMOUNT="11000000000000000000"
SPEND_AMOUNT="2000000000000000000"

PASSED=0
FAILED=0

pass() { echo "  PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL $1"; FAILED=$((FAILED + 1)); }

cleanup() {
    [[ -n "$ANVIL_NINE_PID" ]] && kill $ANVIL_NINE_PID 2>/dev/null || true
    [[ -n "$ANVIL_EIGHT_PID" ]] && kill $ANVIL_EIGHT_PID 2>/dev/null || true
}
trap cleanup EXIT

setup_authority() {
    local pk="$1"
    local rpc="$2"
    local address

    address=$(cast wallet address --private-key "$pk" 2>/dev/null)
    cast send "$address" \
        --value "$FUND_AMOUNT" \
        --rpc-url "$rpc" \
        --private-key "$DEPLOYER_PK" \
        >/dev/null 2>&1

    echo "$address"
}

read_status_tuple() {
    local address="$1"
    local rpc="$2"
    cast call "$address" "callDippedStatus()(bool,bool,bool)" --rpc-url "$rpc" 2>/dev/null
}

echo "Starting anvil --monad --hardfork MonadNine (port $PORT_NINE)..."
anvil --monad --hardfork MonadNine --port $PORT_NINE &>/dev/null &
ANVIL_NINE_PID=$!

echo "Starting anvil --monad --hardfork MonadEight (port $PORT_EIGHT)..."
anvil --monad --hardfork MonadEight --port $PORT_EIGHT &>/dev/null &
ANVIL_EIGHT_PID=$!

sleep 2

if ! cast chain-id --rpc-url "$RPC_NINE" &>/dev/null; then
    echo "ERROR: MonadNine anvil failed to start"
    exit 1
fi
if ! cast chain-id --rpc-url "$RPC_EIGHT" &>/dev/null; then
    echo "ERROR: MonadEight anvil failed to start"
    exit 1
fi

echo ""
echo "=============================================="
echo "  MIP-4 ANVIL RPC TESTS"
echo "=============================================="
echo ""

echo "Deploying ReserveBalanceCaller on MonadNine..."
CALLER_NINE=$(forge create test/Mip4ReserveBalanceTest.t.sol:ReserveBalanceCaller \
    --rpc-url "$RPC_NINE" --private-key "$DEPLOYER_PK" --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  ReserveBalanceCaller (MonadNine): $CALLER_NINE"

echo "Deploying ReserveBalanceCaller on MonadEight..."
CALLER_EIGHT=$(forge create test/Mip4ReserveBalanceTest.t.sol:ReserveBalanceCaller \
    --rpc-url "$RPC_EIGHT" --private-key "$DEPLOYER_PK" --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  ReserveBalanceCaller (MonadEight): $CALLER_EIGHT"

echo "Deploying RefundSink on MonadNine..."
SINK_NINE=$(forge create test/Mip4ReserveBalanceTest.t.sol:RefundSink \
    --rpc-url "$RPC_NINE" --private-key "$DEPLOYER_PK" --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  RefundSink (MonadNine): $SINK_NINE"

echo "Deploying DelegatedReserveProbe on MonadNine..."
PROBE_NINE=$(forge create test/Mip4ReserveBalanceTest.t.sol:DelegatedReserveProbe \
    --rpc-url "$RPC_NINE" --private-key "$DEPLOYER_PK" --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  DelegatedReserveProbe (MonadNine): $PROBE_NINE"

echo ""
echo "[MonadNine — Direct Introspection]"

STATUS_NINE=$(read_status_tuple "$CALLER_NINE" "$RPC_NINE")
STATUS_NINE_1=$(echo "$STATUS_NINE" | sed -n '1p')
STATUS_NINE_2=$(echo "$STATUS_NINE" | sed -n '2p')
STATUS_NINE_3=$(echo "$STATUS_NINE" | sed -n '3p')
if [[ "$STATUS_NINE_1" == "true" && "$STATUS_NINE_2" == "true" && "$STATUS_NINE_3" == "false" ]]; then
    pass "MonadNine direct call returns false with ABI bool returndata"
else
    fail "MonadNine direct call should return (true, true, false)"
fi

echo ""
echo "[MonadEight — Hardfork Gating]"

STATUS_EIGHT=$(read_status_tuple "$CALLER_EIGHT" "$RPC_EIGHT")
STATUS_EIGHT_1=$(echo "$STATUS_EIGHT" | sed -n '1p')
STATUS_EIGHT_2=$(echo "$STATUS_EIGHT" | sed -n '2p')
STATUS_EIGHT_3=$(echo "$STATUS_EIGHT" | sed -n '3p')
if [[ "$STATUS_EIGHT_1" == "true" && "$STATUS_EIGHT_2" == "false" && "$STATUS_EIGHT_3" == "false" ]]; then
    pass "MonadEight treats 0x1001 as absent precompile"
else
    fail "MonadEight should return (true, false, false) for 0x1001"
fi

echo ""
echo "[MonadNine — Delegated Sender Reserve Tracking]"

AUTH1=$(setup_authority "$AUTH1_PK" "$RPC_NINE")
cast send "$AUTH1" "spendAndRecord(address,uint256)" "$SINK_NINE" "$SPEND_AMOUNT" \
    --rpc-url "$RPC_NINE" \
    --private-key "$AUTH1_PK" \
    --auth "$PROBE_NINE" \
    --force \
    >/dev/null 2>&1

BEFORE=$(cast call "$AUTH1" "lastBefore()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
DURING=$(cast call "$AUTH1" "lastDuring()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
if [[ "$BEFORE" == "false" && "$DURING" == "true" ]]; then
    pass "Delegated sender sees false before spend and true after dipping below reserve"
else
    fail "Delegated sender should record false before spend and true after spend"
fi

AUTH2=$(setup_authority "$AUTH2_PK" "$RPC_NINE")
cast send "$AUTH2" "spendRestoreAndRecord(address,uint256)" "$SINK_NINE" "$SPEND_AMOUNT" \
    --rpc-url "$RPC_NINE" \
    --private-key "$AUTH2_PK" \
    --auth "$PROBE_NINE" \
    --force \
    >/dev/null 2>&1

BEFORE=$(cast call "$AUTH2" "lastBefore()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
DURING=$(cast call "$AUTH2" "lastDuring()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
AFTER=$(cast call "$AUTH2" "lastAfter()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
if [[ "$BEFORE" == "false" && "$DURING" == "true" && "$AFTER" == "false" ]]; then
    pass "Delegated sender can restore balance and clear violation in the same transaction"
else
    fail "Delegated sender should record false -> true -> false when funds are restored"
fi

AUTH3=$(setup_authority "$AUTH3_PK" "$RPC_NINE")
cast send "$AUTH3" "childSpendRevertAndRecord(address,uint256)" "$SINK_NINE" "$SPEND_AMOUNT" \
    --rpc-url "$RPC_NINE" \
    --private-key "$AUTH3_PK" \
    --auth "$PROBE_NINE" \
    --force \
    >/dev/null 2>&1

CHILD_OK=$(cast call "$AUTH3" "lastChildCallOk()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
CHILD_DIPPED=$(cast call "$AUTH3" "lastChildDipped()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
AFTER_REVERT=$(cast call "$AUTH3" "lastAfterRevert()(bool)" --rpc-url "$RPC_NINE" 2>/dev/null)
if [[ "$CHILD_OK" == "false" && "$CHILD_DIPPED" == "true" && "$AFTER_REVERT" == "false" ]]; then
    pass "Child-frame violation is rolled back after revert"
else
    fail "Child-frame revert should leave the parent with no reserve violation"
fi

echo ""
TOTAL=$((PASSED + FAILED))
echo "=============================================="
echo "  MIP-4 Anvil: $PASSED/$TOTAL passed"
echo "=============================================="

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
