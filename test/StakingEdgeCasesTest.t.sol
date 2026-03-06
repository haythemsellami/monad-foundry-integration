// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/IStakingPrecompile.sol";
import "../src/IMonadVm.sol";

/// @title StakingEdgeCasesTest
/// @notice Edge cases and error conditions for the staking precompile:
///         payability enforcement, invalid inputs, authorization,
///         duplicate validators, insufficient balance, dust threshold,
///         and withdrawal timing constraints.
contract StakingEdgeCasesTest is Test {
    IStakingPrecompile constant STAKING = IStakingPrecompile(address(0x1000));
    IMonadVm constant monad = IMonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);

    uint256 constant ACTIVE_STAKE = 10_000_000 ether;
    uint256 constant MIN_AUTH_STAKE = 100_000 ether;

    function _buildPayload(address auth, uint256 stake, uint256 commission) internal pure returns (bytes memory) {
        bytes memory secp = new bytes(33);
        bytes memory bls = new bytes(48);
        for (uint256 i = 0; i < 20; i++) {
            bls[i] = bytes20(auth)[i];
        }
        return abi.encodePacked(secp, bls, auth, stake, commission);
    }

    function _createValidator(address auth, uint256 stake, uint256 commission) internal returns (uint64) {
        bytes memory payload = _buildPayload(auth, stake, commission);
        vm.deal(address(this), stake);
        return STAKING.addValidator{value: stake}(payload, new bytes(64), new bytes(96));
    }

    function _getValidatorCore(uint64 valId) internal returns (address, uint64, uint256, uint256, uint256, uint256) {
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getValidator.selector, valId));
        require(ok, "getValidator failed");
        return abi.decode(ret, (address, uint64, uint256, uint256, uint256, uint256));
    }

    // =========================================================================
    // Payability Enforcement
    // =========================================================================

    /// @dev addValidator, delegate, externalReward are payable; others are not.
    ///      Sending value to non-payable functions should revert.

    function test_payability_undelegateRejectsValue() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.undelegate.selector, valId, uint256(0), uint8(0))
        );
        assertFalse(success, "undelegate with value should revert");
    }

    function test_payability_withdrawRejectsValue() public {
        monad.setEpoch(1, false);
        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.withdraw.selector, uint64(1), uint8(0))
        );
        assertFalse(success, "withdraw with value should revert");
    }

    function test_payability_compoundRejectsValue() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        vm.deal(address(this), 1 ether);
        (bool success,) =
            address(STAKING).call{value: 1 ether}(abi.encodeWithSelector(IStakingPrecompile.compound.selector, valId));
        assertFalse(success, "compound with value should revert");
    }

    function test_payability_claimRewardsRejectsValue() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.claimRewards.selector, valId)
        );
        assertFalse(success, "claimRewards with value should revert");
    }

    function test_payability_changeCommissionRejectsValue() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.changeCommission.selector, valId, uint256(0))
        );
        assertFalse(success, "changeCommission with value should revert");
    }

    function test_payability_readFunctionsRejectValue() public {
        vm.deal(address(this), 1 ether);
        (bool success,) =
            address(STAKING).call{value: 1 ether}(abi.encodeWithSelector(IStakingPrecompile.getEpoch.selector));
        assertFalse(success, "getEpoch with value should revert");
    }

    // =========================================================================
    // Invalid Inputs
    // =========================================================================

    function test_invalidInput_shortCalldata() public {
        // Calldata shorter than 4 bytes (no selector)
        (bool success,) = address(STAKING).call(hex"0102");
        assertFalse(success, "short calldata should revert");
    }

    function test_invalidInput_unknownSelector() public {
        (bool success,) = address(STAKING).call(hex"deadbeef");
        assertFalse(success, "unknown selector should revert");
    }

    function test_invalidInput_emptyCalldata() public {
        // Empty calldata (no selector at all)
        (bool success,) = address(STAKING).call(hex"");
        assertFalse(success, "empty calldata should revert");
    }

    function test_readFunction_nonExistentValidator() public {
        // Query a validator that doesn't exist — should succeed with zero values
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getValidator.selector, uint64(999)));
        assertTrue(ok, "getValidator for non-existent should not revert");
        (address auth,,,,,) = abi.decode(ret, (address, uint64, uint256, uint256, uint256, uint256));
        assertEq(auth, address(0), "non-existent validator has zero auth");
    }

    // =========================================================================
    // Authorization
    // =========================================================================

    function test_authorization_changeCommissionRequiresAuth() public {
        monad.setEpoch(1, false);
        address auth = address(0xAA);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);

        // Non-auth address tries to change commission
        address notAuth = address(0xBB);
        vm.prank(notAuth);
        (bool success,) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.changeCommission.selector, valId, uint256(0.5e18)));
        assertFalse(success, "non-auth should not change commission");
    }

    function test_authorization_changeCommissionFromAuth() public {
        monad.setEpoch(1, false);
        address auth = address(0xAA);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);

        // Auth address succeeds
        vm.prank(auth);
        bool success = STAKING.changeCommission(valId, 0.5e18);
        assertTrue(success, "auth should change commission");
    }

    // =========================================================================
    // Duplicate Validators
    // =========================================================================

    function test_duplicateValidator_sameAuthAddress() public {
        monad.setEpoch(1, false);
        address auth = address(0xCC);
        _createValidator(auth, ACTIVE_STAKE, 0);

        // Try to create another validator with the same auth address
        bytes memory payload = _buildPayload(auth, ACTIVE_STAKE, 0);
        vm.deal(address(this), ACTIVE_STAKE);
        (bool success,) = address(STAKING).call{value: ACTIVE_STAKE}(
            abi.encodeWithSelector(IStakingPrecompile.addValidator.selector, payload, new bytes(64), new bytes(96))
        );
        assertFalse(success, "duplicate auth address should revert");
    }

    // =========================================================================
    // Insufficient Stake / Balance
    // =========================================================================

    function test_addValidator_belowMinAuthStake() public {
        monad.setEpoch(1, false);
        // Below MIN_AUTH_ADDRESS_STAKE (100,000 MON)
        uint256 tooLow = 99_999 ether;
        bytes memory payload = _buildPayload(address(0xDD), tooLow, 0);
        vm.deal(address(this), tooLow);
        (bool success,) = address(STAKING).call{value: tooLow}(
            abi.encodeWithSelector(IStakingPrecompile.addValidator.selector, payload, new bytes(64), new bytes(96))
        );
        assertFalse(success, "below min auth stake should revert");
    }

    function test_addValidator_valueMismatch() public {
        monad.setEpoch(1, false);
        // Payload says 200,000 MON but only sending 100,000
        bytes memory payload = _buildPayload(address(0xDD), 200_000 ether, 0);
        vm.deal(address(this), MIN_AUTH_STAKE);
        (bool success,) = address(STAKING).call{value: MIN_AUTH_STAKE}(
            abi.encodeWithSelector(IStakingPrecompile.addValidator.selector, payload, new bytes(64), new bytes(96))
        );
        assertFalse(success, "value != signed_stake should revert");
    }

    function test_undelegate_moreThanStaked() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId);

        // Try to undelegate more than staked
        vm.prank(delegator);
        (bool success,) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.undelegate.selector, valId, uint256(2000 ether), uint8(0)));
        assertFalse(success, "cannot undelegate more than staked");
    }

    // =========================================================================
    // Commission Bounds
    // =========================================================================

    function test_commission_aboveMax() public {
        monad.setEpoch(1, false);
        // Commission > 1e18 (>100%) should fail
        uint256 tooHigh = 1e18 + 1;
        bytes memory payload = _buildPayload(address(0xEE), ACTIVE_STAKE, tooHigh);
        vm.deal(address(this), ACTIVE_STAKE);
        (bool success,) = address(STAKING).call{value: ACTIVE_STAKE}(
            abi.encodeWithSelector(IStakingPrecompile.addValidator.selector, payload, new bytes(64), new bytes(96))
        );
        assertFalse(success, "commission > 100% should revert");
    }

    function test_changeCommission_aboveMax() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        (bool success,) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.changeCommission.selector, valId, uint256(1e18 + 1)));
        assertFalse(success, "changeCommission > 100% should revert");
    }

    // =========================================================================
    // Dust Threshold
    // =========================================================================

    function test_delegate_belowDust() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Dust threshold is 1e9
        address delegator = address(0xD1);
        vm.deal(delegator, 1e9 - 1);
        vm.prank(delegator);
        (bool success,) =
            address(STAKING).call{value: 1e9 - 1}(abi.encodeWithSelector(IStakingPrecompile.delegate.selector, valId));
        assertFalse(success, "delegation below dust threshold should revert");
    }

    function test_delegate_exactDust() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Exactly at dust threshold should succeed
        address delegator = address(0xD1);
        vm.deal(delegator, 1e9);
        vm.prank(delegator);
        bool success = STAKING.delegate{value: 1e9}(valId);
        assertTrue(success, "delegation at dust threshold should succeed");
    }

    // =========================================================================
    // Withdrawal Timing
    // =========================================================================

    function test_withdraw_beforeDelayExpires() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        // Undelegate at epoch 2 → WR activationEpoch = 3
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 0);

        // Try to withdraw immediately (epoch 2, need epoch > 4)
        vm.prank(delegator);
        (bool success,) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.withdraw.selector, valId, uint8(0)));
        assertFalse(success, "withdraw before delay should revert");
    }

    function test_withdraw_nonExistentId() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Try to withdraw a non-existent withdrawal ID
        (bool success,) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.withdraw.selector, valId, uint8(42)));
        assertFalse(success, "withdraw non-existent ID should revert");
    }

    // =========================================================================
    // Duplicate Withdrawal ID
    // =========================================================================

    function test_undelegate_duplicateWithdrawId() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 2000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 2000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        // First undelegate with withdrawId=0
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 0);

        // Second undelegate with same withdrawId=0 should fail
        vm.prank(delegator);
        (bool success,) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.undelegate.selector, valId, uint256(500 ether), uint8(0)));
        assertFalse(success, "duplicate withdrawal ID should revert");
    }

    // =========================================================================
    // Unknown Validator for Write Operations
    // =========================================================================

    function test_delegate_unknownValidator() public {
        monad.setEpoch(1, false);
        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.delegate.selector, uint64(999))
        );
        assertFalse(success, "delegate to non-existent validator should revert");
    }

    function test_undelegate_unknownValidator() public {
        monad.setEpoch(1, false);
        (bool success,) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.undelegate.selector, uint64(999), uint256(100), uint8(0)));
        assertFalse(success, "undelegate from non-existent validator should revert");
    }

    function test_changeCommission_unknownValidator() public {
        monad.setEpoch(1, false);
        (bool success,) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.changeCommission.selector, uint64(999), uint256(0.1e18)));
        assertFalse(success, "changeCommission on non-existent validator should revert");
    }

    // =========================================================================
    // External Reward Bounds
    // =========================================================================

    function test_externalReward_belowMinimum() public {
        monad.setEpoch(1, false);
        address auth = address(0xF1);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // Below MIN_EXTERNAL_REWARD (1e9)
        vm.deal(address(this), 1e9 - 1);
        (bool success,) = address(STAKING).call{value: 1e9 - 1}(
            abi.encodeWithSelector(IStakingPrecompile.externalReward.selector, valId)
        );
        assertFalse(success, "external reward below minimum should revert");
    }

    function test_externalReward_notInValidatorSet() public {
        monad.setEpoch(1, false);
        // Create validator below active stake (not in execution set, no consensus views)
        uint64 valId = _createValidator(address(0xF2), MIN_AUTH_STAKE, 0);

        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.externalReward.selector, valId)
        );
        assertFalse(success, "external reward to non-active validator should revert");
    }

    // =========================================================================
    // Undelegate Zero Amount (No-Op)
    // =========================================================================

    function test_undelegate_zeroAmount() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Undelegate zero should succeed as a no-op
        bool success = STAKING.undelegate(valId, 0, 0);
        assertTrue(success, "zero undelegate should succeed as no-op");
    }

    // =========================================================================
    // Payload Length Validation
    // =========================================================================

    function test_addValidator_shortPayload() public {
        monad.setEpoch(1, false);
        // Payload < 165 bytes
        bytes memory shortPayload = new bytes(100);
        vm.deal(address(this), ACTIVE_STAKE);
        (bool success,) = address(STAKING).call{value: ACTIVE_STAKE}(
            abi.encodeWithSelector(IStakingPrecompile.addValidator.selector, shortPayload, new bytes(64), new bytes(96))
        );
        assertFalse(success, "short payload should revert");
    }

    // =========================================================================
    // T3: Revert Messages Match Expected Format
    // =========================================================================

    /// @dev "unknown validator" — delegate to non-existent validator.
    function test_revertMessage_delegateUnknownValidator() public {
        monad.setEpoch(1, false);
        _createValidator(address(this), ACTIVE_STAKE, 0);
        vm.deal(address(this), 1 ether);
        (bool success, bytes memory ret) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.delegate.selector, uint64(999))
        );
        assertFalse(success);
        assertEq(string(ret), "unknown validator", "delegate unknown validator msg");
    }

    /// @dev "delegation is too small" — below dust threshold.
    function test_revertMessage_delegateDust() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD3);
        vm.deal(delegator, 100);
        vm.prank(delegator);
        (bool success, bytes memory ret) =
            address(STAKING).call{value: 100}(abi.encodeWithSelector(IStakingPrecompile.delegate.selector, valId));
        assertFalse(success);
        assertEq(string(ret), "delegation is too small", "delegate dust msg");
    }

    /// @dev "commission too high" on changeCommission.
    function test_revertMessage_commissionTooHigh() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        (bool success, bytes memory ret) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.changeCommission.selector, valId, uint256(1e18 + 1)));
        assertFalse(success);
        assertEq(string(ret), "commission too high", "commission msg");
    }

    /// @dev "withdrawal id exists" — duplicate undelegate withdrawId.
    function test_revertMessage_withdrawalIdExists() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        monad.epochBoundary(2);
        address del2 = address(0xD4);
        vm.deal(del2, 2000 ether);
        vm.prank(del2);
        STAKING.delegate{value: 2000 ether}(valId);
        monad.epochBoundary(3);
        vm.prank(del2);
        STAKING.undelegate(valId, 1000 ether, 0);
        vm.prank(del2);
        (bool success, bytes memory ret) = address(STAKING)
            .call(abi.encodeWithSelector(IStakingPrecompile.undelegate.selector, valId, uint256(500 ether), uint8(0)));
        assertFalse(success);
        assertEq(string(ret), "withdrawal id exists", "duplicate wr msg");
    }

    // =========================================================================
    // T4: External Reward Unknown Validator
    // =========================================================================

    /// @dev externalReward to nonexistent validator reverts.
    function test_externalReward_unknownValidator() public {
        monad.setEpoch(1, false);
        vm.deal(address(this), 1 ether);
        (bool success,) = address(STAKING).call{value: 1 ether}(
            abi.encodeWithSelector(IStakingPrecompile.externalReward.selector, uint64(999))
        );
        assertFalse(success, "externalReward to non-existent validator should revert");
    }

    // =========================================================================
    // T5: External Reward Above Maximum
    // =========================================================================

    /// @dev externalReward > 1e25 reverts.
    function test_externalReward_aboveMaximum() public {
        monad.setEpoch(1, false);
        address auth = address(0xF5);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // MAX_EXTERNAL_REWARD = 1e25
        uint256 tooMuch = 1e25 + 1;
        vm.deal(address(this), tooMuch);
        (bool success,) = address(STAKING).call{value: tooMuch}(
            abi.encodeWithSelector(IStakingPrecompile.externalReward.selector, valId)
        );
        assertFalse(success, "external reward above maximum should revert");
    }

    // =========================================================================
    // T7: Undelegate Dust Collection
    // =========================================================================

    /// @dev Undelegate leaving < 1e9 remainder collects entire stake.
    function test_undelegate_dustCollection() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD7);
        uint256 delegateAmount = 1000 ether;
        vm.deal(delegator, delegateAmount);
        vm.prank(delegator);
        STAKING.delegate{value: delegateAmount}(valId);

        // Activate delegations
        monad.epochBoundary(2);

        // Undelegate all but 1 wei (below dust threshold of 1e9)
        uint256 undelegateAmount = delegateAmount - 1;
        vm.prank(delegator);
        STAKING.undelegate(valId, undelegateAmount, 0);

        // Dust collection should collect entire remaining stake
        (uint256 delStake,,) = _getDelegator(valId, delegator);
        assertEq(delStake, 0, "dust should be collected, zero remaining");

        // Withdrawal request should be for the full amount (dust collected)
        (uint256 wrAmount,,) = STAKING.getWithdrawalRequest(valId, delegator, 0);
        assertEq(wrAmount, delegateAmount, "WR should include dust-collected amount");
    }

    function _getDelegator(uint64 valId, address delegator)
        internal
        returns (uint256 stake, uint256 accRewardPerToken, uint256 unclaimedRewards)
    {
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getDelegator.selector, valId, delegator));
        require(ok, "getDelegator failed");
        (stake, accRewardPerToken, unclaimedRewards,,,,) =
            abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint64, uint64));
    }

    // =========================================================================
    // T11: Linked List Cleanup on Full Undelegate
    // =========================================================================

    /// @dev getDelegations returns empty after full undelegate.
    function test_linkedList_cleanupOnFullUndelegate() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD11);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId);

        // Verify in list
        (bool isDone,, uint64[] memory valIds) = STAKING.getDelegations(delegator, 0);
        assertTrue(isDone);
        assertEq(valIds.length, 1, "should be in delegation list");

        // Activate then fully undelegate
        monad.epochBoundary(2);
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 0);

        // Should be removed from list
        (isDone,, valIds) = STAKING.getDelegations(delegator, 0);
        assertTrue(isDone);
        assertEq(valIds.length, 0, "should be removed from delegation list after full undelegate");
    }
}
