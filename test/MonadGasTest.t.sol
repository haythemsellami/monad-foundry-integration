// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/// @title MonadGasTest
/// @notice Comprehensive tests for Monad's gas pricing model
/// @dev Monad differences from Ethereum:
///
///      Cold Access Costs:
///        - COLD_SLOAD_COST:           8100 (Ethereum: 2100)
///        - COLD_ACCOUNT_ACCESS_COST: 10100 (Ethereum: 2600)
///        - WARM_ACCESS_COST:           100 (same as Ethereum)
///
///      SSTORE Costs (same as Ethereum):
///        - SSTORE_SET:   20000 (0 -> non-zero)
///        - SSTORE_RESET:  2900 (non-zero -> X when current == original)
///        - SSTORE_DIRTY:   100 (when current != original)
///
///      No-Refund Model (from handler.rs):
///        - refund() sets refund counter to 0
///        - reimburse_caller() does nothing
///        - No refund for clearing storage to 0
///
///      Gas Limit Charging:
///        - User pays gas_limit * gas_price (not gas_used)
///        - Beneficiary receives priority_fee * gas_limit
contract MonadGasTest is Test {
    // =========================================================================
    // Monad Gas Constants (from monad-revm/src/instructions.rs)
    // =========================================================================
    uint256 constant MONAD_COLD_SLOAD_COST = 8100;
    uint256 constant MONAD_COLD_ACCOUNT_ACCESS_COST = 10100;
    uint256 constant WARM_ACCESS_COST = 100;

    // Ethereum gas costs (for reference)
    uint256 constant ETH_COLD_SLOAD_COST = 2100;
    uint256 constant ETH_COLD_ACCOUNT_ACCESS_COST = 2600;

    // =========================================================================
    // Standard EVM Constants (unchanged in Monad)
    // =========================================================================
    uint256 constant SSTORE_SET = 20000;
    uint256 constant SSTORE_RESET = 2900;
    uint256 constant SSTORE_DIRTY = 100;

    // Measurement overhead from stack operations
    uint256 constant MEASUREMENT_OVERHEAD = 25;

    // Expected measured values
    uint256 constant EXPECTED_COLD_ACCOUNT_GAS = MONAD_COLD_ACCOUNT_ACCESS_COST + MEASUREMENT_OVERHEAD;
    uint256 constant EXPECTED_WARM_GAS = WARM_ACCESS_COST + MEASUREMENT_OVERHEAD;
    uint256 constant COLD_WARM_DIFFERENCE = MONAD_COLD_ACCOUNT_ACCESS_COST - WARM_ACCESS_COST;

    StorageContract storageTarget;

    function setUp() public {
        storageTarget = new StorageContract();
    }

    // =========================================================================
    // SECTION 1: Cold/Warm Account Access Tests (BALANCE, EXTCODESIZE, EXTCODEHASH)
    // =========================================================================

    /// @notice Test cold BALANCE costs 10100 gas (Monad) vs 2600 (Ethereum)
    function test_ColdBalanceGasCost() public {
        address target =
            address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "cold1")))));

        uint256 gasBefore = gasleft();
        uint256 bal = target.balance;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, bal) }

        uint256 gasUsed = gasBefore - gasAfter;
        console.log("Cold BALANCE gas:", gasUsed);

        assertEq(gasUsed, EXPECTED_COLD_ACCOUNT_GAS, "Cold BALANCE must cost 10125 (10100 + 25 overhead)");
        assertGt(gasUsed, ETH_COLD_ACCOUNT_ACCESS_COST + MEASUREMENT_OVERHEAD, "Must be higher than Ethereum");
    }

    /// @notice Test warm BALANCE costs 100 gas (same as Ethereum)
    function test_WarmBalanceGasCost() public {
        address target = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, "warm1")))));

        uint256 bal1 = target.balance; // Cold access (warm up)

        uint256 gasBefore = gasleft();
        uint256 bal2 = target.balance; // Warm access
        uint256 gasAfter = gasleft();

        assembly {
            mstore(0, bal1)
            mstore(32, bal2)
        }

        uint256 warmGas = gasBefore - gasAfter;
        console.log("Warm BALANCE gas:", warmGas);

        assertEq(warmGas, EXPECTED_WARM_GAS, "Warm BALANCE must cost 125 (100 + 25 overhead)");
    }

    /// @notice Test cold EXTCODESIZE costs 10100 gas (Monad)
    function test_ColdExtcodesizeGasCost() public {
        address target =
            address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "extcode")))));

        uint256 gasBefore = gasleft();
        uint256 size = target.code.length;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, size) }

        uint256 gasUsed = gasBefore - gasAfter;
        console.log("Cold EXTCODESIZE gas:", gasUsed);

        assertEq(gasUsed, EXPECTED_COLD_ACCOUNT_GAS, "Cold EXTCODESIZE must cost 10125");
    }

    /// @notice Test cold EXTCODEHASH costs 10100 gas (Monad)
    function test_ColdExtcodehashGasCost() public {
        address target =
            address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "extcodehash")))));

        uint256 gasBefore = gasleft();
        bytes32 hash = target.codehash;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, hash) }

        uint256 gasUsed = gasBefore - gasAfter;
        console.log("Cold EXTCODEHASH gas:", gasUsed);

        assertEq(gasUsed, EXPECTED_COLD_ACCOUNT_GAS, "Cold EXTCODEHASH must cost 10125");
    }

    /// @notice Test cold vs warm difference is exactly 10000 (Monad) vs 2500 (Ethereum)
    function test_ColdWarmDifferenceIsExact() public {
        address target = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, "diff1")))));

        uint256 gasBefore = gasleft();
        uint256 bal1 = target.balance; // Cold
        uint256 gasAfterCold = gasleft();

        uint256 bal2 = target.balance; // Warm
        uint256 gasAfterWarm = gasleft();

        assembly {
            mstore(0, bal1)
            mstore(32, bal2)
        }

        uint256 coldGas = gasBefore - gasAfterCold;
        uint256 warmGas = gasAfterCold - gasAfterWarm;
        uint256 difference = coldGas - warmGas;

        console.log("Cold gas:", coldGas);
        console.log("Warm gas:", warmGas);
        console.log("Difference:", difference);

        assertEq(difference, COLD_WARM_DIFFERENCE, "Cold/warm difference must be 10000 (Monad pricing)");
    }

    // =========================================================================
    // SECTION 2: SLOAD Tests
    // =========================================================================

    /// @notice Test SLOAD cold/warm difference
    function test_SloadColdWarmDifference() public {
        StorageReader reader = new StorageReader();

        bytes32 slot = bytes32(uint256(100));
        bytes32 value = bytes32(uint256(42));
        vm.store(address(reader), slot, value);

        uint256 gasBefore = gasleft();
        reader.readSlot(uint256(slot));
        uint256 gasAfterFirst = gasleft();

        reader.readSlot(uint256(slot));
        uint256 gasAfterSecond = gasleft();

        uint256 firstCallGas = gasBefore - gasAfterFirst;
        uint256 secondCallGas = gasAfterFirst - gasAfterSecond;

        console.log("First SLOAD call gas:", firstCallGas);
        console.log("Second SLOAD call gas:", secondCallGas);

        assertGt(firstCallGas, 100, "First SLOAD should cost more than warm access");
    }

    // =========================================================================
    // SECTION 3: SSTORE Tests (Cold/Warm/Dirty Slot Costs)
    // =========================================================================

    /// @notice Test exact SSTORE costs with inline assembly
    /// @dev Verifies cold SSTORE = 28100 (8100 + 20000), dirty slot = 100
    function test_SstoreExactCosts() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Baseline overhead
        assembly {
            gasBefore := gas()
            gasAfter := gas()
        }
        uint256 baseline = gasBefore - gasAfter;

        // Cold SSTORE (0 -> 1): 8100 + 20000 = 28100
        assembly {
            gasBefore := gas()
            sstore(0x100, 1)
            gasAfter := gas()
        }
        uint256 coldCost = (gasBefore - gasAfter) - baseline - 6; // 6 = PUSH overhead

        console.log("Cold SSTORE (0->1):", coldCost);
        assertEq(coldCost, MONAD_COLD_SLOAD_COST + SSTORE_SET, "Cold SSTORE must cost 28100");

        // Warm clear (1 -> 0): dirty slot = 100
        assembly {
            gasBefore := gas()
            sstore(0x100, 0)
            gasAfter := gas()
        }
        uint256 clearCost = (gasBefore - gasAfter) - baseline - 5; // 5 = PUSH2 + PUSH0

        console.log("Warm clear (1->0):", clearCost);
        assertEq(clearCost, SSTORE_DIRTY, "Dirty slot clear must cost 100");

        // Warm set (0 -> 2): SSTORE_SET = 20000
        assembly {
            gasBefore := gas()
            sstore(0x100, 2)
            gasAfter := gas()
        }
        uint256 setCost = (gasBefore - gasAfter) - baseline - 6;

        console.log("Warm set (0->2):", setCost);
        assertEq(setCost, SSTORE_SET, "Clean slot set must cost 20000");

        // Warm modify (2 -> 3): dirty slot = 100
        assembly {
            gasBefore := gas()
            sstore(0x100, 3)
            gasAfter := gas()
        }
        uint256 modifyCost = (gasBefore - gasAfter) - baseline - 6;

        console.log("Warm modify (2->3):", modifyCost);
        assertEq(modifyCost, SSTORE_DIRTY, "Dirty slot modify must cost 100");
    }

    /// @notice Test cold SSTORE via external call
    function test_SstoreColdAccessCost() public {
        StorageContract freshTarget = new StorageContract();

        uint256 gasBefore = gasleft();
        freshTarget.setStorage(42);
        uint256 gasAfter = gasleft();

        uint256 gasUsed = gasBefore - gasAfter;
        console.log("Cold SSTORE (external):", gasUsed);

        assertTrue(gasUsed > 5000, "Cold SSTORE should cost more than Ethereum baseline");
    }

    // =========================================================================
    // SECTION 4: No-Refund Model Tests
    // =========================================================================

    /// @notice Prove clear and modify cost the same (no refund advantage)
    function test_NoRefundOnStorageClear() public {
        uint256 gasBefore;
        uint256 gasAfter;

        assembly {
            gasBefore := gas()
            gasAfter := gas()
        }
        uint256 baseline = gasBefore - gasAfter;

        // Set value first
        assembly { sstore(0x200, 1) }

        // Clear (1 -> 0)
        assembly {
            gasBefore := gas()
            sstore(0x200, 0)
            gasAfter := gas()
        }
        uint256 clearCost = (gasBefore - gasAfter) - baseline - 5;

        // Set again
        assembly { sstore(0x200, 2) }

        // Modify (2 -> 3)
        assembly {
            gasBefore := gas()
            sstore(0x200, 3)
            gasAfter := gas()
        }
        uint256 modifyCost = (gasBefore - gasAfter) - baseline - 6;

        console.log("Clear cost:", clearCost);
        console.log("Modify cost:", modifyCost);

        // Both should be SSTORE_DIRTY (100) - no refund advantage for clearing
        assertEq(clearCost, SSTORE_DIRTY, "Clear must cost 100");
        assertEq(modifyCost, SSTORE_DIRTY, "Modify must cost 100");
        assertEq(clearCost, modifyCost, "Clear and modify must cost the same (no refund)");
    }

    /// @notice Test storage pattern: set -> clear -> set -> clear
    function test_StorageRefundPattern() public {
        uint256[] memory gasCosts = new uint256[](4);

        uint256 gasBefore = gasleft();
        storageTarget.setStorage(1);
        gasCosts[0] = gasBefore - gasleft();

        gasBefore = gasleft();
        storageTarget.clearStorage();
        gasCosts[1] = gasBefore - gasleft();

        gasBefore = gasleft();
        storageTarget.setStorage(2);
        gasCosts[2] = gasBefore - gasleft();

        gasBefore = gasleft();
        storageTarget.clearStorage();
        gasCosts[3] = gasBefore - gasleft();

        console.log("Set (cold):", gasCosts[0]);
        console.log("Clear (1st):", gasCosts[1]);
        console.log("Set (warm):", gasCosts[2]);
        console.log("Clear (2nd):", gasCosts[3]);

        // Both clears should have similar cost (no refund accumulation)
        uint256 clearDiff = gasCosts[1] > gasCosts[3] ? gasCosts[1] - gasCosts[3] : gasCosts[3] - gasCosts[1];

        assertTrue(clearDiff < 2000, "Clear operations should have similar cost");
    }
}

// =============================================================================
// Helper Contracts
// =============================================================================

contract StorageReader {
    function readSlot(uint256 slot) external view returns (bytes32 value) {
        assembly { value := sload(slot) }
    }
}

contract StorageContract {
    uint256 public slot0;
    uint256 public slot1;
    uint256 public slot2;

    function setStorage(uint256 value) external {
        slot0 = value;
    }

    function clearStorage() external {
        slot0 = 0;
    }

    function setMultipleSlots(uint256 a, uint256 b, uint256 c) external {
        slot0 = a;
        slot1 = b;
        slot2 = c;
    }

    function clearMultipleSlots() external {
        slot0 = 0;
        slot1 = 0;
        slot2 = 0;
    }

    function getStorage() external view returns (uint256) {
        return slot0;
    }
}
