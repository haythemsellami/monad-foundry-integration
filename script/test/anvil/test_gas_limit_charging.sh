#!/bin/bash
# =============================================================================
# Test: Monad charges gas based on gas_limit, not gas_used
# =============================================================================
#
# Monad behavior (from handler.rs):
#   - reimburse_caller() does nothing (no unused gas returned)
#   - reward_beneficiary() uses gas_limit, not gas_used
#
# Expected:
#   - Monad anvil:    balance_spent = gas_limit * gas_price
#   - Standard anvil: balance_spent = gas_used * gas_price
#
# Usage:
#   1. Start anvil: 'anvil --monad' or 'anvil'
#   2. Run: ./script/test_gas_limit_charging.sh
# =============================================================================

set -e

RPC="http://localhost:8545"
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

echo "=============================================="
echo "  GAS_LIMIT vs GAS_USED CHARGING TEST"
echo "=============================================="
echo ""

# Verify anvil is running
if ! cast chain-id --rpc-url $RPC &>/dev/null; then
    echo "ERROR: anvil not running"
    echo "Start with: anvil --monad (Monad) or anvil (Ethereum)"
    exit 1
fi

# Deploy contract
echo "Deploying contract..."
cd "$(dirname "$0")/.."
CONTRACT=$(forge create test/RefundTest.t.sol:StorageClearer \
    --rpc-url $RPC --private-key $PRIVKEY --broadcast --json 2>/dev/null | jq -r '.deployedTo')
echo "Contract: $CONTRACT"
echo ""

# Test parameters
GAS_LIMIT=100000  # High limit, operation uses ~45k

# Get balance before
BALANCE_BEFORE=$(cast balance $SENDER --rpc-url $RPC)

# Send tx with high gas limit
RECEIPT=$(cast send $CONTRACT "setValue(uint256)" 1 \
    --rpc-url $RPC --private-key $PRIVKEY --gas-limit $GAS_LIMIT --json 2>/dev/null)

# Get balance after
BALANCE_AFTER=$(cast balance $SENDER --rpc-url $RPC)

# Parse receipt
GAS_USED=$(printf '%d' $(echo $RECEIPT | jq -r '.gasUsed'))
GAS_PRICE=$(printf '%d' $(echo $RECEIPT | jq -r '.effectiveGasPrice'))

# Calculate
COST_IF_LIMIT=$(python3 -c "print($GAS_LIMIT * $GAS_PRICE)")
COST_IF_USED=$(python3 -c "print($GAS_USED * $GAS_PRICE)")
ACTUAL=$(python3 -c "print(int('$BALANCE_BEFORE') - int('$BALANCE_AFTER'))")

echo "Gas limit:  $GAS_LIMIT"
echo "Gas used:   $GAS_USED"
echo "Gas price:  $GAS_PRICE wei"
echo ""
echo "Cost if gas_limit: $COST_IF_LIMIT wei"
echo "Cost if gas_used:  $COST_IF_USED wei"
echo "Actual spent:      $ACTUAL wei"
echo ""

# Determine model
DIFF_LIMIT=$(python3 -c "print(abs($ACTUAL - $COST_IF_LIMIT))")
DIFF_USED=$(python3 -c "print(abs($ACTUAL - $COST_IF_USED))")

if [ "$DIFF_LIMIT" -lt "$DIFF_USED" ]; then
    echo ">>> MONAD: Charged on GAS_LIMIT <<<"
    echo "    No refund for unused gas"
else
    echo ">>> ETHEREUM: Charged on GAS_USED <<<"
    echo "    Unused gas refunded"
fi
