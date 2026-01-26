// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/IStakingPrecompile.sol";

/// @title StakingPrecompileForkTest
/// @notice Fork-based tests for Monad staking precompile (implemented functions only)
/// @dev Run with: MONAD_RPC_URL="your-rpc-url" forge test --match-contract StakingPrecompileForkTest -vvv
/// @dev Tests the 8 implemented view functions: getEpoch, getProposerValId, getValidator, getDelegator, getWithdrawalRequest,
/// @dev getConsensusValidatorSet, getSnapshotValidatorSet, getExecutionValidatorSet
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

    function testFork_GetEpoch() public view {
        (uint64 epoch, bool inEpochDelayPeriod) = STAKING.getEpoch();
        console.log("Current epoch from fork:", epoch);
        console.log("In epoch delay period:", inEpochDelayPeriod);
        assertGt(epoch, 0, "Epoch should be > 0 on live chain");
    }

    function testFork_GetProposerValId() public view {
        uint64 valId = STAKING.getProposerValId();
        console.log("Proposer validator ID:", valId);
        // Proposer ID should be a valid validator (>= 1)
        assertGt(valId, 0, "Proposer validator ID should be > 0");
    }

    // ============ Validator Info Tests ============

    function testFork_GetValidator() public view {
        // Get proposer to ensure we query an existing validator
        uint64 proposerValId = STAKING.getProposerValId();

        // Use raw call to avoid stack too deep with full tuple
        bytes4 selector = bytes4(keccak256("getValidator(uint64)"));
        (bool success, bytes memory result) = address(STAKING).staticcall(
            abi.encodeWithSelector(selector, proposerValId)
        );

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

    // TODO: fix later once delegate feature implemented in the precompile
    // function testFork_GetDelegator() public view {
    //     uint64 proposerValId = STAKING.getProposerValId();
    //     address delegator = vm.envOr("DELEGATOR_ADDRESS", address(this));

    //     (
    //         uint256 stake,
    //         uint256 accRewardPerToken,
    //         uint256 unclaimedRewards,
    //         uint256 deltaStake,
    //         uint256 nextDeltaStake,
    //         uint64 deltaEpoch,
    //         uint64 nextDeltaEpoch
    //     ) = STAKING.getDelegator(proposerValId, delegator);

    //     console.log("Delegator stake:", stake);
    //     console.log("Delegator accRewardPerToken:", accRewardPerToken);
    //     console.log("Delegator unclaimedRewards:", unclaimedRewards);
    //     console.log("Delegator deltaStake:", deltaStake);
    //     console.log("Delegator nextDeltaStake:", nextDeltaStake);
    //     console.log("Delegator deltaEpoch:", deltaEpoch);
    //     console.log("Delegator nextDeltaEpoch:", nextDeltaEpoch);
    // }

    // ============ Withdrawal Request Tests ============

    // TODO: fix later once delegate and withdraw features are implemented in the precompile
    // function testFork_GetWithdrawalRequest() public view {
    //     uint64 proposerValId = STAKING.getProposerValId();
    //     address delegator = vm.envOr("DELEGATOR_ADDRESS", address(this));

    //     (uint256 amount, uint256 accRewardPerToken, uint64 epoch) = STAKING.getWithdrawalRequest(proposerValId, delegator, 0);

    //     console.log("Withdrawal request amount:", amount);
    //     console.log("Withdrawal request accRewardPerToken:", accRewardPerToken);
    //     console.log("Withdrawal request epoch:", epoch);
    // }

    // ============ Validator Set Tests ============

    function testFork_GetConsensusValidatorSet() public view {
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

    function testFork_GetSnapshotValidatorSet() public view {
        (bool isDone, uint32 nextIndex, uint64[] memory valIds) = STAKING.getSnapshotValidatorSet(0);

        // Snapshot should have same validators as consensus (copy at epoch boundary)
        assertGt(valIds.length, 0, "Should have at least one snapshot validator");
        assertEq(uint256(nextIndex), valIds.length, "nextIndex should equal returned count");
    }

    function testFork_GetExecutionValidatorSet() public view {
        (bool isDone, uint32 nextIndex, uint64[] memory valIds) = STAKING.getExecutionValidatorSet(0);

        // Execution set includes all validators (not just top 200)
        assertGt(valIds.length, 0, "Should have at least one execution validator");
        assertEq(uint256(nextIndex), valIds.length, "nextIndex should equal returned count");
    }

    function testFork_GetValidatorSet_Pagination() public view {
        // Request past the end - should get empty array with isDone=true
        (bool isDonePastEnd,, uint64[] memory valIdsPastEnd) = STAKING.getConsensusValidatorSet(10000);
        assertTrue(isDonePastEnd, "Should be done when start index >= length");
        assertEq(valIdsPastEnd.length, 0, "Should return empty array when start >= length");
    }

    function testFork_ValidatorSets_Consistency() public view {
        // All three sets should contain valid validator IDs
        (, , uint64[] memory consensusVals) = STAKING.getConsensusValidatorSet(0);
        (, , uint64[] memory snapshotVals) = STAKING.getSnapshotValidatorSet(0);
        (, , uint64[] memory executionVals) = STAKING.getExecutionValidatorSet(0);

        // Consensus and snapshot should have the same size (after epoch boundary)
        assertEq(consensusVals.length, snapshotVals.length, "Consensus and snapshot should have same size");

        // Execution set should be >= consensus set
        assertGe(executionVals.length, consensusVals.length, "Execution set should be >= consensus set");

        // Check that consensus validators exist in execution set
        if (consensusVals.length > 0) {
            bool found = false;
            for (uint i = 0; i < executionVals.length; i++) {
                if (executionVals[i] == consensusVals[0]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "First consensus validator should exist in execution set");
        }
    }
}
