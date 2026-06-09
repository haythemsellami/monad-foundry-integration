#!/bin/bash

# Monad Foundry Integration - Full Test Suite Runner

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
FAILED_TESTS=()

# Navigate to project root (parent of script/)
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Keep script parsing stable when using Monad nightly builds.
export FOUNDRY_DISABLE_NIGHTLY_WARNING="${FOUNDRY_DISABLE_NIGHTLY_WARNING:-1}"

is_retryable_rpc_file() {
    local logfile="$1"
    grep -Eiq '429|Too Many Requests|No response|timed out|timeout|connection reset|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout' "$logfile"
}

run_and_capture() {
    local logfile="$1"
    local label="$2"
    shift 2

    local cmd_pid
    local start_ts
    local heartbeat_interval=30
    local poll_interval=5
    local idle_for=0
    local last_size=0
    local current_size=0

    start_ts=$(date +%s)
    : >"$logfile"
    "$@" > >(tee "$logfile") 2>&1 &
    cmd_pid=$!

    while kill -0 "$cmd_pid" 2>/dev/null; do
        sleep "$poll_interval"
        current_size=$(wc -c < "$logfile" | tr -d ' ')

        if [ "$current_size" -gt "$last_size" ]; then
            last_size=$current_size
            idle_for=0
            continue
        fi

        idle_for=$((idle_for + poll_interval))
        if [ $idle_for -ge $heartbeat_interval ] && kill -0 "$cmd_pid" 2>/dev/null; then
            echo -e "    ${CYAN}…${NC} Still running $label ($(($(date +%s) - start_ts))s)"
            idle_for=0
        fi
    done

    wait "$cmd_pid"
    return $?
}

run_step() {
    local label="$1"
    local logfile="$2"
    shift 2

    local start_ts
    local duration
    local status

    start_ts=$(date +%s)
    echo -e "  ${CYAN}▶${NC} Running $label..."

    if run_and_capture "$logfile" "$label" "$@"; then
        status=0
    else
        status=$?
    fi

    duration=$(( $(date +%s) - start_ts ))
    if [ $status -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Finished $label (${duration}s)"
    else
        echo -e "  ${RED}✗${NC} Finished $label (${duration}s)"
    fi

    return $status
}

discover_forge_suites() {
    rg -l 'function test|contract .* is Test' "$PROJECT_ROOT/test" "$PROJECT_ROOT/src" -g '*.sol' \
        | sort \
        | while IFS= read -r suite; do
            [[ "$(basename "$suite")" == Mip* ]] && continue
            echo "$suite"
        done
}

run_forge_suite_with_retry() {
    local logfile="$1"
    local suite_path="$2"
    local suite_label="${suite_path#$PROJECT_ROOT/}"
    local max_retries=3
    local attempt=1
    local status=0

    while [ $attempt -le $max_retries ]; do
        : >"$logfile"
        run_and_capture "$logfile" "forge suite $suite_label" forge test --match-path "$suite_label"
        status=$?

        if [ $status -eq 0 ]; then
            return 0
        fi

        if ! is_retryable_rpc_file "$logfile"; then
            return $status
        fi

        echo "    forge suite $suite_label hit a retryable RPC error; retrying ($attempt/$max_retries)..." >&2
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
    done

    return $status
}

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  MONAD FOUNDRY INTEGRATION TESTS${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# ============================================================================
# FORGE TESTS
# ============================================================================
echo -e "${YELLOW}[FORGE TESTS]${NC}"

FORGE_SUITES=()
while IFS= read -r suite; do
    FORGE_SUITES+=("$suite")
done < <(discover_forge_suites)
echo "  Discovered ${#FORGE_SUITES[@]} forge suite files"

FORGE_PASSED=0
FORGE_FAILED=0

for suite in "${FORGE_SUITES[@]}"; do
    suite_label="${suite#$PROJECT_ROOT/}"
    suite_log=$(mktemp)
    suite_start_ts=$(date +%s)

    echo -e "  ${CYAN}▶${NC} Running forge suite $suite_label..."
    run_forge_suite_with_retry "$suite_log" "$suite"
    suite_status=$?
    suite_duration=$(( $(date +%s) - suite_start_ts ))

    if [ $suite_status -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Finished forge suite $suite_label (${suite_duration}s)"
    else
        echo -e "  ${RED}✗${NC} Finished forge suite $suite_label (${suite_duration}s)"
    fi

    suite_output=$(cat "$suite_log")
    rm -f "$suite_log"

    suite_passed=$(echo "$suite_output" | grep -c '^\[PASS\]' || true)
    suite_fail_lines=$(echo "$suite_output" | grep '^\[FAIL' | awk '!seen[$0]++' || true)
    suite_failed=$(echo "$suite_fail_lines" | sed '/^$/d' | wc -l | tr -d ' ')

    FORGE_PASSED=$((FORGE_PASSED + suite_passed))
    FORGE_FAILED=$((FORGE_FAILED + suite_failed))
    PASSED=$((PASSED + suite_passed))
    FAILED=$((FAILED + suite_failed))

    if [[ $suite_failed -gt 0 ]]; then
        while IFS= read -r line; do
            test_name=$(echo "$line" | sed 's/\[FAIL[^]]*\] //' | cut -d'(' -f1 | xargs)
            FAILED_TESTS+=("forge: $suite_label :: $test_name")
        done <<< "$suite_fail_lines"
    fi

    if [[ $suite_status -ne 0 && $suite_failed -eq 0 ]]; then
        FAILED=$((FAILED + 1))
        FORGE_FAILED=$((FORGE_FAILED + 1))
        FAILED_TESTS+=("forge: $suite_label (command failed)")
    fi
done

echo -e "  Forge summary: ${GREEN}${FORGE_PASSED} passed${NC}, ${RED}${FORGE_FAILED} failed${NC}"

echo ""

# ============================================================================
# CHISEL TESTS
# ============================================================================
echo -e "${YELLOW}[CHISEL TESTS]${NC}"

# Run chisel tests (no anvil needed)
for script in "$PROJECT_ROOT"/script/test/chisel/*.sh; do
    [[ -f "$script" ]] || continue
    script_name=$(basename "$script")
    output_file=$(mktemp)

    if run_step "$script_name" "$output_file" "$script"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("chisel: $script_name")
    fi
    rm -f "$output_file"
done

echo ""

# ============================================================================
# MIP-3 MEMORY TESTS
# ============================================================================
echo -e "${YELLOW}[MIP-3 MEMORY TESTS]${NC}"

MIP3_LOG=$(mktemp)
run_step "test_mip3.sh" "$MIP3_LOG" "$PROJECT_ROOT/script/forge/test_mip3.sh" || true
MIP3_OUTPUT=$(cat "$MIP3_LOG")
rm -f "$MIP3_LOG"

# Parse pass/fail from the mip3 script output
MIP3_PASSED=$(echo "$MIP3_OUTPUT" | grep -c 'PASS' || true)
MIP3_FAILED=$(echo "$MIP3_OUTPUT" | grep -c 'FAIL' || true)

PASSED=$((PASSED + MIP3_PASSED))
FAILED=$((FAILED + MIP3_FAILED))

echo -e "  MIP-3 summary: ${GREEN}${MIP3_PASSED} passed${NC}, ${RED}${MIP3_FAILED} failed${NC}"

if [[ $MIP3_FAILED -gt 0 ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name=$(echo "$line" | sed 's/.*FAIL //')
        FAILED_TESTS+=("mip3: $name")
    done <<< "$(echo "$MIP3_OUTPUT" | grep 'FAIL' || true)"
fi

echo ""

# ============================================================================
# MIP-4 RESERVE BALANCE TESTS
# ============================================================================
echo -e "${YELLOW}[MIP-4 RESERVE BALANCE TESTS]${NC}"

MIP4_LOG=$(mktemp)
run_step "test_mip4.sh" "$MIP4_LOG" "$PROJECT_ROOT/script/forge/test_mip4.sh" || true
MIP4_OUTPUT=$(cat "$MIP4_LOG")
rm -f "$MIP4_LOG"

MIP4_PASSED=$(echo "$MIP4_OUTPUT" | grep -c 'PASS' || true)
MIP4_FAILED=$(echo "$MIP4_OUTPUT" | grep -c 'FAIL' || true)

PASSED=$((PASSED + MIP4_PASSED))
FAILED=$((FAILED + MIP4_FAILED))

echo -e "  MIP-4 summary: ${GREEN}${MIP4_PASSED} passed${NC}, ${RED}${MIP4_FAILED} failed${NC}"

if [[ $MIP4_FAILED -gt 0 ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name=$(echo "$line" | sed 's/.*FAIL //')
        FAILED_TESTS+=("mip4: $name")
    done <<< "$(echo "$MIP4_OUTPUT" | grep 'FAIL' || true)"
fi

echo ""

# ============================================================================
# ANVIL TESTS
# ============================================================================
echo -e "${YELLOW}[ANVIL TESTS]${NC}"

# Start anvil if not running
ANVIL_PID=""
if ! cast chain-id --rpc-url http://localhost:8545 &>/dev/null; then
    echo -e "  ${CYAN}Starting anvil --monad...${NC}"
    anvil --monad &>/dev/null &
    ANVIL_PID=$!
    sleep 2
    if ! cast chain-id --rpc-url http://localhost:8545 &>/dev/null; then
        echo -e "  ${RED}✗${NC} Failed to start anvil --monad"
        exit 1
    fi
fi

# Run anvil tests
for script in "$PROJECT_ROOT"/script/test/anvil/*.sh; do
    [[ -f "$script" ]] || continue
    script_name=$(basename "$script")
    output_file=$(mktemp)

    if run_step "$script_name" "$output_file" "$script"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("anvil: $script_name")
    fi
    rm -f "$output_file"
done

# Cleanup anvil if we started it
[[ -n "$ANVIL_PID" ]] && kill $ANVIL_PID 2>/dev/null

echo ""

# ============================================================================
# ANVIL FORK TESTS (uses separate anvil instance with Monad fork)
# ============================================================================
echo -e "${YELLOW}[ANVIL FORK TESTS]${NC}"

# Check if MONAD_RPC_URL is set or use default
MONAD_RPC_URL="${MONAD_RPC_URL:-https://rpc.monad.xyz}"

# Run fork tests (each script manages its own anvil fork instance)
for script in "$PROJECT_ROOT"/script/test/anvil/fork/*.sh; do
    [[ -f "$script" ]] || continue
    script_name=$(basename "$script")
    output_file=$(mktemp)

    if run_step "$script_name" "$output_file" env MONAD_RPC_URL="$MONAD_RPC_URL" "$script"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("anvil-fork: $script_name")
    fi
    rm -f "$output_file"
done

echo ""

# ============================================================================
# SUMMARY
# ============================================================================
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
TOTAL=$((PASSED + FAILED))
echo -e "  Total: $TOTAL  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo -e "  ${RED}Failed:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}•${NC} $test"
    done
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
