#!/bin/bash
# Test Monad gas charging behavior using cast against anvil
#
# Usage:
#   anvil --monad &    # Start anvil with Monad gas model
#   ./test_monad_gas.sh
#
#   anvil &            # Start anvil with Ethereum gas model
#   ./test_monad_gas.sh
#
# Expected Results:
#   Monad:    gas_charged == gas_limit (no refunds)
#   Ethereum: gas_charged <  gas_limit (refund unused gas)

set -e

CAST="cast"
FORGE="forge"
RPC_URL="http://127.0.0.1:8545"

# Anvil's default test account (Account #0)
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RECIPIENT="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

echo "=============================================="
echo "       Monad vs Ethereum Gas Model Test       "
echo "=============================================="
echo ""

# Check if anvil is running
if ! $CAST chain-id --rpc-url $RPC_URL &>/dev/null; then
    echo "ERROR: Cannot connect to anvil at $RPC_URL"
    echo "Please run: anvil --monad  OR  anvil"
    exit 1
fi

CHAIN_ID=$($CAST chain-id --rpc-url $RPC_URL)
echo "Connected to chain ID: $CHAIN_ID"
echo ""

#############################################
# Test 1: Simple Transfer
#############################################
echo "Test: Simple ETH Transfer"
echo "─────────────────────────────────────────────"

GAS_LIMIT=100000
GAS_PRICE="1000000000"  # 1 gwei
VALUE_SENT="1000000000000000"  # 0.001 ETH in wei

# Get balance before
BALANCE_BEFORE=$($CAST balance $SENDER --rpc-url $RPC_URL)

# Send transaction
$CAST send $RECIPIENT \
    --value 0.001ether \
    --gas-limit $GAS_LIMIT \
    --gas-price $GAS_PRICE \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL \
    > /dev/null 2>&1

sleep 1

# Get balance after
BALANCE_AFTER=$($CAST balance $SENDER --rpc-url $RPC_URL)

# Calculate gas charged (balance_before - balance_after - value_sent) / gas_price
GAS_COST_WEI=$(echo "$BALANCE_BEFORE - $BALANCE_AFTER - $VALUE_SENT" | bc)
GAS_CHARGED=$(echo "$GAS_COST_WEI / $GAS_PRICE" | bc)

echo ""
echo "  Gas Limit:   $GAS_LIMIT"
echo "  Gas Charged: $GAS_CHARGED"
echo ""

if [ "$GAS_CHARGED" = "$GAS_LIMIT" ]; then
    echo ">>> MONAD: gas_charged == gas_limit (no refunds)"
elif [ "$GAS_CHARGED" -lt "$GAS_LIMIT" ]; then
    echo ">>> ETHEREUM: gas_charged < gas_limit (refund unused)"
else
    echo ">>> UNEXPECTED: gas_charged > gas_limit"
fi

echo ""
echo "=============================================="

#############################################
# Test 2: Contract Deployment (commented out)
#############################################
# echo ""
# echo "┌─────────────────────────────────────────────┐"
# echo "│ Test 2: Contract Deployment                 │"
# echo "└─────────────────────────────────────────────┘"

# cd /Users/haythem/Projects/Category/monad-foundry-integration

# DEPLOY_GAS_LIMIT=500000
# echo "Parameters:"
# echo "  Gas limit:  $DEPLOY_GAS_LIMIT"
# echo "  Gas price:  $GAS_PRICE wei (1 gwei)"
# echo ""

# # Get balance before
# BALANCE_BEFORE=$($CAST balance $SENDER --rpc-url $RPC_URL)
# echo "Sender balance before: $BALANCE_BEFORE wei"

# # Deploy contract
# $FORGE create src/Counter.sol:Counter \
#     --gas-limit $DEPLOY_GAS_LIMIT \
#     --gas-price $GAS_PRICE \
#     --private-key $PRIVATE_KEY \
#     --rpc-url $RPC_URL \
#     --broadcast \
#     > /dev/null 2>&1

# sleep 1

# # Get balance after
# BALANCE_AFTER=$($CAST balance $SENDER --rpc-url $RPC_URL)
# echo "Sender balance after:  $BALANCE_AFTER wei"

# DEPLOY_COST=$(echo "$BALANCE_BEFORE - $BALANCE_AFTER" | bc)
# DEPLOY_GAS_UNITS=$(echo "$DEPLOY_COST / $GAS_PRICE" | bc)
# MAX_COST=$((DEPLOY_GAS_LIMIT * GAS_PRICE))

# echo ""
# echo "Results:"
# echo "  Deployment cost:    $DEPLOY_COST wei"
# echo "  Gas units charged:  $DEPLOY_GAS_UNITS"
# echo "  Max possible:       $MAX_COST wei ($DEPLOY_GAS_LIMIT gas)"
# echo ""

# if [ "$DEPLOY_COST" = "$MAX_COST" ]; then
#     echo ">>> RESULT: MONAD gas model - Full gas_limit charged"
#     TEST2_MODEL="monad"
# else
#     echo ">>> RESULT: ETHEREUM gas model - Less than gas_limit charged"
#     TEST2_MODEL="ethereum"
# fi
