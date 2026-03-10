#!/bin/bash
# =============================================================================
# Test: MIP-3 Linear Memory via Anvil RPC
# =============================================================================
#
# Verifies MIP-3 behavior through the full RPC/transaction pipeline:
#   1. Gas estimation reflects linear pricing on MonadNine
#   2. 8 MB cap enforced via real transactions on MonadNine
#   3. Pooled parent+child cap via real transactions on MonadNine
#   4. Differential: same calldata costs less on MonadNine than MonadEight
#
# This script manages its own anvil instances (ports 9545/9546).
#
# Usage: ./script/test/anvil/test_mip3_memory.sh
# =============================================================================

set -e

cd "$(dirname "$0")/../../.."

PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
PORT_NINE=9545
PORT_EIGHT=9546
RPC_NINE="http://localhost:$PORT_NINE"
RPC_EIGHT="http://localhost:$PORT_EIGHT"
ANVIL_NINE_PID=""
ANVIL_EIGHT_PID=""
BLOCK_GAS_LIMIT=200000000

PASSED=0
FAILED=0

pass() { echo "  PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL $1"; FAILED=$((FAILED + 1)); }

cleanup() {
    [[ -n "$ANVIL_NINE_PID" ]] && kill $ANVIL_NINE_PID 2>/dev/null || true
    [[ -n "$ANVIL_EIGHT_PID" ]] && kill $ANVIL_EIGHT_PID 2>/dev/null || true
}
trap cleanup EXIT

# =========================================================================
# Start anvil instances
# =========================================================================
echo "Starting anvil --monad --hardfork MonadNine (port $PORT_NINE)..."
anvil --monad --hardfork MonadNine --port $PORT_NINE --gas-limit $BLOCK_GAS_LIMIT &>/dev/null &
ANVIL_NINE_PID=$!

echo "Starting anvil --monad --hardfork MonadEight (port $PORT_EIGHT)..."
anvil --monad --hardfork MonadEight --port $PORT_EIGHT --gas-limit $BLOCK_GAS_LIMIT &>/dev/null &
ANVIL_EIGHT_PID=$!

sleep 2

# Verify both are running
if ! cast chain-id --rpc-url $RPC_NINE &>/dev/null; then
    echo "ERROR: MonadNine anvil failed to start"
    exit 1
fi
if ! cast chain-id --rpc-url $RPC_EIGHT &>/dev/null; then
    echo "ERROR: MonadEight anvil failed to start"
    exit 1
fi

echo ""
echo "=============================================="
echo "  MIP-3 ANVIL RPC TESTS"
echo "=============================================="
echo ""

# =========================================================================
# Deploy contracts on both chains
# =========================================================================
echo "Deploying MemoryAllocator on MonadNine..."
ALLOC_NINE=$(forge create test/Mip3MemoryTest.t.sol:MemoryAllocator \
    --rpc-url $RPC_NINE --private-key $PRIVKEY --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  MemoryAllocator (MonadNine): $ALLOC_NINE"

echo "Deploying PooledCapTester on MonadNine..."
POOLED_NINE=$(forge create test/Mip3MemoryTest.t.sol:PooledCapTester \
    --rpc-url $RPC_NINE --private-key $PRIVKEY --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  PooledCapTester (MonadNine): $POOLED_NINE"

echo "Deploying MemoryAllocator on MonadEight..."
ALLOC_EIGHT=$(forge create test/Mip3MemoryTest.t.sol:MemoryAllocator \
    --rpc-url $RPC_EIGHT --private-key $PRIVKEY --broadcast --json 2>/dev/null \
    | jq -r '.deployedTo')
echo "  MemoryAllocator (MonadEight): $ALLOC_EIGHT"

echo ""

# =========================================================================
# Test 1: Near-8 MB allocation succeeds on MonadNine
# =========================================================================
echo "[MonadNine — 8 MB Cap via RPC]"

# allocateRaw(8MB - 4KB) should succeed
NEAR_8MB=$((8 * 1024 * 1024 - 4096))
CALLDATA_NEAR=$(cast calldata "allocateRaw(uint256)" $NEAR_8MB)

RECEIPT=$(cast send $ALLOC_NINE $CALLDATA_NEAR \
    --rpc-url $RPC_NINE --private-key $PRIVKEY \
    --gas-limit $BLOCK_GAS_LIMIT --json 2>/dev/null) || true

STATUS=$(echo "$RECEIPT" | jq -r '.status')
if [[ "$STATUS" == "0x1" ]]; then
    pass "Near-8 MB allocation succeeds on MonadNine"
else
    fail "Near-8 MB allocation should succeed on MonadNine"
fi

# =========================================================================
# Test 2: Over-8 MB allocation reverts on MonadNine
# =========================================================================
OVER_8MB=$((8 * 1024 * 1024 + 32))
CALLDATA_OVER=$(cast calldata "allocateRaw(uint256)" $OVER_8MB)

RECEIPT=$(cast send $ALLOC_NINE $CALLDATA_OVER \
    --rpc-url $RPC_NINE --private-key $PRIVKEY \
    --gas-limit $BLOCK_GAS_LIMIT --json 2>/dev/null) || true

STATUS=$(echo "$RECEIPT" | jq -r '.status')
if [[ "$STATUS" == "0x0" ]]; then
    pass "Over-8 MB allocation reverts on MonadNine (MemoryLimitOOG)"
else
    fail "Over-8 MB allocation should revert on MonadNine"
fi

# =========================================================================
# Test 3: Over-8 MB allocation succeeds on MonadEight (cap not active)
# =========================================================================
echo ""
echo "[MonadEight — No Cap]"

RECEIPT=$(cast send $ALLOC_EIGHT $CALLDATA_OVER \
    --rpc-url $RPC_EIGHT --private-key $PRIVKEY \
    --gas-limit $BLOCK_GAS_LIMIT --json 2>/dev/null) || true

STATUS=$(echo "$RECEIPT" | jq -r '.status')
if [[ "$STATUS" == "0x1" ]]; then
    pass "Over-8 MB allocation succeeds on MonadEight (cap not active)"
else
    fail "Over-8 MB allocation should succeed on MonadEight"
fi

# =========================================================================
# Test 4: Pooled cap — parent 6 MB + child 512 KB succeeds
# =========================================================================
echo ""
echo "[MonadNine — Pooled Cap via RPC]"

PARENT_SIZE=$((6 * 1024 * 1024))
CHILD_SIZE=$((512 * 1024))
CALLDATA_POOLED=$(cast calldata "parentThenChild(uint256,uint256)" $PARENT_SIZE $CHILD_SIZE)

RECEIPT=$(cast send $POOLED_NINE $CALLDATA_POOLED \
    --rpc-url $RPC_NINE --private-key $PRIVKEY \
    --gas-limit $BLOCK_GAS_LIMIT --json 2>/dev/null) || true

STATUS=$(echo "$RECEIPT" | jq -r '.status')
if [[ "$STATUS" == "0x1" ]]; then
    pass "Pooled cap: parent 6 MB + child 512 KB succeeds"
else
    fail "Pooled cap: parent 6 MB + child 512 KB should succeed"
fi

# =========================================================================
# Test 5: Differential gas estimation
# =========================================================================
echo ""
echo "[Differential — Gas Estimation]"

# Estimate gas for 1 MB allocation on both profiles
SIZE_1MB=$((1024 * 1024))
CALLDATA_1MB=$(cast calldata "allocateRaw(uint256)" $SIZE_1MB)

GAS_NINE=$(cast estimate $ALLOC_NINE $CALLDATA_1MB --rpc-url $RPC_NINE 2>/dev/null) || true
GAS_EIGHT=$(cast estimate $ALLOC_EIGHT $CALLDATA_1MB --rpc-url $RPC_EIGHT 2>/dev/null) || true

if [[ -n "$GAS_NINE" && -n "$GAS_EIGHT" ]]; then
    echo "  1 MB allocateRaw estimate:"
    echo "    MonadEight: $GAS_EIGHT gas"
    echo "    MonadNine:  $GAS_NINE gas"
    if [[ "$GAS_EIGHT" -gt "$GAS_NINE" ]]; then
        pass "Gas estimate: MonadEight ($GAS_EIGHT) > MonadNine ($GAS_NINE)"
    else
        fail "Gas estimate: expected MonadEight > MonadNine, got $GAS_EIGHT <= $GAS_NINE"
    fi
else
    fail "Could not estimate gas on one or both profiles"
fi

echo ""

# =========================================================================
# Summary
# =========================================================================
TOTAL=$((PASSED + FAILED))
echo "=============================================="
echo "  MIP-3 Anvil: $PASSED/$TOTAL passed"
echo "=============================================="

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
