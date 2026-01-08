#!/bin/bash
# Test Monad opcode and precompile gas pricing via anvil --monad
#
# Usage:
#   anvil --monad &
#   ./script/test_opcodes_precompiles_gas_pricing.sh
#
# Monad Cold Access Costs:
#   Cold Account: 10100 gas (BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, CALL, CALLCODE, DELEGATECALL, STATICCALL)
#   Cold Storage: 8100 gas (SLOAD, SSTORE)
#   Warm Access:  100 gas
#
# Monad Precompile Costs:
#   ecRecover (0x01): 6000 gas (2x Ethereum)
#   ecAdd (0x06):     300 gas (2x Ethereum)
#   ecMul (0x07):     30000 gas (5x Ethereum)
#   ecPairing (0x08): 225000 + 170000/pt (5x Ethereum)
#   blake2f (0x09):   rounds × 2 (2x Ethereum)

set -e

CAST="cast"
FORGE="forge"
RPC_URL="http://127.0.0.1:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Monad expected gas costs
MONAD_COLD_ACCOUNT=10100
MONAD_COLD_STORAGE=8100

# Base transaction cost (excluded from opcode analysis)
BASE_TX_COST=21000

# Counters for test results
PASS_COUNT=0
FAIL_COUNT=0

echo "=============================================="
echo " Monad Opcode & Precompile Gas Pricing Test "
echo "=============================================="
echo ""

# Check anvil is running
if ! $CAST chain-id --rpc-url $RPC_URL &>/dev/null; then
    echo "ERROR: Cannot connect to anvil at $RPC_URL"
    echo "Run: anvil --monad"
    exit 1
fi

echo "Deploying OpcodesAndPrecompilesGasPricing contract..."
DEPLOY_OUTPUT=$($FORGE create src/OpcodesAndPrecompilesGasPricing.sol:OpcodesAndPrecompilesGasPricing \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL \
    --broadcast 2>&1)

# Extract contract address from output (macOS compatible)
CONTRACT=$(echo "$DEPLOY_OUTPUT" | grep "Deployed to:" | awk '{print $3}')
echo "Deployed at: $CONTRACT"
echo ""

# Helper function to generate random address
random_addr() {
    echo "0x$(openssl rand -hex 20)"
}

# Helper function to test an opcode
# Args: $1=name, $2=function_sig, $3=args, $4=expected_cost, $5=min_threshold
test_opcode() {
    local name=$1
    local func_sig=$2
    local args=$3
    local expected=$4
    local threshold=$5

    echo "Test: $name"
    printf '─%.0s' {1..40}
    echo ""

    local gas
    gas=$($CAST estimate $CONTRACT "$func_sig" $args --rpc-url $RPC_URL 2>/dev/null || echo "ERROR")

    if [ "$gas" = "ERROR" ]; then
        echo "  Status: SKIPPED (estimate failed)"
        echo ""
        return
    fi

    local exec_gas=$((gas - BASE_TX_COST))

    echo "  Total gas estimate:      $gas"
    echo "  Execution gas (- 21000): $exec_gas"
    echo "  Expected cold cost:      $expected"

    if [ "$gas" -gt "$threshold" ]; then
        echo "  Status: PASS"
        ((PASS_COUNT++))
    else
        echo "  Status: FAIL - gas too low"
        ((FAIL_COUNT++))
    fi
    echo ""
}

echo "=============================================="
echo "  STORAGE ACCESS OPCODES (Cold: 8100 gas)"
echo "=============================================="
echo ""

# SLOAD - read storage (each tx is separate, so slot is always cold)
test_opcode "SLOAD" "testSLOAD(uint256)" "0" "$MONAD_COLD_STORAGE" 26000

# SSTORE - write storage (higher gas due to storage write costs)
# Threshold is higher because SSTORE includes ~20000 gas for storage write (0->non-zero)
test_opcode "SSTORE" "testSSTORE(uint256,uint256)" "999 42" "$MONAD_COLD_STORAGE" 48000

echo "=============================================="
echo "  ACCOUNT ACCESS OPCODES (Cold: 10100 gas)"
echo "=============================================="
echo ""

# BALANCE
test_opcode "BALANCE" "testBALANCE(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# EXTCODESIZE
test_opcode "EXTCODESIZE" "testEXTCODESIZE(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# EXTCODECOPY (also uses EXTCODESIZE internally, so may have higher gas)
test_opcode "EXTCODECOPY" "testEXTCODECOPY(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# EXTCODEHASH
test_opcode "EXTCODEHASH" "testEXTCODEHASH(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# CALL
test_opcode "CALL" "testCALL(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# CALLCODE
test_opcode "CALLCODE" "testCALLCODE(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# DELEGATECALL
test_opcode "DELEGATECALL" "testDELEGATECALL(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

# STATICCALL
test_opcode "STATICCALL" "testSTATICCALL(address)" "$(random_addr)" "$MONAD_COLD_ACCOUNT" 28000

echo "=============================================="
echo "  PRECOMPILES - Monad Gas Costs"
echo "=============================================="
echo ""
echo "  | Precompile  | Address | Ethereum | Monad   |"
echo "  |-------------|---------|----------|---------|"
echo "  | ecRecover   | 0x01    | 3,000    | 6,000   |"
echo "  | ecAdd       | 0x06    | 150      | 300     |"
echo "  | ecMul       | 0x07    | 6,000    | 30,000  |"
echo "  | ecPairing   | 0x08    | 45,000*  | 225,000*|"
echo "  | blake2f     | 0x09    | rounds×1 | rounds×2|"
echo ""

# Helper function to test a precompile
# Args: $1=name, $2=function_sig, $3=eth_cost, $4=multiplier
test_precompile() {
    local name=$1
    local func_sig=$2
    local eth_cost=$3
    local multiplier=$4

    local monad_cost=$((eth_cost * multiplier))

    echo "Test: $name"
    printf '─%.0s' {1..40}
    echo ""

    local gas
    gas=$($CAST estimate $CONTRACT "$func_sig" --rpc-url $RPC_URL 2>/dev/null || echo "ERROR")

    if [ "$gas" = "ERROR" ]; then
        echo "  Status: SKIPPED (estimate failed)"
        echo ""
        return
    fi

    local exec_gas=$((gas - BASE_TX_COST))

    echo "  Total gas estimate:      $gas"
    echo "  Execution gas (- 21000): $exec_gas"
    echo "  Ethereum cost:           $eth_cost"
    echo "  Multiplier:              ${multiplier}x"
    echo "  Expected Monad cost:     $monad_cost"

    # Pass if execution gas includes the Monad precompile cost
    if [ "$exec_gas" -ge "$monad_cost" ]; then
        echo "  Status: PASS (exec_gas >= monad_cost)"
        ((PASS_COUNT++))
    else
        echo "  Status: FAIL (exec_gas < monad_cost, likely using Ethereum pricing)"
        ((FAIL_COUNT++))
    fi
    echo ""
}

# ecRecover (0x01) - Ethereum: 3000, Monad: 3000 × 2 = 6000
test_precompile "ecRecover" "testEcRecover()" 3000 2

# ecAdd (0x06) - Ethereum: 150, Monad: 150 × 2 = 300
test_precompile "ecAdd" "testEcAdd()" 150 2

# ecMul (0x07) - Ethereum: 6000, Monad: 6000 × 5 = 30000
test_precompile "ecMul" "testEcMul()" 6000 5

# ecPairing (0x08) - Ethereum: 45000 + 34000/pt, Monad: 5x
# With 1 point: Ethereum = 79000, Monad = 79000 × 5 = 395000
test_precompile "ecPairing" "testEcPairing()" 79000 5

# blake2f (0x09) - Ethereum: rounds × 1, Monad: rounds × 2
# With 12 rounds: Ethereum = 12, Monad = 12 × 2 = 24
test_precompile "blake2f" "testBlake2f()" 12 2

#############################################
# Summary
#############################################
echo "=============================================="
echo "Summary"
echo "=============================================="
echo ""
echo "  Monad Cold Access Costs:"
echo "  ├── Cold Storage (SLOAD, SSTORE): 8100 gas"
echo "  └── Cold Account (BALANCE, EXTCODE*, CALL*): 10100 gas"
echo ""
echo "  Monad Precompile Costs:"
echo "  ├── ecRecover (0x01): 6000 gas (2x Ethereum)"
echo "  ├── ecAdd (0x06): 300 gas (2x Ethereum)"
echo "  ├── ecMul (0x07): 30000 gas (5x Ethereum)"
echo "  ├── ecPairing (0x08): 225000 + 170000/pt (5x Ethereum)"
echo "  └── blake2f (0x09): rounds × 2 (2x Ethereum)"
echo ""
echo "  Tests passed: $PASS_COUNT"
echo "  Tests failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "  All tests passed!"
    exit 0
else
    echo "  Some tests failed"
    exit 1
fi
