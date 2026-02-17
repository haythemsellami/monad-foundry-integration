// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStakingPrecompile
/// @notice Interface for the Monad staking precompile at 0x1000
/// @dev Reference: https://docs.monad.xyz/developer-essentials/staking/staking-precompile
/// @dev The staking precompile only accepts plain CALL — STATICCALL, DELEGATECALL, and
///      CALLCODE are rejected. Read functions are NOT marked `view` because some of them
///      modify state internally (e.g. getDelegator pulls delegator state up to date).
interface IStakingPrecompile {
    // ============ State-Modifying Functions ============

    /// @notice Add a new validator
    /// @param payload Validator payload data
    /// @param signedSecpMessage Signed SECP message
    /// @param signedBlsMessage Signed BLS message
    /// @return validatorId The ID of the newly added validator
    function addValidator(bytes calldata payload, bytes calldata signedSecpMessage, bytes calldata signedBlsMessage)
        external
        payable
        returns (uint64 validatorId);

    /// @notice Delegate stake to a validator
    /// @param validatorId The validator to delegate to
    /// @return success Whether the delegation succeeded
    function delegate(uint64 validatorId) external payable returns (bool success);

    /// @notice Undelegate stake from a validator
    /// @param validatorId The validator to undelegate from
    /// @param amount The amount to undelegate
    /// @param withdrawId The withdrawal ID
    /// @return success Whether the undelegation succeeded
    function undelegate(uint64 validatorId, uint256 amount, uint8 withdrawId) external returns (bool success);

    /// @notice Withdraw undelegated stake
    /// @param validatorId The validator to withdraw from
    /// @param withdrawId The withdrawal ID
    /// @return success Whether the withdrawal succeeded
    function withdraw(uint64 validatorId, uint8 withdrawId) external returns (bool success);

    /// @notice Compound rewards back into stake
    /// @param validatorId The validator to compound for
    /// @return success Whether the compounding succeeded
    function compound(uint64 validatorId) external returns (bool success);

    /// @notice Claim staking rewards
    /// @param validatorId The validator to claim rewards from
    /// @return success Whether the claim succeeded
    function claimRewards(uint64 validatorId) external returns (bool success);

    /// @notice Change validator commission rate
    /// @param validatorId The validator to change commission for
    /// @param commission The new commission rate
    /// @return success Whether the change succeeded
    function changeCommission(uint64 validatorId, uint256 commission) external returns (bool success);

    /// @notice Add external reward to a validator
    /// @param validatorId The validator to reward
    /// @return success Whether the reward succeeded
    function externalReward(uint64 validatorId) external returns (bool success);

    // ============ Read Functions (NOT view — must be called via CALL) ============

    /// @notice Get validator information
    /// @param validatorId The validator ID to query
    function getValidator(uint64 validatorId)
        external
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards,
            uint256 consensusStake,
            uint256 consensusCommission,
            uint256 snapshotStake,
            uint256 snapshotCommission,
            bytes memory secpPubkey,
            bytes memory blsPubkey
        );

    /// @notice Get delegator information for a specific validator
    /// @param validatorId The validator ID
    /// @param delegator The delegator address
    function getDelegator(uint64 validatorId, address delegator)
        external
        returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        );

    /// @notice Get withdrawal request information
    /// @param validatorId The validator ID
    /// @param delegator The delegator address
    /// @param withdrawId The withdrawal ID
    function getWithdrawalRequest(uint64 validatorId, address delegator, uint8 withdrawId)
        external
        returns (uint256 withdrawalAmount, uint256 accRewardPerToken, uint64 withdrawEpoch);

    /// @notice Get consensus validator set (paginated)
    /// @param startIndex Starting index for pagination
    function getConsensusValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    /// @notice Get snapshot validator set (paginated)
    /// @param startIndex Starting index for pagination
    function getSnapshotValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    /// @notice Get execution validator set (paginated)
    /// @param startIndex Starting index for pagination
    function getExecutionValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    /// @notice Get delegations for a delegator (paginated)
    /// @param delegator The delegator address
    /// @param startValId Starting validator ID for pagination
    function getDelegations(address delegator, uint64 startValId)
        external
        returns (bool isDone, uint64 nextValId, uint64[] memory valIds);

    /// @notice Get delegators for a validator (paginated)
    /// @param validatorId The validator ID
    /// @param startDelegator Starting delegator address for pagination
    function getDelegators(uint64 validatorId, address startDelegator)
        external
        returns (bool isDone, address nextDelegator, address[] memory delegators);

    /// @notice Get current epoch information
    /// @return epoch The current epoch number
    /// @return inEpochDelayPeriod Whether currently in epoch delay period
    function getEpoch() external returns (uint64 epoch, bool inEpochDelayPeriod);

    /// @notice Get the current proposer validator ID
    /// @return valId The proposer's validator ID
    function getProposerValId() external returns (uint64 valId);
}
