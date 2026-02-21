// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/IStakingPrecompile.sol";
import "../src/IMonadVm.sol";

/// @title StakingWriteFunctionsTest
/// @notice Tests all 8 state-modifying staking precompile functions:
///         addValidator, delegate, undelegate, withdraw, compound,
///         claimRewards, changeCommission, externalReward.
/// @dev Each test creates validators via addValidator and exercises one write function,
///      verifying state changes through the corresponding read functions.
///      Validators require >= 10,000,000 MON stake to clear STAKE_TOO_LOW flag
///      and enter the execution set.
contract StakingWriteFunctionsTest is Test {
    IStakingPrecompile constant STAKING = IStakingPrecompile(address(0x1000));
    IMonadVm constant monad = IMonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);

    /// @dev Minimum active validator stake: 10,000,000 MON.
    uint256 constant ACTIVE_STAKE = 10_000_000 ether;

    /// @dev Minimum auth address stake: 100,000 MON.
    uint256 constant MIN_AUTH_STAKE = 100_000 ether;

    /// @dev Dust threshold: 1e9 (1 Gwei).
    uint256 constant DUST = 1e9;

    /// @dev Maximum commission: 1e18 (100%).
    uint256 constant MAX_COMMISSION = 1e18;

    /// @dev Build addValidator payload.
    /// Layout: secp_pubkey(33) + bls_pubkey(48) + auth_address(20) + stake(32) + commission(32) = 165 bytes.
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

    /// @dev Create a validator. Deals balance to this contract and calls addValidator.
    function _createValidator(address auth, uint256 stake, uint256 commission)
        internal
        returns (uint64)
    {
        bytes memory payload = _buildPayload(auth, stake, commission);
        bytes memory dummySig64 = new bytes(64);
        bytes memory dummySig96 = new bytes(96);
        vm.deal(address(this), stake);
        return STAKING.addValidator{value: stake}(payload, dummySig64, dummySig96);
    }

    /// @dev Decode first 6 fields of getValidator (avoids stack-too-deep).
    function _getValidatorCore(uint64 valId)
        internal
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards
        )
    {
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getValidator.selector, valId));
        require(ok, "getValidator failed");
        (authAddress, flags, stake, accRewardPerToken, commission, unclaimedRewards) =
            abi.decode(ret, (address, uint64, uint256, uint256, uint256, uint256));
    }

    /// @dev Get consensus and snapshot view fields.
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

    /// @dev Get delegator info via raw call.
    function _getDelegator(uint64 valId, address delegator)
        internal
        returns (uint256 stake, uint256 accRewardPerToken, uint256 unclaimedRewards)
    {
        (bool ok, bytes memory ret) =
            address(STAKING).call(abi.encodeWithSelector(IStakingPrecompile.getDelegator.selector, valId, delegator));
        require(ok, "getDelegator failed");
        (stake, accRewardPerToken, unclaimedRewards,,,, ) =
            abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint64, uint64));
    }

    // =========================================================================
    // addValidator
    // =========================================================================

    function test_addValidator_basic() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0.1e18);

        assertEq(valId, 1, "first validator should have ID 1");

        (address auth, uint64 flags, uint256 stake,, uint256 commission,) = _getValidatorCore(valId);
        assertEq(auth, address(this), "auth address mismatch");
        assertEq(flags, 0, "flags should be OK (0) for sufficient stake");
        assertEq(stake, ACTIVE_STAKE, "stake mismatch");
        assertEq(commission, 0.1e18, "commission mismatch");
    }

    function test_addValidator_sequentialIds() public {
        monad.setEpoch(1, false);
        uint64 id1 = _createValidator(address(0xA1), ACTIVE_STAKE, 0);
        uint64 id2 = _createValidator(address(0xA2), ACTIVE_STAKE, 0);
        uint64 id3 = _createValidator(address(0xA3), ACTIVE_STAKE, 0);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_addValidator_selfDelegation() public {
        monad.setEpoch(1, false);
        address auth = address(0xB1);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);

        // Delegation is pending until activation epoch. Advance to activate.
        monad.epochBoundary(2);

        // Trigger pull_delegator_up_to_date via claimRewards (no-op with zero rewards)
        vm.prank(auth);
        STAKING.claimRewards(valId);

        // Now getDelegator reflects the activated stake
        (uint256 delStake,,) = _getDelegator(valId, auth);
        assertEq(delStake, ACTIVE_STAKE, "self-delegation stake should match");
    }

    function test_addValidator_executionSet() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        (bool isDone,, uint64[] memory execSet) = STAKING.getExecutionValidatorSet(0);
        assertTrue(isDone);
        assertEq(execSet.length, 1, "should be in execution set");
        assertEq(execSet[0], valId);
    }

    function test_addValidator_belowActiveStake() public {
        monad.setEpoch(1, false);
        // Below ACTIVE_VALIDATOR_STAKE but above MIN_AUTH_ADDRESS_STAKE
        uint64 valId = _createValidator(address(this), MIN_AUTH_STAKE, 0);

        (, uint64 flags,,,,) = _getValidatorCore(valId);
        assertEq(flags, 1, "flags should be STAKE_TOO_LOW (1)");
    }

    // =========================================================================
    // delegate
    // =========================================================================

    function test_delegate_basic() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Delegate from a separate address
        address delegator = address(0xD1);
        uint256 delegateAmount = 500 ether;
        vm.deal(delegator, delegateAmount);
        vm.prank(delegator);
        STAKING.delegate{value: delegateAmount}(valId);

        // Validator total stake is updated immediately
        (,, uint256 totalStake,,,) = _getValidatorCore(valId);
        assertEq(totalStake, ACTIVE_STAKE + delegateAmount, "total stake should increase");

        // Activate delegations and trigger pull to see delegator's active stake
        monad.epochBoundary(2);
        vm.prank(delegator);
        STAKING.claimRewards(valId);

        (uint256 delStake,,) = _getDelegator(valId, delegator);
        assertEq(delStake, delegateAmount, "delegator stake mismatch");
    }

    function test_delegate_multipleDelegators() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        for (uint256 i = 1; i <= 3; i++) {
            address delegator = address(uint160(0xD000 + i));
            uint256 amount = i * 100 ether;
            vm.deal(delegator, amount);
            vm.prank(delegator);
            STAKING.delegate{value: amount}(valId);
        }

        // Verify total stake: ACTIVE_STAKE + 100 + 200 + 300 = ACTIVE_STAKE + 600
        (,, uint256 totalStake,,,) = _getValidatorCore(valId);
        assertEq(totalStake, ACTIVE_STAKE + 600 ether, "total stake with 3 delegators");
    }

    function test_delegate_additionalFromSameDelegator() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 400 ether}(valId);

        vm.prank(delegator);
        STAKING.delegate{value: 600 ether}(valId);

        // Activate delegations and trigger pull
        monad.epochBoundary(2);
        vm.prank(delegator);
        STAKING.claimRewards(valId);

        (uint256 delStake,,) = _getDelegator(valId, delegator);
        assertEq(delStake, 1000 ether, "cumulative delegation");
    }

    // =========================================================================
    // undelegate
    // =========================================================================

    function test_undelegate_partial() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        // Undelegate half
        vm.prank(delegator);
        bool success = STAKING.undelegate(valId, 500 ether, 0);
        assertTrue(success, "undelegate should succeed");

        // undelegate calls pull_delegator_up_to_date, so getDelegator reflects active stake
        (uint256 delStake,,) = _getDelegator(valId, delegator);
        assertEq(delStake, 500 ether, "remaining delegator stake");
    }

    function test_undelegate_createsWithdrawalRequest() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        vm.prank(delegator);
        STAKING.undelegate(valId, 500 ether, 0);

        // Verify withdrawal request exists
        (uint256 wrAmount,, uint64 wrEpoch) = STAKING.getWithdrawalRequest(valId, delegator, 0);
        assertEq(wrAmount, 500 ether, "withdrawal amount mismatch");
        assertGt(wrEpoch, 0, "withdrawal epoch should be set");
    }

    function test_undelegate_full() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 1000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        // Undelegate all
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 0);

        (uint256 delStake,,) = _getDelegator(valId, delegator);
        assertEq(delStake, 0, "delegator stake should be zero");
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_afterDelay() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        uint256 delegateAmount = 1000 ether;
        vm.deal(delegator, delegateAmount);
        vm.prank(delegator);
        STAKING.delegate{value: delegateAmount}(valId);

        // Activate delegations (epoch 1 → 2)
        monad.epochBoundary(2);

        // Undelegate at epoch 2 → WR activationEpoch = 3
        vm.prank(delegator);
        STAKING.undelegate(valId, delegateAmount, 0);

        // Advance past withdrawal delay: need epoch > wr_epoch + WITHDRAWAL_DELAY
        // wr_epoch=3, WITHDRAWAL_DELAY=1 → need epoch > 4, so epoch 5
        monad.epochBoundary(3);
        monad.epochBoundary(4);
        monad.epochBoundary(5);

        // Withdraw
        uint256 balanceBefore = delegator.balance;
        vm.prank(delegator);
        bool success = STAKING.withdraw(valId, 0);
        assertTrue(success, "withdraw should succeed");

        // Balance should increase by at least the undelegated amount
        uint256 balanceAfter = delegator.balance;
        assertGe(balanceAfter - balanceBefore, delegateAmount, "should receive at least undelegated amount");

        // Withdrawal request should be cleared
        (uint256 wrAmount,,) = STAKING.getWithdrawalRequest(valId, delegator, 0);
        assertEq(wrAmount, 0, "withdrawal request should be cleared");
    }

    // =========================================================================
    // claimRewards
    // =========================================================================

    function test_claimRewards_afterBlockReward() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);

        // Run epoch lifecycle to populate consensus views
        monad.epochBoundary(2);

        // Distribute block reward
        monad.blockReward(auth, 10 ether);

        // Claim rewards as the self-delegator (auth address)
        uint256 balanceBefore = auth.balance;
        STAKING.claimRewards(valId);
        uint256 balanceAfter = auth.balance;

        uint256 claimed = balanceAfter - balanceBefore;
        assertGt(claimed, 0, "should have claimed some rewards");

        // Commission = 10 * 0.1 = 1 MON → credited to auth delegator rewards
        // Delegator reward = 9 MON → distributed via accumulator
        // Auth (sole delegator, 100% stake) gets: 1 (commission) + 9 (share) = 10 MON
        assertEq(claimed, 10 ether, "auth gets commission + full share");
    }

    function test_claimRewards_zeroRewards() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Claim with no rewards should succeed (no-op)
        bool success = STAKING.claimRewards(valId);
        assertTrue(success, "claimRewards with zero should succeed");
    }

    // =========================================================================
    // compound
    // =========================================================================

    function test_compound_rewardsIntoStake() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);

        monad.epochBoundary(2);
        monad.blockReward(auth, 10 ether);

        // Compound rewards back into stake
        bool success = STAKING.compound(valId);
        assertTrue(success, "compound should succeed");

        // Compound re-delegates rewards as pending delta.
        // Advance epoch to activate the compounded amount.
        monad.epochBoundary(3);

        // Trigger pull to promote compound delta into active stake
        STAKING.claimRewards(valId);

        // Verify active stake increased by the full reward (commission + share = 10 MON)
        (uint256 stakeAfter,,) = _getDelegator(valId, auth);
        assertEq(stakeAfter, ACTIVE_STAKE + 10 ether, "stake increased by compounded reward");
    }

    // =========================================================================
    // changeCommission
    // =========================================================================

    function test_changeCommission_basic() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);

        // Change commission from 10% to 5%
        bool success = STAKING.changeCommission(valId, 0.05e18);
        assertTrue(success, "changeCommission should succeed");

        (,,,, uint256 newComm,) = _getValidatorCore(valId);
        assertEq(newComm, 0.05e18, "commission should be 5%");
    }

    function test_changeCommission_toZero() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0.1e18);

        STAKING.changeCommission(valId, 0);
        (,,,, uint256 newComm,) = _getValidatorCore(valId);
        assertEq(newComm, 0, "commission should be 0");
    }

    function test_changeCommission_toMax() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        STAKING.changeCommission(valId, MAX_COMMISSION);
        (,,,, uint256 newComm,) = _getValidatorCore(valId);
        assertEq(newComm, MAX_COMMISSION, "commission should be 100%");
    }

    // =========================================================================
    // externalReward
    // =========================================================================

    function test_externalReward_basic() public {
        monad.setEpoch(1, false);
        address auth = address(0xE1);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);

        // Need consensus views for externalReward to work
        monad.epochBoundary(2);

        // Send external reward
        uint256 rewardAmount = 5 ether;
        vm.deal(address(this), rewardAmount);
        bool success = STAKING.externalReward{value: rewardAmount}(valId);
        assertTrue(success, "externalReward should succeed");

        // Verify accumulator increased
        (,,, uint256 acc,,) = _getValidatorCore(valId);
        assertGt(acc, 0, "accumulator should increase from external reward");
    }

    function test_externalReward_delegatorCanClaim() public {
        monad.setEpoch(1, false);
        address auth = address(0xE1);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // External reward (zero commission validator)
        uint256 rewardAmount = 5 ether;
        vm.deal(address(this), rewardAmount);
        STAKING.externalReward{value: rewardAmount}(valId);

        // Self-delegator (auth) claims
        uint256 balBefore = auth.balance;
        vm.prank(auth);
        STAKING.claimRewards(valId);
        uint256 claimed = auth.balance - balBefore;

        // With 0% commission, full reward goes to delegators via accumulator
        assertEq(claimed, rewardAmount, "delegator should claim full external reward");
    }

    // =========================================================================
    // T6: Compound Zero Rewards (No-Op)
    // =========================================================================

    /// @dev compound with no rewards is a no-op.
    function test_compound_zeroRewards() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        // Compound with zero rewards should succeed (no-op)
        bool success = STAKING.compound(valId);
        assertTrue(success, "compound with zero rewards should succeed");

        // Stake should remain unchanged
        (uint256 stake,,) = _getDelegator(valId, address(this));
        // Delegation is still pending (not activated yet), so stake is 0
        // but validator total stake should still be ACTIVE_STAKE
        (,, uint256 totalStake,,,) = _getValidatorCore(valId);
        assertEq(totalStake, ACTIVE_STAKE, "stake unchanged after zero-reward compound");
    }

    // =========================================================================
    // T10: Withdraw Includes Rewards
    // =========================================================================

    /// @dev Rewards are collected during undelegate via pull_up. Withdraw returns
    ///      the undelegated principal. Total (claimed + withdrawn) exceeds original.
    function test_withdraw_includesRewards() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0); // 0% commission

        // Activate delegations
        monad.epochBoundary(2);

        // Block reward before undelegate — pull_up during undelegate will collect these
        monad.blockReward(auth, 100 ether);

        // Undelegate all: pull_up collects rewards, then creates WR for principal
        uint256 balBefore = auth.balance;
        STAKING.undelegate(valId, ACTIVE_STAKE, 0);

        // Rewards collected during pull_up (100 MON with 0% commission, sole delegator)
        uint256 rewardsClaimed = auth.balance - balBefore;
        // No balance transfer from undelegate itself, but del.rewards gets populated
        // and we need to claimRewards to actually transfer
        // Actually pull_up just sets del.rewards; claimRewards transfers. Let's check getDelegator.
        (,, uint256 pendingRewards) = _getDelegator(valId, auth);
        assertEq(pendingRewards, 100 ether, "pull_up collected 100 MON rewards");

        // Claim the rewards
        balBefore = auth.balance;
        STAKING.claimRewards(valId);
        uint256 claimed = auth.balance - balBefore;
        assertEq(claimed, 100 ether, "claimed rewards from pull_up");

        // Advance past withdrawal delay
        monad.epochBoundary(3);
        monad.epochBoundary(4);
        monad.epochBoundary(5);

        // Withdraw — returns undelegated principal
        balBefore = auth.balance;
        STAKING.withdraw(valId, 0);
        uint256 withdrawn = auth.balance - balBefore;
        assertEq(withdrawn, ACTIVE_STAKE, "withdraw returns principal");

        // Total: claimed (100 ether) + withdrawn (10M) > original stake (10M)
        assertGt(claimed + withdrawn, ACTIVE_STAKE, "total exceeds original stake");
    }

    // =========================================================================
    // T12: Delegate Event Emission
    // =========================================================================

    /// @dev Verify Delegate event is emitted with correct topics/data.
    function test_delegate_eventEmission() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        uint256 amount = 500 ether;
        vm.deal(delegator, amount);

        // Expect a log from the staking address
        // The Delegated event has topics: signature, valId, delegator
        vm.prank(delegator);
        vm.recordLogs();
        STAKING.delegate{value: amount}(valId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Should have at least 1 event (Delegated)
        assertGt(logs.length, 0, "should emit at least one event");

        // Find the log from staking address
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(STAKING)) {
                found = true;
                // topic[1] = valId, topic[2] = delegator address
                assertEq(uint256(logs[i].topics[1]), uint256(valId), "event valId mismatch");
                assertEq(
                    address(uint160(uint256(logs[i].topics[2]))),
                    delegator,
                    "event delegator mismatch"
                );
                break;
            }
        }
        assertTrue(found, "Delegated event should be emitted from staking address");
    }
}
