// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/IStakingPrecompile.sol";

/// @title StakingPrecompileForkTest
/// @notice Fork-based tests for Monad staking precompile (implemented functions only)
/// @dev Run with: MONAD_RPC_URL="your-rpc-url" forge test --match-contract StakingPrecompileForkTest -vvv
/// @dev Tests all 10 read functions: getEpoch, getProposerValId, getValidator, getDelegator, getWithdrawalRequest,
/// @dev getConsensusValidatorSet, getSnapshotValidatorSet, getExecutionValidatorSet, getDelegations, getDelegators
/// @dev Note: Read functions are NOT view — they must be called via CALL (not STATICCALL)
contract StakingPrecompileForkTest is Test {
    address constant STAKING_ADDRESS = address(0x0000000000000000000000000000000000001000);
    IStakingPrecompile constant STAKING = IStakingPrecompile(STAKING_ADDRESS);

    // Default Monad RPC URL
    string constant DEFAULT_MONAD_RPC_URL = "https://rpc.monad.xyz";

    function setUp() public {
        // Fork from Monad mainnet (or custom RPC if MONAD_RPC_URL env var is set)
        string memory rpcUrl = vm.envOr("MONAD_RPC_URL", DEFAULT_MONAD_RPC_URL);
        vm.createSelectFork(rpcUrl);
    }

    // ============ Epoch Tests ============

    function testFork_GetEpoch() public {
        (uint64 epoch, bool inEpochDelayPeriod) = STAKING.getEpoch();
        console.log("Current epoch from fork:", epoch);
        console.log("In epoch delay period:", inEpochDelayPeriod);
        assertGt(epoch, 0, "Epoch should be > 0 on live chain");
    }

    function testFork_GetProposerValId() public {
        uint64 valId = STAKING.getProposerValId();
        console.log("Proposer validator ID:", valId);
        // Proposer ID should be a valid validator (>= 1)
        assertGt(valId, 0, "Proposer validator ID should be > 0");
    }

    // ============ Validator Info Tests ============

    function testFork_GetValidator() public {
        // Get proposer to ensure we query an existing validator
        uint64 proposerValId = STAKING.getProposerValId();

        // Use raw call (not staticcall) — staking precompile rejects STATICCALL
        bytes4 selector = bytes4(keccak256("getValidator(uint64)"));
        (bool success, bytes memory result) = address(STAKING).call(abi.encodeWithSelector(selector, proposerValId));

        require(success, "getValidator call failed");

        // Decode first few fields using assembly to avoid stack issues
        // Full return: (address, uint64, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, bytes, bytes)
        address authAddress;
        uint64 flags;
        uint256 stake;
        uint256 commission;
        assembly {
            authAddress := mload(add(result, 32))
            flags := mload(add(result, 64))
            stake := mload(add(result, 96))
            // skip accRewardPerToken at offset 128
            commission := mload(add(result, 160))
        }

        console.log("Validator", proposerValId, "auth address:", authAddress);
        console.log("Validator flags:", flags);
        console.log("Validator stake:", stake);
        console.log("Validator commission:", commission);

        // Verify validator has non-zero auth address on live chain
        assertTrue(authAddress != address(0), "Validator should have auth address");
    }

    // ============ Delegator Tests ============

    function testFork_GetDelegator() public {
        uint64 proposerValId = STAKING.getProposerValId();

        // Call with address(this) which has no delegation — should return zeros without reverting
        bytes4 selector = bytes4(keccak256("getDelegator(uint64,address)"));
        (bool success,) = address(STAKING).call(abi.encodeWithSelector(selector, proposerValId, address(this)));
        assertTrue(success, "getDelegator should not revert for unknown delegator");
    }

    // ============ Withdrawal Request Tests ============

    function testFork_GetWithdrawalRequest() public {
        uint64 proposerValId = STAKING.getProposerValId();

        // Call with address(this) which has no withdrawal — should return zeros without reverting
        bytes4 selector = bytes4(keccak256("getWithdrawalRequest(uint64,address,uint8)"));
        (bool success,) =
            address(STAKING).call(abi.encodeWithSelector(selector, proposerValId, address(this), uint8(0)));
        assertTrue(success, "getWithdrawalRequest should not revert for unknown withdrawal");
    }

    // ============ Validator Set Tests ============

    function testFork_GetConsensusValidatorSet() public {
        (bool isDone, uint32 nextIndex, uint64[] memory valIds) = STAKING.getConsensusValidatorSet(0);

        // Verify we got some validators on live chain
        assertGt(valIds.length, 0, "Should have at least one consensus validator");
        // nextIndex should be valIds.length when starting from 0
        assertEq(uint256(nextIndex), valIds.length, "nextIndex should equal returned count");
        // If less than 100 validators, isDone should be true
        if (valIds.length < 100) {
            assertTrue(isDone, "isDone should be true when < 100 validators");
        }
    }

    function testFork_GetSnapshotValidatorSet() public {
        (bool isDone, uint32 nextIndex, uint64[] memory valIds) = STAKING.getSnapshotValidatorSet(0);

        // Snapshot should have same validators as consensus (copy at epoch boundary)
        assertGt(valIds.length, 0, "Should have at least one snapshot validator");
        assertEq(uint256(nextIndex), valIds.length, "nextIndex should equal returned count");
    }

    function testFork_GetExecutionValidatorSet() public {
        (bool isDone, uint32 nextIndex, uint64[] memory valIds) = STAKING.getExecutionValidatorSet(0);

        // Execution set includes all validators (not just top 200)
        assertGt(valIds.length, 0, "Should have at least one execution validator");
        assertEq(uint256(nextIndex), valIds.length, "nextIndex should equal returned count");
    }

    function testFork_GetValidatorSet_Pagination() public {
        // Request past the end - should get empty array with isDone=true
        (bool isDonePastEnd,, uint64[] memory valIdsPastEnd) = STAKING.getConsensusValidatorSet(10000);
        assertTrue(isDonePastEnd, "Should be done when start index >= length");
        assertEq(valIdsPastEnd.length, 0, "Should return empty array when start >= length");
    }

    // ============ Delegation List Tests ============

    function testFork_GetDelegations() public {
        // Find a validator with known delegators by using a consensus validator
        (,, uint64[] memory consensusVals) = STAKING.getConsensusValidatorSet(0);
        require(consensusVals.length > 0, "Need at least one consensus validator");

        uint64 valId = consensusVals[0];

        // Get delegators for this validator to find a real delegator address
        (bool delsDone, address nextDel, address[] memory delegators) = STAKING.getDelegators(valId, address(0));
        console.log("Validator", valId, "has delegators (first page):", delegators.length);

        if (delegators.length > 0) {
            // Now test getDelegations for the first delegator
            address delegator = delegators[0];
            (bool isDone, uint64 nextValId, uint64[] memory valIds) = STAKING.getDelegations(delegator, 0);

            console.log("Delegator", delegator);
            console.log("  delegated to validators (first page):", valIds.length);
            console.log("  isDone:", isDone);
            console.log("  nextValId:", nextValId);

            // The delegator must be staked with at least the validator we found them through
            assertGt(valIds.length, 0, "Delegator should have at least one delegation");

            // Verify the validator we found them through is in the results
            bool found = false;
            for (uint256 i = 0; i < valIds.length; i++) {
                if (valIds[i] == valId) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "Delegation list should contain the validator we queried");

            // If isDone, nextValId should be 0
            if (isDone) {
                assertEq(nextValId, 0, "nextValId should be 0 when done");
            } else {
                assertGt(nextValId, 0, "nextValId should be > 0 when not done");
            }
        }
    }

    function testFork_GetDelegators() public {
        // Use a consensus validator — should have at least one delegator
        (,, uint64[] memory consensusVals) = STAKING.getConsensusValidatorSet(0);
        require(consensusVals.length > 0, "Need at least one consensus validator");

        uint64 valId = consensusVals[0];
        (bool isDone, address nextDelegator, address[] memory delegators) = STAKING.getDelegators(valId, address(0));

        console.log("Validator", valId, "delegators (first page):", delegators.length);
        console.log("  isDone:", isDone);

        // A consensus validator should have at least one delegator (itself or others)
        assertGt(delegators.length, 0, "Consensus validator should have at least one delegator");

        // All returned addresses should be non-zero
        for (uint256 i = 0; i < delegators.length; i++) {
            assertTrue(delegators[i] != address(0), "Delegator address should not be zero");
        }

        // If isDone, nextDelegator should be zero address
        if (isDone) {
            assertEq(nextDelegator, address(0), "nextDelegator should be zero when done");
        } else {
            assertTrue(nextDelegator != address(0), "nextDelegator should be non-zero when not done");
        }
    }

    function testFork_GetDelegations_EmptyForUnknown() public {
        // An address with no delegations should return empty
        (bool isDone, uint64 nextValId, uint64[] memory valIds) = STAKING.getDelegations(address(this), 0);
        assertTrue(isDone, "Should be done for address with no delegations");
        assertEq(valIds.length, 0, "Should return empty array for address with no delegations");
    }

    function testFork_GetDelegators_EmptyForUnknown() public {
        // A non-existent validator (very high ID) should return empty
        (bool isDone, address nextDelegator, address[] memory delegators) = STAKING.getDelegators(999999, address(0));
        assertTrue(isDone, "Should be done for non-existent validator");
        assertEq(delegators.length, 0, "Should return empty array for non-existent validator");
    }

    function testFork_GetDelegations_Pagination() public {
        // Find a delegator with known delegations
        (,, uint64[] memory consensusVals) = STAKING.getConsensusValidatorSet(0);
        require(consensusVals.length > 0, "Need at least one consensus validator");

        (,, address[] memory delegators) = STAKING.getDelegators(consensusVals[0], address(0));
        if (delegators.length > 0) {
            // Get first page
            (bool isDone1, uint64 nextValId1, uint64[] memory page1) = STAKING.getDelegations(delegators[0], 0);

            if (!isDone1 && nextValId1 > 0) {
                // Get second page using continuation token
                (bool isDone2,, uint64[] memory page2) = STAKING.getDelegations(delegators[0], nextValId1);
                console.log("Delegation pagination: page1 =", page1.length, "page2 =", page2.length);

                // Second page should not repeat first page entries
                if (page2.length > 0) {
                    bool overlap = false;
                    for (uint256 i = 0; i < page1.length && !overlap; i++) {
                        for (uint256 j = 0; j < page2.length && !overlap; j++) {
                            if (page1[i] == page2[j]) overlap = true;
                        }
                    }
                    assertFalse(overlap, "Paginated pages should not overlap");
                }
            }
        }
    }

    function testFork_GetDelegators_Pagination() public {
        (,, uint64[] memory consensusVals) = STAKING.getConsensusValidatorSet(0);
        require(consensusVals.length > 0, "Need at least one consensus validator");

        uint64 valId = consensusVals[0];

        // Get first page
        (bool isDone1, address nextDel1, address[] memory page1) = STAKING.getDelegators(valId, address(0));

        if (!isDone1 && nextDel1 != address(0)) {
            // Get second page using continuation token
            (bool isDone2,, address[] memory page2) = STAKING.getDelegators(valId, nextDel1);
            console.log("Delegator pagination: page1 =", page1.length, "page2 =", page2.length);

            // Second page should not repeat first page entries
            if (page2.length > 0) {
                bool overlap = false;
                for (uint256 i = 0; i < page1.length && !overlap; i++) {
                    for (uint256 j = 0; j < page2.length && !overlap; j++) {
                        if (page1[i] == page2[j]) overlap = true;
                    }
                }
                assertFalse(overlap, "Paginated pages should not overlap");
            }
        }
    }

    // ============ Validator Set Consistency Tests ============

    function testFork_ValidatorSets_Consistency() public {
        // All three sets should contain valid validator IDs
        (,, uint64[] memory consensusVals) = STAKING.getConsensusValidatorSet(0);
        (,, uint64[] memory snapshotVals) = STAKING.getSnapshotValidatorSet(0);
        (,, uint64[] memory executionVals) = STAKING.getExecutionValidatorSet(0);

        // Consensus and snapshot should have the same size (after epoch boundary)
        assertEq(consensusVals.length, snapshotVals.length, "Consensus and snapshot should have same size");

        // Execution set should be >= consensus set
        assertGe(executionVals.length, consensusVals.length, "Execution set should be >= consensus set");

        // Check that consensus validators exist in execution set
        if (consensusVals.length > 0) {
            bool found = false;
            for (uint256 i = 0; i < executionVals.length; i++) {
                if (executionVals[i] == consensusVals[0]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "First consensus validator should exist in execution set");
        }
    }
}
