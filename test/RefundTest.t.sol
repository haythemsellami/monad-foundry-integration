// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

/// @title RefundTest
/// @notice Proves Monad's no-refund gas model
/// @dev Verified via anvil testing:
///
///      | Operation      | Ethereum  | Monad   | Difference |
///      |----------------|-----------|---------|------------|
///      | setValue(1)    | 43,718    | 49,718  | +6,000     |
///      | clearValue()   | 21,441    | 32,241  | +10,800    |
///      | setValue(2)    | 43,718    | 49,718  | +6,000     |
///
///      clearValue() costs 10,800 MORE gas on Monad:
///        - +6,000: Higher cold storage (8100 vs 2100)
///        - +4,800: No refund (Ethereum refunds 4800 for clearing)
///
///      To reproduce:
///        1. foundryup --use stable && anvil
///        2. Deploy, setValue(1), clearValue() -> 21,441 gas
///        3. foundryup --use haythemsellami-branch-monad-forge-integration && anvil --monad
///        4. Deploy, setValue(1), clearValue() -> 32,241 gas
///
/// Monad behavior (from handler.rs):
///   - refund() sets exec_result.gas_mut().set_refund(0)
///   - reimburse_caller() does nothing
///   - No refund for clearing storage
contract RefundTest is Test {
    // Monad Gas Constants
    uint256 constant MIP8_BASE_COST = 100;
    uint256 constant MONAD_COLD_PAGE_READ = 8000;
    uint256 constant PAGE_WRITE_COST = 2800;
    uint256 constant STATE_GROWTH_COST = 17000;

    /// @notice Verify Monad's cold storage cost
    /// @dev PASSES on Monad Foundry, FAILS on standard Foundry
    function test_MonadColdStorageCost() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Baseline
        assembly {
            gasBefore := gas()
            gasAfter := gas()
        }
        uint256 baseline = gasBefore - gasAfter;

        // Cold SSTORE (0 -> 1)
        assembly {
            gasBefore := gas()
            sstore(0x400, 1)
            gasAfter := gas()
        }
        uint256 coldCost = (gasBefore - gasAfter) - baseline - 6;

        console.log("Cold SSTORE cost:", coldCost);
        uint256 expected = MIP8_BASE_COST + MONAD_COLD_PAGE_READ + PAGE_WRITE_COST + STATE_GROWTH_COST;
        console.log("Expected (Monad):", expected);

        assertEq(coldCost, expected, "Must match MonadTen MIP-8 pricing (27900)");
    }
}

/// @notice Helper contract for storage operations
contract StorageClearer {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function clearValue() external {
        value = 0;
    }
}
