// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMonadVm
/// @notice Monad-specific cheatcodes for staking lifecycle control in Foundry tests.
/// @dev Address: 0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA (keccak256("monad cheatcode")[12:])
///
///      These cheatcodes provide two categories of functionality:
///      1. Direct state control: setEpoch, setProposer, setAccumulator
///      2. Syscall wrappers: blockReward, epochSnapshot, epochChange, epochBoundary
///
///      State-mutating staking functions (delegate, undelegate, addValidator, etc.)
///      are handled by the staking precompile at 0x1000 directly.
interface IMonadVm {
    /// @notice Sets the current epoch and delay period for the staking precompile.
    function setEpoch(uint64 epoch, bool inDelayPeriod) external;

    /// @notice Sets the current block proposer validator ID.
    function setProposer(uint64 valId) external;

    /// @notice Directly sets a validator's accumulated reward per token.
    function setAccumulator(uint64 valId, uint256 value) external;

    /// @notice Distribute block reward via the real syscallReward handler.
    /// @dev Mints `reward` to staking address and distributes via accumulator math
    ///      using consensus/snapshot view stake (production-equivalent behavior).
    function blockReward(address author, uint256 reward) external;

    /// @notice Execute syscallSnapshot: copies consensus→snapshot view, rebuilds
    ///         consensus set from execution set sorted by stake. Sets in_boundary = true.
    function epochSnapshot() external;

    /// @notice Execute syscallOnEpochChange: increments epoch, clears in_boundary.
    /// @dev `newEpoch` must equal `currentEpoch + 1`.
    function epochChange(uint64 newEpoch) external;

    /// @notice Convenience: epochSnapshot() then epochChange(newEpoch).
    function epochBoundary(uint64 newEpoch) external;
}
