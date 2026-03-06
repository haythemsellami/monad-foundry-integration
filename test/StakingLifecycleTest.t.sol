// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/IStakingPrecompile.sol";
import "../src/IMonadVm.sol";

/// @title StakingLifecycleTest
/// @notice End-to-end lifecycle scenarios combining write functions and syscall cheatcodes.
/// @dev Tests exercise multi-step flows that mirror production staking behavior:
///      validator creation → delegation → epoch lifecycle → reward distribution →
///      claim/compound → undelegation → withdrawal.
contract StakingLifecycleTest is Test {
    IStakingPrecompile constant STAKING = IStakingPrecompile(address(0x1000));
    IMonadVm constant monad = IMonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);

    uint256 constant ACTIVE_STAKE = 10_000_000 ether;

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
    // Full Validator Lifecycle
    // =========================================================================

    /// @dev Complete lifecycle: create → epoch → reward → claim → undelegate → withdraw.
    function test_fullValidatorLifecycle() public {
        // --- Phase 1: Setup ---
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18);

        // Verify creation
        (address gotAuth, uint64 flags, uint256 stake,,,) = _getValidatorCore(valId);
        assertEq(gotAuth, auth);
        assertEq(flags, 0, "flags should be OK");
        assertEq(stake, ACTIVE_STAKE);

        // --- Phase 2: Epoch lifecycle to populate consensus views ---
        monad.epochBoundary(2);

        // --- Phase 3: Block rewards ---
        monad.blockReward(auth, 100 ether);
        monad.blockReward(auth, 50 ether);

        // --- Phase 4: Claim rewards ---
        uint256 balBefore = auth.balance;
        STAKING.claimRewards(valId);
        uint256 claimed = auth.balance - balBefore;

        // Commission = 150 * 0.1 = 15 MON → credited to auth delegator rewards
        // Delegator reward = 135 MON → auth (sole delegator) gets full share
        // Total: 15 + 135 = 150 MON
        assertEq(claimed, 150 ether, "auth gets commission + full share");

        // --- Phase 5: Undelegate all ---
        // undelegate calls pull_delegator_up_to_date which activates the delegation
        STAKING.undelegate(valId, ACTIVE_STAKE, 0);
        (uint256 delStake,,) = _getDelegator(valId, auth);
        assertEq(delStake, 0, "fully undelegated");

        // --- Phase 6: Advance epochs and withdraw ---
        // Undelegate at epoch 2 → WR activationEpoch=3, WITHDRAWAL_DELAY=1
        // Need epoch > wr_epoch + WITHDRAWAL_DELAY → epoch > 4
        monad.epochBoundary(3);
        monad.epochBoundary(4);
        monad.epochBoundary(5);

        balBefore = auth.balance;
        STAKING.withdraw(valId, 0);
        uint256 withdrawn = auth.balance - balBefore;

        // Should get back at least the original stake
        assertGe(withdrawn, ACTIVE_STAKE, "should withdraw at least original stake");
    }

    // =========================================================================
    // Multi-Delegator Scenario
    // =========================================================================

    /// @dev Multiple delegators stake to the same validator, share rewards proportionally.
    function test_multiDelegator_proportionalRewards() public {
        monad.setEpoch(1, false);
        address auth = address(0xAA);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0); // 0% commission

        // Alice delegates 3x auth's stake
        address alice = address(0xA11CE);
        vm.deal(alice, 30_000_000 ether);
        vm.prank(alice);
        STAKING.delegate{value: 30_000_000 ether}(valId);

        // Total stake: 10M (auth) + 30M (alice) = 40M
        // auth has 25%, alice has 75%

        monad.epochBoundary(2);
        monad.blockReward(auth, 100 ether);

        // Auth claims (25% of 100 = 25 MON with 0% commission)
        uint256 authBal = auth.balance;
        vm.prank(auth);
        STAKING.claimRewards(valId);
        uint256 authClaimed = auth.balance - authBal;
        assertEq(authClaimed, 25 ether, "auth gets 25% of reward");

        // Alice claims (75% of 100 = 75 MON)
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        STAKING.claimRewards(valId);
        uint256 aliceClaimed = alice.balance - aliceBal;
        assertEq(aliceClaimed, 75 ether, "alice gets 75% of reward");
    }

    // =========================================================================
    // Multi-Validator Scenario
    // =========================================================================

    /// @dev Multiple validators with different commissions receive rewards independently.
    function test_multiValidator_independentRewards() public {
        monad.setEpoch(1, false);

        address auth1 = address(0xB1);
        address auth2 = address(0xB2);
        uint64 valId1 = _createValidator(auth1, ACTIVE_STAKE, 0.1e18); // 10% commission
        uint64 valId2 = _createValidator(auth2, ACTIVE_STAKE, 0.2e18); // 20% commission

        monad.epochBoundary(2);

        // Same reward to both validators
        monad.blockReward(auth1, 100 ether);
        monad.blockReward(auth2, 100 ether);

        // Val1: commission = 10, share = 90 → auth (sole delegator) gets 100
        uint256 bal1 = auth1.balance;
        vm.prank(auth1);
        STAKING.claimRewards(valId1);
        assertEq(auth1.balance - bal1, 100 ether, "val1 auth gets commission + share");

        // Val2: commission = 20, share = 80 → auth (sole delegator) gets 100
        uint256 bal2 = auth2.balance;
        vm.prank(auth2);
        STAKING.claimRewards(valId2);
        assertEq(auth2.balance - bal2, 100 ether, "val2 auth gets commission + share");
    }

    // =========================================================================
    // Epoch Progression with Accumulated Rewards
    // =========================================================================

    /// @dev Rewards accumulate across multiple epochs.
    function test_crossEpochRewardAccumulation() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // Epoch 2: 10 MON reward
        monad.blockReward(auth, 10 ether);

        // Epoch 3: 20 MON reward
        monad.epochBoundary(3);
        monad.blockReward(auth, 20 ether);

        // Epoch 4: 30 MON reward
        monad.epochBoundary(4);
        monad.blockReward(auth, 30 ether);

        // Claim all accumulated rewards (0% commission: full 60 MON)
        uint256 balBefore = auth.balance;
        STAKING.claimRewards(valId);
        uint256 claimed = auth.balance - balBefore;
        assertEq(claimed, 60 ether, "accumulated rewards across 3 epochs");
    }

    // =========================================================================
    // Compound Then Continue Earning
    // =========================================================================

    /// @dev Compound rewards increase stake, which earns proportionally more in future epochs.
    function test_compoundIncreasesEffectiveStake() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // Epoch 2: earn and compound
        monad.blockReward(auth, 1_000_000 ether); // large reward
        STAKING.compound(valId);

        // Compound re-delegates rewards as pending delta. Advance to activate.
        monad.epochBoundary(3);

        // Trigger pull to promote compound delta into active stake
        STAKING.claimRewards(valId);

        // Verify stake increased
        (uint256 stakeAfterCompound,,) = _getDelegator(valId, auth);
        assertEq(stakeAfterCompound, ACTIVE_STAKE + 1_000_000 ether, "stake increased by reward");

        // New epoch with updated consensus views reflecting higher stake
        monad.epochBoundary(4);

        // Epoch 4: same reward amount, still solo delegator gets full reward
        monad.blockReward(auth, 100 ether);

        uint256 balBefore = auth.balance;
        STAKING.claimRewards(valId);
        uint256 claimed = auth.balance - balBefore;
        // Allow 1 wei rounding from accumulator integer division
        assertApproxEqAbs(claimed, 100 ether, 1, "solo delegator gets full reward");
    }

    // =========================================================================
    // Delegate Mid-Lifecycle
    // =========================================================================

    /// @dev New delegator joins after rewards have already accumulated.
    function test_lateDelegatorDoesNotClaimPastRewards() public {
        monad.setEpoch(1, false);
        address auth = address(0xDD);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // Auth earns rewards
        monad.blockReward(auth, 100 ether);

        // Alice joins AFTER rewards were distributed
        address alice = address(0xA11CE);
        vm.deal(alice, ACTIVE_STAKE);
        vm.prank(alice);
        STAKING.delegate{value: ACTIVE_STAKE}(valId);

        // Alice should have no rewards to claim (she joined after distribution)
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        STAKING.claimRewards(valId);
        uint256 aliceClaimed = alice.balance - aliceBal;
        assertEq(aliceClaimed, 0, "late delegator should not claim past rewards");

        // Auth should still get the full 100 MON
        uint256 authBal = auth.balance;
        vm.prank(auth);
        STAKING.claimRewards(valId);
        assertEq(auth.balance - authBal, 100 ether, "auth gets full past reward");
    }

    // =========================================================================
    // Commission Change Mid-Lifecycle
    // =========================================================================

    /// @dev Changing commission rate affects only future reward distributions.
    function test_commissionChangeAffectsFutureRewards() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18); // 10%
        monad.epochBoundary(2);

        // Epoch 2: 10% commission, 100 MON reward
        // Auth (sole delegator) gets commission (10) + share (90) = 100 MON
        monad.blockReward(auth, 100 ether);
        uint256 bal1 = auth.balance;
        STAKING.claimRewards(valId);
        uint256 claimed1 = auth.balance - bal1;
        assertEq(claimed1, 100 ether, "auth gets full reward as sole delegator");

        // Change commission to 50%
        STAKING.changeCommission(valId, 0.5e18);

        // Need new epoch for consensus views to reflect new commission
        monad.epochBoundary(3);

        // Epoch 3: 50% commission, 100 MON reward
        // Auth (sole delegator) gets commission (50) + share (50) = 100 MON
        monad.blockReward(auth, 100 ether);
        uint256 bal2 = auth.balance;
        STAKING.claimRewards(valId);
        uint256 claimed2 = auth.balance - bal2;
        assertEq(claimed2, 100 ether, "auth gets full reward as sole delegator");
    }

    // =========================================================================
    // External Reward Then Claim
    // =========================================================================

    /// @dev externalReward adds directly to accumulator, delegators can claim.
    function test_externalRewardThenClaim() public {
        monad.setEpoch(1, false);
        address auth = address(0xEE);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // Anyone can send external reward
        address rewarder = address(0xF1);
        vm.deal(rewarder, 50 ether);
        vm.prank(rewarder);
        STAKING.externalReward{value: 50 ether}(valId);

        // Auth (sole delegator) claims
        uint256 bal = auth.balance;
        vm.prank(auth);
        STAKING.claimRewards(valId);
        assertEq(auth.balance - bal, 50 ether, "delegator claims full external reward");
    }

    // =========================================================================
    // Undelegate-Withdraw Across Epochs
    // =========================================================================

    /// @dev Withdrawal request persists across epoch boundaries.
    function test_withdrawalPersistsAcrossEpochs() public {
        monad.setEpoch(1, false);
        address auth = address(this);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);

        // Delegate extra
        address delegator = address(0xD1);
        vm.deal(delegator, 5000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 5000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        // Undelegate at epoch 2 → WR activationEpoch = 3
        vm.prank(delegator);
        STAKING.undelegate(valId, 5000 ether, 0);

        // Verify withdrawal request
        (uint256 wrAmount,,) = STAKING.getWithdrawalRequest(valId, delegator, 0);
        assertEq(wrAmount, 5000 ether, "withdrawal request exists");

        // Advance epochs
        monad.epochBoundary(3);

        // Withdrawal request should still exist
        (wrAmount,,) = STAKING.getWithdrawalRequest(valId, delegator, 0);
        assertEq(wrAmount, 5000 ether, "withdrawal persists after epoch boundary");

        // Need epoch > wr_epoch + WITHDRAWAL_DELAY → epoch > 4
        monad.epochBoundary(4);
        monad.epochBoundary(5);

        // Now withdraw
        uint256 bal = delegator.balance;
        vm.prank(delegator);
        STAKING.withdraw(valId, 0);
        assertGe(delegator.balance - bal, 5000 ether, "got funds back");
    }

    // =========================================================================
    // Multiple Withdrawal Slots
    // =========================================================================

    /// @dev Multiple undelegations using different withdrawal IDs.
    function test_multipleWithdrawalIds() public {
        monad.setEpoch(1, false);
        uint64 valId = _createValidator(address(this), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 3000 ether);
        vm.prank(delegator);
        STAKING.delegate{value: 3000 ether}(valId);

        // Activate delegations before undelegating
        monad.epochBoundary(2);

        // Three separate undelegations with different withdraw IDs (epoch 2 → WR epoch 3)
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 0);
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 1);
        vm.prank(delegator);
        STAKING.undelegate(valId, 1000 ether, 2);

        // Verify all three withdrawal requests
        (uint256 wr0,,) = STAKING.getWithdrawalRequest(valId, delegator, 0);
        (uint256 wr1,,) = STAKING.getWithdrawalRequest(valId, delegator, 1);
        (uint256 wr2,,) = STAKING.getWithdrawalRequest(valId, delegator, 2);
        assertEq(wr0, 1000 ether);
        assertEq(wr1, 1000 ether);
        assertEq(wr2, 1000 ether);

        // Advance past withdrawal delay: wr_epoch=3, need epoch > 4
        monad.epochBoundary(3);
        monad.epochBoundary(4);
        monad.epochBoundary(5);

        uint256 bal = delegator.balance;
        vm.prank(delegator);
        STAKING.withdraw(valId, 0);
        vm.prank(delegator);
        STAKING.withdraw(valId, 1);
        vm.prank(delegator);
        STAKING.withdraw(valId, 2);

        assertGe(delegator.balance - bal, 3000 ether, "all three withdrawals");
    }

    // =========================================================================
    // getDelegations / getDelegators Integration
    // =========================================================================

    /// @dev Verify getDelegations and getDelegators reflect write operations.
    function test_delegationListsReflectState() public {
        monad.setEpoch(1, false);
        uint64 valId1 = _createValidator(address(0xF1), ACTIVE_STAKE, 0);
        uint64 valId2 = _createValidator(address(0xF2), ACTIVE_STAKE, 0);

        address delegator = address(0xD1);
        vm.deal(delegator, 2000 ether);

        // Delegate to both validators
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId1);
        vm.prank(delegator);
        STAKING.delegate{value: 1000 ether}(valId2);

        // getDelegations should show both validators
        (bool isDone,, uint64[] memory valIds) = STAKING.getDelegations(delegator, 0);
        assertTrue(isDone);
        assertEq(valIds.length, 2, "delegated to 2 validators");

        // getDelegators for valId1 should include auth + delegator
        address[] memory delegators;
        (isDone,, delegators) = STAKING.getDelegators(valId1, address(0));
        assertTrue(isDone);
        assertGe(delegators.length, 2, "at least auth + delegator");
    }

    // =========================================================================
    // Validator Set Evolution
    // =========================================================================

    /// @dev Validator set evolves as validators gain/lose stake across epoch boundaries.
    function test_validatorSetEvolution() public {
        monad.setEpoch(1, false);

        // Create three validators: val1 < val2 < val3 by stake
        uint64 valId1 = _createValidator(address(0xE1), 10_000_000 ether, 0);
        uint64 valId2 = _createValidator(address(0xE2), 20_000_000 ether, 0);
        uint64 valId3 = _createValidator(address(0xE3), 30_000_000 ether, 0);

        // First epoch boundary: consensus set sorted by stake desc
        monad.epochBoundary(2);

        (,, uint64[] memory consSet) = STAKING.getConsensusValidatorSet(0);
        assertEq(consSet.length, 3);
        assertEq(consSet[0], valId3, "highest stake first");
        assertEq(consSet[1], valId2, "middle stake second");
        assertEq(consSet[2], valId1, "lowest stake third");

        // Delegator adds massive stake to val1, making it the largest
        address bigDelegator = address(0xB19);
        vm.deal(bigDelegator, 100_000_000 ether);
        vm.prank(bigDelegator);
        STAKING.delegate{value: 100_000_000 ether}(valId1);

        // New epoch boundary: val1 should now be first
        monad.epochBoundary(3);

        (,, consSet) = STAKING.getConsensusValidatorSet(0);
        assertEq(consSet[0], valId1, "val1 now has highest stake");
    }

    // =========================================================================
    // T1: Commission Goes to Auth Address
    // =========================================================================

    /// @dev After blockReward with 10% commission, auth claimRewards gets
    ///      commission + proportional share.
    function test_blockReward_commissionGoesToAuth() public {
        monad.setEpoch(1, false);
        address auth = address(0xCA);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.1e18); // 10% commission

        // Add a second delegator with equal stake
        address alice = address(0xA11CE);
        vm.deal(alice, ACTIVE_STAKE);
        vm.prank(alice);
        STAKING.delegate{value: ACTIVE_STAKE}(valId);

        // Total: 10M (auth) + 10M (alice) = 20M, each 50%
        monad.epochBoundary(2);

        // Block reward: 150 MON
        monad.blockReward(auth, 150 ether);
        // Commission = 150 * 0.1 = 15 MON → credited to auth.rewards
        // del_reward = 135 MON → split 50/50 via accumulator

        // Auth claims: commission (15) + 50% of del_reward (67.5) = 82.5 MON
        uint256 authBal = auth.balance;
        vm.prank(auth);
        STAKING.claimRewards(valId);
        uint256 authClaimed = auth.balance - authBal;
        assertEq(authClaimed, 82.5 ether, "auth gets commission + proportional share");

        // Alice claims: 50% of del_reward = 67.5 MON (no commission)
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        STAKING.claimRewards(valId);
        uint256 aliceClaimed = alice.balance - aliceBal;
        assertEq(aliceClaimed, 67.5 ether, "alice gets proportional share only");

        // Total: 82.5 + 67.5 = 150 = full block reward
    }

    // =========================================================================
    // T2: Unclaimed Rewards Accuracy
    // =========================================================================

    /// @dev After all delegators + auth claim, validator.unclaimedRewards == 0.
    function test_blockReward_unclaimedRewardsAccuracy() public {
        monad.setEpoch(1, false);
        address auth = address(0xCB);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0.05e18); // 5% commission

        address bob = address(0xB0B);
        vm.deal(bob, ACTIVE_STAKE);
        vm.prank(bob);
        STAKING.delegate{value: ACTIVE_STAKE}(valId);

        monad.epochBoundary(2);
        monad.blockReward(auth, 200 ether);

        // Before claims: unclaimed should be del_reward = 200 - 10 = 190
        (,,,,, uint256 unclaimed) = _getValidatorCore(valId);
        assertEq(unclaimed, 190 ether, "unclaimed = del_reward after blockReward");

        // Auth claims
        vm.prank(auth);
        STAKING.claimRewards(valId);

        // Bob claims
        vm.prank(bob);
        STAKING.claimRewards(valId);

        // After all claims, unclaimed should be zero
        (,,,,, unclaimed) = _getValidatorCore(valId);
        assertEq(unclaimed, 0, "unclaimed should be zero after all claims");
    }

    // =========================================================================
    // T8: Validator Flags — STAKE_TOO_LOW Lifecycle
    // =========================================================================

    /// @dev Flag set/cleared as validator stake crosses threshold.
    function test_validatorFlags_stakeTooLow_lifecycle() public {
        monad.setEpoch(1, false);

        // Create validator below active stake threshold
        uint256 lowStake = 100_000 ether; // MIN_AUTH but < ACTIVE_STAKE
        uint64 valId = _createValidator(address(0xF8), lowStake, 0);

        (, uint64 flags,,,,) = _getValidatorCore(valId);
        assertEq(flags & 1, 1, "STAKE_TOO_LOW should be set");

        // Delegator adds stake to cross threshold
        address delegator = address(0xD8);
        uint256 needed = ACTIVE_STAKE - lowStake;
        vm.deal(delegator, needed);
        vm.prank(delegator);
        STAKING.delegate{value: needed}(valId);

        (, flags,,,,) = _getValidatorCore(valId);
        assertEq(flags & 1, 0, "STAKE_TOO_LOW should be cleared");

        // Activate then undelegate to drop below
        monad.epochBoundary(2);
        vm.prank(delegator);
        STAKING.undelegate(valId, needed, 0);

        (, flags,,,,) = _getValidatorCore(valId);
        assertEq(flags & 1, 1, "STAKE_TOO_LOW should be set again");
    }

    // =========================================================================
    // T9: Validator Flags — WITHDRAWN Lifecycle
    // =========================================================================

    /// @dev WITHDRAWN flag set when auth underdelegates below 100K MON.
    function test_validatorFlags_withdrawn_lifecycle() public {
        monad.setEpoch(1, false);
        address auth = address(0xF9);
        uint64 valId = _createValidator(auth, ACTIVE_STAKE, 0);

        (, uint64 flags,,,,) = _getValidatorCore(valId);
        assertEq(flags & 2, 0, "WITHDRAWN should not be set initially");

        // Auth undelegates below MIN_AUTH_ADDRESS_STAKE
        monad.epochBoundary(2);
        uint256 undelegateAmount = ACTIVE_STAKE - 50_000 ether; // leaves 50K < 100K
        vm.prank(auth);
        STAKING.undelegate(valId, undelegateAmount, 0);

        (, flags,,,,) = _getValidatorCore(valId);
        assertEq(flags & 2, 2, "WITHDRAWN should be set after auth underdelegates");

        // Re-delegate to restore above threshold
        vm.deal(auth, 100_000 ether);
        vm.prank(auth);
        STAKING.delegate{value: 100_000 ether}(valId);

        (, flags,,,,) = _getValidatorCore(valId);
        assertEq(flags & 2, 0, "WITHDRAWN should be cleared after re-delegate");
    }

    // =========================================================================
    // T13: External Reward to Multiple Validators
    // =========================================================================

    /// @dev Independent external rewards to different validators.
    function test_externalReward_multipleValidators() public {
        monad.setEpoch(1, false);
        address auth1 = address(0xE1);
        address auth2 = address(0xE2);
        uint64 valId1 = _createValidator(auth1, ACTIVE_STAKE, 0);
        uint64 valId2 = _createValidator(auth2, ACTIVE_STAKE, 0);
        monad.epochBoundary(2);

        // Different reward amounts
        vm.deal(address(this), 30 ether);
        STAKING.externalReward{value: 10 ether}(valId1);
        STAKING.externalReward{value: 20 ether}(valId2);

        // Claim from val1
        uint256 bal1 = auth1.balance;
        vm.prank(auth1);
        STAKING.claimRewards(valId1);
        assertEq(auth1.balance - bal1, 10 ether, "val1 gets 10 ether");

        // Claim from val2
        uint256 bal2 = auth2.balance;
        vm.prank(auth2);
        STAKING.claimRewards(valId2);
        assertEq(auth2.balance - bal2, 20 ether, "val2 gets 20 ether");
    }
}
