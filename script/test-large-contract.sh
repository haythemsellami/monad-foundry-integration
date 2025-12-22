#!/bin/bash
# Test script to verify Monad's increased bytecode limit (128KB vs Ethereum's 24KB)
#
# Prerequisites: Start anvil before running this script
#   $ anvil
#
# Expected behavior:
# - With current Foundry (Ethereum limits): FAILS with "max code size exceeded"
# - With Monad-integrated Foundry (128KB limit): SUCCEEDS

set -e

echo "=== Monad Large Contract Deployment Test ==="
echo ""

# Check if forge is available
if ! command -v forge &> /dev/null; then
    echo "Error: forge not found. Please install Foundry."
    exit 1
fi

# Contract info
CONTRACT_NAME="OversizedContract"
CONTRACT_PATH="src/LargeContract.sol"

echo "Building contract..."
# Use --force to ignore size warnings during build
if ! forge build --force 2>&1; then
    echo "Build failed"
    exit 1
fi

# Get bytecode size
BYTECODE_SIZE=$(forge inspect $CONTRACT_NAME bytecode | wc -c)
BYTECODE_SIZE=$((BYTECODE_SIZE / 2 - 1))  # Convert hex chars to bytes, minus 0x prefix

echo ""
echo "Contract: $CONTRACT_NAME"
echo "Bytecode size: $BYTECODE_SIZE bytes ($((BYTECODE_SIZE / 1024)) KB)"
echo "Ethereum limit (EIP-170): 24,576 bytes (24 KB)"
echo "Monad limit: 131,072 bytes (128 KB)"
echo ""

# Default anvil private key
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

echo "Attempting to deploy $CONTRACT_NAME..."
echo ""

# Try to deploy
if forge create $CONTRACT_PATH:$CONTRACT_NAME --private-key $PRIVATE_KEY --rpc-url http://127.0.0.1:8545 2>&1; then
    echo ""
    echo "SUCCESS: Contract deployed!"
    echo "   This indicates Monad's 128KB bytecode limit is active."
    exit 0
else
    echo ""
    echo "FAILED: Contract deployment failed (expected with Ethereum limits)"
    echo "   The contract exceeds Ethereum's 24KB limit."
    echo "   Once monad-revm is integrated, this should succeed."
    exit 1
fi
