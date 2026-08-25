#!/bin/bash
#
# MIP-8 Integration Test Runner
#
# Runs pagified-state assertions on MonadTen and verifies the feature remains
# disabled on MonadNine.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

cd "$(dirname "$0")/../.."

PASSED=0
FAILED=0

FORGE_PROJECT_ENV_ARG=""
if (cd / && command forge --help 2>&1) | grep -q -- "--allow-project-env"; then
    FORGE_PROJECT_ENV_ARG="--allow-project-env"
fi

forge() {
    if [[ -n "$FORGE_PROJECT_ENV_ARG" ]]; then
        command forge "$FORGE_PROJECT_ENV_ARG" "$@"
    else
        command forge "$@"
    fi
}

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAILED=$((FAILED + 1)); }

run_profile() {
    local label="$1"
    local profile="$2"
    local contract="$3"
    local output status parsed_failures

    echo -e "${YELLOW}[$label]${NC}"
    set +e
    output=$(FOUNDRY_PROFILE="$profile" forge test \
        --match-path test/Mip8PagifiedStateTest.t.sol \
        --match-contract "$contract" \
        -vv 2>&1)
    status=$?
    set -e

    parsed_failures=0
    while IFS= read -r line; do
        if [[ $line == "Suite result:"* ]]; then
            break
        fi
        if [[ $line =~ \[PASS\] ]]; then
            name=$(echo "$line" | sed 's/\[PASS\] //' | cut -d'(' -f1 | xargs)
            pass "$name"
        elif [[ $line =~ \[FAIL ]]; then
            name=$(echo "$line" | sed 's/\[FAIL[^]]*\] //' | cut -d'(' -f1 | xargs)
            fail "$name"
            parsed_failures=$((parsed_failures + 1))
        fi
    done <<< "$output"

    if [[ $status -ne 0 && $parsed_failures -eq 0 ]]; then
        echo "$output"
        fail "$label command failed"
    fi
    echo ""
}

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  MIP-8 PAGIFIED STATE INTEGRATION TESTS${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

run_profile "MonadTen — Exact MIP-8 Assertions" monad_ten MonadTenMip8PagifiedStateTest
run_profile "MonadNine — Hardfork-Gating Semantics" monad_nine MonadNineMip8RegressionTest

TOTAL=$((PASSED + FAILED))
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}  All $TOTAL tests passed.${NC}"
else
    echo -e "${RED}  $FAILED/$TOTAL tests failed.${NC}"
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

exit "$FAILED"
