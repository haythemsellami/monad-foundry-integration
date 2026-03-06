#!/bin/bash

# Test Chisel Monad EVM Gas Costs
# Verifies chisel is using Monad-specific gas pricing

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  CHISEL MONAD GAS COST TESTS${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Helper to run chisel eval and extract gas value from return
get_gas() {
    local result=$(chisel eval -vvvvv "$1" 2>&1 | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
    printf "%d" "$result" 2>/dev/null || echo "0"
}

# Helper to check gas range
check_gas() {
    local name="$1" actual="$2" min="$3" max="$4" eth="$5"
    if [[ $actual -ge $min && $actual -le $max ]]; then
        echo -e "  ${GREEN}✓${NC} $name: $actual gas (Monad: $min-$max, ETH: ~$eth)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $name: $actual gas (Monad: $min-$max, ETH: ~$eth)"
        FAILED=$((FAILED + 1))
    fi
}

echo -e "${YELLOW}[COLD ACCESS]${NC}"

# Cold BALANCE (Monad: 10,100 vs Ethereum: 2,600)
GAS=$(get_gas 'assembly { let g1 := gas() let b := balance(0x1234567890123456789012345678901234567890) mstore(0, sub(g1, gas())) return(0, 32) }')
check_gas "BALANCE" "$GAS" 10100 10115 2600

# Cold SLOAD (Monad: 8,100 vs Ethereum: 2,100)
GAS=$(get_gas 'assembly { let g1 := gas() let s := sload(0x1234) mstore(0, sub(g1, gas())) return(0, 32) }')
check_gas "SLOAD" "$GAS" 8100 8115 2100

# Cold EXTCODESIZE (Monad: 10,100 vs Ethereum: 2,600)
GAS=$(get_gas 'assembly { let g1 := gas() let s := extcodesize(0x1234567890123456789012345678901234567890) mstore(0, sub(g1, gas())) return(0, 32) }')
check_gas "EXTCODESIZE" "$GAS" 10100 10115 2600

echo ""
echo -e "${YELLOW}[WARM ACCESS]${NC}"

# Warm BALANCE - use a variable to prevent optimization
GAS=$(get_gas 'assembly { let addr := 0x1234567890123456789012345678901234567890 let b1 := balance(addr) let g1 := gas() let b2 := balance(addr) let g2 := gas() mstore(0, sub(g1, g2)) mstore(32, add(b1, b2)) return(0, 64) }')
check_gas "BALANCE" "$GAS" 100 115 100

# Warm SLOAD - use a variable to prevent optimization
GAS=$(get_gas 'assembly { let slot := 0x5678 let s1 := sload(slot) let g1 := gas() let s2 := sload(slot) let g2 := gas() mstore(0, sub(g1, g2)) mstore(32, add(s1, s2)) return(0, 64) }')
check_gas "SLOAD" "$GAS" 100 115 100

echo ""

# Summary
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
