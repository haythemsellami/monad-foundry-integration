// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/IStakingPrecompile.sol";
import "../src/IMonadVm.sol";

/// @title StakingCheatcodesTest
/// @notice Tests all 7 Monad cheatcodes:
///         Direct state: setEpoch, setProposer, setAccumulator
///         Syscall wrappers: blockReward, epochSnapshot, epochChange, epochBoundary
/// @dev These cheatcodes live at 0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA, separate from
///      the standard Foundry CHEATCODE_ADDRESS. They provide test control over consensus-layer
///      state that the staking precompile does not expose through its public interface.
contract StakingCheatcodesTest is Test {
    IStakingPrecompile constant STAKING = IStakingPrecompile(address(0x1000));
    IMonadVm constant monad = IMonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);

    uint256 constant ACTIVE_STAKE = 10_000_000 ether;

    function _buildPayload(address auth, uint256 stake, uint256 commission)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory secp = new bytes(33);
        bytes memory bls = new bytes(48);
        for (uint256 i = 0; i < 20; i++) {
            bls[i] = bytes20(auth)[i];
        }
        return abi.encodePacked(secp, bls, auth, stake, commission);
    }

    function _createValidator(address auth, uint256 stake, uint256 commission)
        internal
        returns (uint64)
    {
        bytes memory payload = _buildPayload(auth, stake, commission);
        vm.deal(address(this), stake);
        return STAKING.addValidator{value: stake}(payload, new bytes(64), new bytes(96));
    }

    function _getValidatorCore(uint64 valId)
        internal
        returns (address authAddress, uint64 flags, uint256 stake, uint256 accRewardPerToken, uint256 commission, uint256 unclaimedRewards)
    {
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getValidator.selector, valId));
        require(ok, "getValidator failed");
        (authAddress, flags, stake, accRewardPerToken, commission, unclaimedRewards) =
            abi.decode(ret, (address, uint64, uint256, uint256, uint256, uint256));
    }

    function _getValidatorViews(uint64 valId)
        internal
        returns (uint256 consensusStake, uint256 consensusCommission, uint256 snapshotStake, uint256 snapshotCommission)
    {
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getValidator.selector, valId));
        require(ok, "getValidator failed");
        assembly {
            consensusStake := mload(add(ret, 224))
            consensusCommission := mload(add(ret, 256))
            snapshotStake := mload(add(ret, 288))
            snapshotCommission := mload(add(ret, 320))
        }
    }

    // =========================================================================
    // setEpoch
    // =========================================================================

    function test_setEpoch_basic() public {
        monad.setEpoch(42, false);
        (uint64 epoch, bool inDelay) = STAKING.getEpoch();
        assertEq(epoch, 42);
        assertFalse(inDelay);
    }

    function test_setEpoch_withDelay() public {
        monad.setEpoch(100, true);
        (uint64 epoch, bool inDelay) = STAKING.getEpoch();
        assertEq(epoch, 100);
        assertTrue(inDelay);
    }

    function test_setEpoch_overwrite() public {
        monad.setEpoch(10, false);
        monad.setEpoch(999, true);
        (uint64 epoch, bool inDelay) = STAKING.getEpoch();
        assertEq(epoch, 999);
        assertTrue(inDelay);
    }

    function test_setEpoch_zeroEpoch() public {
        monad.setEpoch(0, false);
        (uint64 epoch,) = STAKING.getEpoch();
        assertEq(epoch, 0);
    }

    // =========================================================================
    // setProposer
    // =========================================================================

    function test_setProposer_basic() public {
        monad.setProposer(42);
        uint64 proposer = STAKING.getProposerValId();
        assertEq(proposer, 42);
    }

    function test_setProposer_overwrite() public {
        monad.setProposer(1);
        monad.setProposer(99);
        uint64 proposer = STAKING.getProposerValId();
        assertEq(proposer, 99);
    }

    // =========================================================================
    // setAccumulator
    // =========================================================================

    function test_setAccumulator_basic() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        uint256 accValue = 123456789e18;
        monad.setAccumulator(valId, accValue);

        (,,, uint256 acc,,) = _getValidatorCore(valId);
        assertEq(acc, accValue);
    }

    function test_setAccumulator_toZero() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        monad.setAccumulator(valId, 1e36);
        monad.setAccumulator(valId, 0);

        (,,, uint256 acc,,) = _getValidatorCore(valId);
        assertEq(acc, 0);
    }

    // =========================================================================
    // epochSnapshot
    // =========================================================================

    function test_epochSnapshot_buildsConsensusSet() public {
        monad.setEpoch(1, false);

        // Create two validators with different stakes
        uint64 valId1 = _createValidator(address(0xA1), 20_000_000 ether, 0.1e18);
        uint64 valId2 = _createValidator(address(0xA2), 10_000_000 ether, 0.05e18);

        monad.epochSnapshot();

        // Consensus set rebuilt from execution set, sorted by stake descending
        (bool isDone,, uint64[] memory consSet) = STAKING.getConsensusValidatorSet(0);
        assertTrue(isDone);
        assertEq(consSet.length, 2);
        assertEq(consSet[0], valId1, "highest stake first");
        assertEq(consSet[1], valId2, "lower stake second");
    }

    function test_epochSnapshot_populatesConsensusViews() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(0xA1), ACTIVE_STAKE, 0.1e18);

        monad.epochSnapshot();

        (uint256 consStake, uint256 consComm,,) = _getValidatorViews(valId);
        assertEq(consStake, ACTIVE_STAKE, "consensus view stake");
        assertEq(consComm, 0.1e18, "consensus view commission");
    }

    function test_epochSnapshot_setsInBoundary() public {
        monad.setEpoch(1, false);
        _createValidator(address(0xA1), ACTIVE_STAKE, 0);

        monad.epochSnapshot();

        (, bool inDelay) = STAKING.getEpoch();
        assertTrue(inDelay, "in_boundary should be true after snapshot");
    }

    function test_epochSnapshot_copiesConsensusToSnapshot() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(0xA1), ACTIVE_STAKE, 0.1e18);

        // First snapshot: builds consensus from execution, no previous consensus to copy
        monad.epochSnapshot();
        monad.epochChange(2);

        // Second snapshot: copies old consensus → snapshot, rebuilds consensus
        monad.epochSnapshot();

        (,, uint256 snapStake, uint256 snapComm) = _getValidatorViews(valId);
        assertEq(snapStake, ACTIVE_STAKE, "snapshot should have previous consensus stake");
        assertEq(snapComm, 0.1e18, "snapshot should have previous consensus commission");

        // Snapshot set should exist
        (bool isDone,, uint64[] memory snapSet) = STAKING.getSnapshotValidatorSet(0);
        assertTrue(isDone);
        assertEq(snapSet.length, 1);
        assertEq(snapSet[0], valId);
    }

    // =========================================================================
    // epochChange
    // =========================================================================

    function test_epochChange_incrementsEpoch() public {
        monad.setEpoch(5, false);
        _createValidator(address(0xB1), ACTIVE_STAKE, 0);
        monad.epochSnapshot();

        monad.epochChange(6);

        (uint64 epoch, bool inDelay) = STAKING.getEpoch();
        assertEq(epoch, 6);
        assertFalse(inDelay, "in_boundary should be cleared");
    }

    // =========================================================================
    // epochBoundary
    // =========================================================================

    function test_epochBoundary_composite() public {
        monad.setEpoch(10, false);
        uint64 valId = _createValidator(address(0xC1), 15_000_000 ether, 0.1e18);

        monad.epochBoundary(11);

        // Epoch incremented
        (uint64 epoch, bool inDelay) = STAKING.getEpoch();
        assertEq(epoch, 11);
        assertFalse(inDelay);

        // Consensus set rebuilt
        (bool isDone,, uint64[] memory consSet) = STAKING.getConsensusValidatorSet(0);
        assertTrue(isDone);
        assertEq(consSet.length, 1);
        assertEq(consSet[0], valId);

        // Consensus views populated
        (uint256 consStake, uint256 consComm,,) = _getValidatorViews(valId);
        assertEq(consStake, 15_000_000 ether);
        assertEq(consComm, 0.1e18);
    }

    // =========================================================================
    // blockReward
    // =========================================================================

    function test_blockReward_basic() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);
        monad.epochBoundary(2);

        monad.blockReward(auth, 10 ether);

        (,,, uint256 acc,, uint256 unclaimed) = _getValidatorCore(valId);
        // unclaimed = del_reward = 10 - commission(10*0.1=1) = 9 MON
        assertEq(unclaimed, 9 ether, "del_reward to unclaimed");
        assertGt(acc, 0, "accumulator should increase");
    }

    function test_blockReward_zeroCommission() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        monad.blockReward(auth, 10 ether);

        (,,, uint256 acc,,) = _getValidatorCore(valId);
        // Full 10 MON goes to accumulator (no commission deducted)
        uint256 pendingRewards = acc * ACTIVE_STAKE / 1e36;
        assertEq(pendingRewards, 10 ether, "full reward goes to delegators");
    }

    function test_blockReward_accumulates() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        _createValidator(auth, ACTIVE_STAKE, 0.1e18);
        monad.epochBoundary(2);

        monad.blockReward(auth, 10 ether);
        monad.blockReward(auth, 20 ether);

        (,,,,, uint256 unclaimed) = _getValidatorCore(1);
        // unclaimed = del_reward(10*0.9) + del_reward(20*0.9) = 9 + 18 = 27 MON
        assertEq(unclaimed, 27 ether, "rewards accumulate");
    }

    function test_blockReward_unknownAuthorNoOp() public {
        monad.setEpoch(1, false);
        _createValidator(address(this), ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // No validator for this author — should not revert
        monad.blockReward(address(0xDEAD), 10 ether);

        (,,, uint256 acc,, uint256 unclaimed) = _getValidatorCore(1);
        assertEq(unclaimed, 0);
        assertEq(acc, 0);
    }

    function test_blockReward_accumulatorMath() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);
        monad.epochBoundary(2);

        monad.blockReward(auth, 10 ether);

        (,,, uint256 acc,,) = _getValidatorCore(valId);
        // commission = 10 * 0.1 = 1 MON, del_reward = 9 MON
        // acc_delta = 9e18 * 1e36 / ACTIVE_STAKE
        // pending = ACTIVE_STAKE * acc_delta / 1e36 = 9e18
        uint256 pendingRewards = acc * ACTIVE_STAKE / 1e36;
        assertEq(pendingRewards, 9 ether, "9 MON to delegators");
    }

    function test_blockReward_multipleValidators() public {
        monad.setEpoch(1, false);
        address auth1 = address(0xD1);
        address auth2 = address(0xD2);
        uint64 valId1 = _createValidator(auth1, 20_000_000 ether, 0.1e18);
        uint64 valId2 = _createValidator(auth2, 10_000_000 ether, 0.05e18);
        monad.epochBoundary(2);

        monad.blockReward(auth1, 20 ether);
        monad.blockReward(auth2, 10 ether);

        (,,,,, uint256 unclaimed1) = _getValidatorCore(valId1);
        (,,,,, uint256 unclaimed2) = _getValidatorCore(valId2);
        // val1: 20 * 0.9 = 18 MON (10% commission)
        // val2: 10 * 0.95 = 9.5 MON (5% commission)
        assertEq(unclaimed1, 18 ether);
        assertEq(unclaimed2, 9.5 ether);
    }
}
