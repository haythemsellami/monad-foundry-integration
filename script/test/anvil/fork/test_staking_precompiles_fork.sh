#!/bin/bash

# Test Monad staking precompiles via anvil --monad with fork
# This validates real data from Monad mainnet
#
# Usage:
#   ./script/test/anvil/fork/test_staking_precompiles_fork.sh
#
#   # With custom RPC:
#   MONAD_RPC_URL="https://your-rpc.monad.xyz" ./script/test/anvil/fork/test_staking_precompiles_fork.sh
#
# Reference: https://docs.monad.xyz/developer-essentials/staking/staking-precompile

STAKING_ADDRESS="0x0000000000000000000000000000000000001000"
MONAD_RPC_URL="${MONAD_RPC_URL:-https://rpc.monad.xyz}"
# Use different port to avoid conflict with regular anvil tests
FORK_ANVIL_PORT="${FORK_ANVIL_PORT:-8546}"
RPC_URL="http://localhost:$FORK_ANVIL_PORT"

PASS_COUNT=0
FAIL_COUNT=0
ANVIL_PID=""

# Helper to increment counters
pass() { PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Cleanup function to kill anvil on exit
cleanup() {
    if [ -n "$ANVIL_PID" ]; then
        kill $ANVIL_PID 2>/dev/null || true
        wait $ANVIL_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=============================================="
echo " Monad Staking Precompiles Fork Test"
echo "=============================================="
echo ""
echo "Precompile address: $STAKING_ADDRESS"
echo "Monad RPC URL: $MONAD_RPC_URL"
echo "Local fork port: $FORK_ANVIL_PORT"
echo ""

# Start anvil with fork
echo "Starting anvil with Monad fork..."
anvil --monad --fork-url "$MONAD_RPC_URL" --port $FORK_ANVIL_PORT > /dev/null 2>&1 &
ANVIL_PID=$!

# Wait for anvil to be ready
for i in {1..30}; do
    if cast chain-id --rpc-url $RPC_URL > /dev/null 2>&1; then
        echo "✓ Anvil fork started (PID: $ANVIL_PID)"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: Anvil fork failed to start within 30 seconds"
        exit 1
    fi
    sleep 1
done

echo ""

echo "=============================================="
echo "  Fork Data Validation Tests"
echo "=============================================="
echo ""
echo "These tests verify real data is returned from the forked state."
echo ""

# ============================================
# Test getEpoch() - Should return non-zero epoch
# ============================================
echo "Test: getEpoch() returns non-zero epoch"
printf '─%.0s' {1..50}
echo ""

OUTPUT=$(cast call $STAKING_ADDRESS "getEpoch()(uint64,bool)" --rpc-url $RPC_URL 2>&1)
EPOCH=$(echo "$OUTPUT" | head -1)

if [[ $? -eq 0 ]] && [[ "$EPOCH" =~ ^[0-9]+$ ]] && [[ "$EPOCH" -gt 0 ]]; then
    echo "  Status: PASS"
    echo "  Epoch: $EPOCH"
    IN_DELAY=$(echo "$OUTPUT" | tail -1)
    echo "  In delay period: $IN_DELAY"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: epoch > 0"
    echo "  Got: $OUTPUT"
    fail
fi
echo ""

# ============================================
# Test getProposerValId() - Should return non-zero validator ID
# ============================================
echo "Test: getProposerValId() returns non-zero validator ID"
printf '─%.0s' {1..50}
echo ""

PROPOSER_VAL_ID=$(cast call $STAKING_ADDRESS "getProposerValId()(uint64)" --rpc-url $RPC_URL 2>&1)

if [[ $? -eq 0 ]] && [[ "$PROPOSER_VAL_ID" =~ ^[0-9]+$ ]] && [[ "$PROPOSER_VAL_ID" -gt 0 ]]; then
    echo "  Status: PASS"
    echo "  Proposer validator ID: $PROPOSER_VAL_ID"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: validator ID > 0"
    echo "  Got: $PROPOSER_VAL_ID"
    fail
fi
echo ""

# ============================================
# Test getValidator(proposerValId) - Should return non-zero auth address
# ============================================
echo "Test: getValidator($PROPOSER_VAL_ID) returns valid validator data"
printf '─%.0s' {1..50}
echo ""

# Get raw result and parse first field (authAddress)
OUTPUT=$(cast call $STAKING_ADDRESS "getValidator(uint64)(address,uint64,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes,bytes)" $PROPOSER_VAL_ID --rpc-url $RPC_URL 2>&1)
AUTH_ADDRESS=$(echo "$OUTPUT" | head -1)

if [[ $? -eq 0 ]] && [[ "$AUTH_ADDRESS" != "0x0000000000000000000000000000000000000000" ]]; then
    echo "  Status: PASS"
    echo "  Auth address: $AUTH_ADDRESS"
    # Parse more fields
    FLAGS=$(echo "$OUTPUT" | sed -n '2p')
    STAKE=$(echo "$OUTPUT" | sed -n '3p')
    echo "  Flags: $FLAGS"
    echo "  Stake: $STAKE"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: non-zero auth address"
    echo "  Got: $AUTH_ADDRESS"
    fail
fi
echo ""

# ============================================
# Test getConsensusValidatorSet(0) - Should return non-empty array
# ============================================
echo "Test: getConsensusValidatorSet(0) returns validators"
printf '─%.0s' {1..50}
echo ""

OUTPUT=$(cast call $STAKING_ADDRESS "getConsensusValidatorSet(uint32)(bool,uint32,uint64[])" 0 --rpc-url $RPC_URL 2>&1)
IS_DONE=$(echo "$OUTPUT" | head -1)
NEXT_INDEX=$(echo "$OUTPUT" | sed -n '2p')

if [[ $? -eq 0 ]] && [[ "$NEXT_INDEX" =~ ^[0-9]+$ ]] && [[ "$NEXT_INDEX" -gt 0 ]]; then
    echo "  Status: PASS"
    echo "  isDone: $IS_DONE"
    echo "  nextIndex (validator count): $NEXT_INDEX"
    # Show first few validator IDs
    echo "  First validators: $(echo "$OUTPUT" | tail -n +3 | head -3 | tr '\n' ' ')"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: nextIndex > 0 (validators exist)"
    echo "  Got: $OUTPUT"
    fail
fi
echo ""

# ============================================
# Test getSnapshotValidatorSet(0) - Should return non-empty array
# ============================================
echo "Test: getSnapshotValidatorSet(0) returns validators"
printf '─%.0s' {1..50}
echo ""

OUTPUT=$(cast call $STAKING_ADDRESS "getSnapshotValidatorSet(uint32)(bool,uint32,uint64[])" 0 --rpc-url $RPC_URL 2>&1)
NEXT_INDEX=$(echo "$OUTPUT" | sed -n '2p')

if [[ $? -eq 0 ]] && [[ "$NEXT_INDEX" =~ ^[0-9]+$ ]] && [[ "$NEXT_INDEX" -gt 0 ]]; then
    echo "  Status: PASS"
    echo "  Validator count: $NEXT_INDEX"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: validators > 0"
    echo "  Got: $OUTPUT"
    fail
fi
echo ""

# ============================================
# Test getExecutionValidatorSet(0) - Should return non-empty array
# ============================================
echo "Test: getExecutionValidatorSet(0) returns validators"
printf '─%.0s' {1..50}
echo ""

OUTPUT=$(cast call $STAKING_ADDRESS "getExecutionValidatorSet(uint32)(bool,uint32,uint64[])" 0 --rpc-url $RPC_URL 2>&1)
NEXT_INDEX=$(echo "$OUTPUT" | sed -n '2p')

if [[ $? -eq 0 ]] && [[ "$NEXT_INDEX" =~ ^[0-9]+$ ]] && [[ "$NEXT_INDEX" -gt 0 ]]; then
    echo "  Status: PASS"
    echo "  Validator count: $NEXT_INDEX"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: validators > 0"
    echo "  Got: $OUTPUT"
    fail
fi
echo ""

# ============================================
# Test validator set consistency
# ============================================
echo "Test: Validator sets consistency check"
printf '─%.0s' {1..50}
echo ""

CONSENSUS_COUNT=$(cast call $STAKING_ADDRESS "getConsensusValidatorSet(uint32)(bool,uint32,uint64[])" 0 --rpc-url $RPC_URL 2>&1 | sed -n '2p')
SNAPSHOT_COUNT=$(cast call $STAKING_ADDRESS "getSnapshotValidatorSet(uint32)(bool,uint32,uint64[])" 0 --rpc-url $RPC_URL 2>&1 | sed -n '2p')
EXECUTION_COUNT=$(cast call $STAKING_ADDRESS "getExecutionValidatorSet(uint32)(bool,uint32,uint64[])" 0 --rpc-url $RPC_URL 2>&1 | sed -n '2p')

# Consensus and snapshot should be equal, execution should be >= consensus
if [[ "$CONSENSUS_COUNT" == "$SNAPSHOT_COUNT" ]] && [[ "$EXECUTION_COUNT" -ge "$CONSENSUS_COUNT" ]]; then
    echo "  Status: PASS"
    echo "  Consensus validators: $CONSENSUS_COUNT"
    echo "  Snapshot validators: $SNAPSHOT_COUNT"
    echo "  Execution validators: $EXECUTION_COUNT"
    echo "  ✓ consensus == snapshot"
    echo "  ✓ execution >= consensus"
    pass
else
    echo "  Status: FAIL"
    echo "  Consensus: $CONSENSUS_COUNT, Snapshot: $SNAPSHOT_COUNT, Execution: $EXECUTION_COUNT"
    fail
fi
echo ""

# ============================================
# Test pagination - request past end
# ============================================
echo "Test: Pagination past end returns empty with isDone=true"
printf '─%.0s' {1..50}
echo ""

OUTPUT=$(cast call $STAKING_ADDRESS "getConsensusValidatorSet(uint32)(bool,uint32,uint64[])" 10000 --rpc-url $RPC_URL 2>&1)
IS_DONE=$(echo "$OUTPUT" | head -1)
# Extract just the number, ignoring cast's scientific notation like "10000 [1e4]"
NEXT_INDEX_RAW=$(echo "$OUTPUT" | sed -n '2p')
NEXT_INDEX=$(echo "$NEXT_INDEX_RAW" | awk '{print $1}')

if [[ "$IS_DONE" == "true" ]] && [[ "$NEXT_INDEX" == "10000" ]]; then
    echo "  Status: PASS"
    echo "  isDone: $IS_DONE (correct - past end)"
    echo "  nextIndex: $NEXT_INDEX (unchanged)"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: isDone=true, nextIndex=10000"
    echo "  Got: isDone=$IS_DONE, nextIndex=$NEXT_INDEX"
    fail
fi
echo ""

# ============================================
# Test getDelegators(validatorId, startDelegator) - Should return delegators for a consensus validator
# ============================================
echo "Test: getDelegators() returns delegators for consensus validator"
printf '─%.0s' {1..50}
echo ""

# Use the proposer validator ID (already fetched above)
OUTPUT=$(cast call $STAKING_ADDRESS "getDelegators(uint64,address)(bool,address,address[])" $PROPOSER_VAL_ID 0x0000000000000000000000000000000000000000 --rpc-url $RPC_URL 2>&1)
DELS_IS_DONE=$(echo "$OUTPUT" | head -1)
DELS_NEXT=$(echo "$OUTPUT" | sed -n '2p')
# The array is on line 3 as [addr1, addr2, ...] — extract first address
DELS_ARRAY_LINE=$(echo "$OUTPUT" | sed -n '3p')
FIRST_DELEGATOR=$(echo "$DELS_ARRAY_LINE" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
DELS_COUNT=$(echo "$DELS_ARRAY_LINE" | grep -oE '0x[0-9a-fA-F]{40}' | wc -l | tr -d ' ')

if [[ $? -eq 0 ]] && [[ "$DELS_COUNT" -gt 0 ]]; then
    echo "  Status: PASS"
    echo "  isDone: $DELS_IS_DONE"
    echo "  nextDelegator: $DELS_NEXT"
    echo "  Delegators returned: $DELS_COUNT"
    echo "  First delegator: $FIRST_DELEGATOR"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: at least one delegator for consensus validator $PROPOSER_VAL_ID"
    echo "  Got: $OUTPUT"
    fail
fi
echo ""

# ============================================
# Test getDelegations(delegator, startValId) - Should return validators for a known delegator
# ============================================
echo "Test: getDelegations() returns validators for a known delegator"
printf '─%.0s' {1..50}
echo ""

# FIRST_DELEGATOR was already extracted above from getDelegators output

if [[ -n "$FIRST_DELEGATOR" ]] && [[ "$FIRST_DELEGATOR" != "0x0000000000000000000000000000000000000000" ]]; then
    OUTPUT2=$(cast call $STAKING_ADDRESS "getDelegations(address,uint64)(bool,uint64,uint64[])" $FIRST_DELEGATOR 0 --rpc-url $RPC_URL 2>&1)
    DELEG_IS_DONE=$(echo "$OUTPUT2" | head -1)
    DELEG_NEXT_VAL=$(echo "$OUTPUT2" | sed -n '2p' | awk '{print $1}')
    # The array is on line 3 as [id1, id2, ...] — count entries
    DELEG_ARRAY_LINE=$(echo "$OUTPUT2" | sed -n '3p')
    DELEG_COUNT=$(echo "$DELEG_ARRAY_LINE" | grep -oE '[0-9]+' | wc -l | tr -d ' ')
    # Handle empty array []
    if [[ "$DELEG_ARRAY_LINE" == "[]" ]]; then DELEG_COUNT=0; fi

    if [[ $? -eq 0 ]] && [[ "$DELEG_COUNT" -gt 0 ]]; then
        echo "  Status: PASS"
        echo "  Delegator: $FIRST_DELEGATOR"
        echo "  isDone: $DELEG_IS_DONE"
        echo "  nextValId: $DELEG_NEXT_VAL"
        echo "  Validators delegated to: $DELEG_COUNT"
        FIRST_VAL=$(echo "$DELEG_ARRAY_LINE" | grep -oE '[0-9]+' | head -1)
        echo "  First validator: $FIRST_VAL"

        # Verify our proposer validator is in the list
        if echo "$DELEG_ARRAY_LINE" | grep -qE "(^|[^0-9])${PROPOSER_VAL_ID}([^0-9]|$)"; then
            echo "  ✓ Proposer validator $PROPOSER_VAL_ID found in delegation list"
        fi
        pass
    else
        echo "  Status: FAIL"
        echo "  Expected: at least one validator for delegator $FIRST_DELEGATOR"
        echo "  Got: $OUTPUT2"
        fail
    fi
else
    echo "  Status: SKIP (no delegator found from previous test)"
fi
echo ""

# ============================================
# Test getDelegations for unknown address - Should return empty
# ============================================
echo "Test: getDelegations() returns empty for unknown address"
printf '─%.0s' {1..50}
echo ""

OUTPUT3=$(cast call $STAKING_ADDRESS "getDelegations(address,uint64)(bool,uint64,uint64[])" 0x000000000000000000000000000000000000dead 0 --rpc-url $RPC_URL 2>&1)
EMPTY_IS_DONE=$(echo "$OUTPUT3" | head -1)
EMPTY_NEXT=$(echo "$OUTPUT3" | sed -n '2p' | awk '{print $1}')

if [[ "$EMPTY_IS_DONE" == "true" ]] && [[ "$EMPTY_NEXT" == "0" ]]; then
    echo "  Status: PASS"
    echo "  isDone: $EMPTY_IS_DONE (correct - no delegations)"
    echo "  nextValId: $EMPTY_NEXT"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: isDone=true, nextValId=0"
    echo "  Got: isDone=$EMPTY_IS_DONE, nextValId=$EMPTY_NEXT"
    fail
fi
echo ""

# ============================================
# Test getDelegators for non-existent validator - Should return empty
# ============================================
echo "Test: getDelegators() returns empty for non-existent validator"
printf '─%.0s' {1..50}
echo ""

OUTPUT4=$(cast call $STAKING_ADDRESS "getDelegators(uint64,address)(bool,address,address[])" 999999 0x0000000000000000000000000000000000000000 --rpc-url $RPC_URL 2>&1)
EMPTY2_IS_DONE=$(echo "$OUTPUT4" | head -1)
EMPTY2_NEXT=$(echo "$OUTPUT4" | sed -n '2p')

if [[ "$EMPTY2_IS_DONE" == "true" ]] && [[ "$EMPTY2_NEXT" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "  Status: PASS"
    echo "  isDone: $EMPTY2_IS_DONE (correct - no delegators)"
    echo "  nextDelegator: $EMPTY2_NEXT"
    pass
else
    echo "  Status: FAIL"
    echo "  Expected: isDone=true, nextDelegator=0x0"
    echo "  Got: isDone=$EMPTY2_IS_DONE, nextDelegator=$EMPTY2_NEXT"
    fail
fi
echo ""

# ============================================
# Summary
# ============================================
echo "=============================================="
echo "  Summary"
echo "=============================================="
echo ""
echo "  Fork source: $MONAD_RPC_URL"
echo "  Tests passed: $PASS_COUNT"
echo "  Tests failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "  ✓ All fork tests passed!"
    exit 0
else
    echo "  ✗ Some fork tests failed"
    exit 1
fi
