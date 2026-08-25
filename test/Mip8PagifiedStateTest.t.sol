// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Mip8StorageDemo} from "src/Mip8StorageDemo.sol";

abstract contract Mip8PagifiedStateTestBase is Test {
    uint256 internal constant PAGE_CROSSING_INDEX = 128;

    function _measureReadOps(Mip8StorageDemo demo, uint256 slotA, uint256 slotB)
        internal
        returns (uint256 firstGas, uint256 secondGas, uint256 checksum)
    {
        (bool ok, bytes memory ret) = address(demo).call(abi.encodeCall(Mip8StorageDemo.measureRead, (slotA, slotB)));
        assertTrue(ok, "measureRead call should succeed");
        return abi.decode(ret, (uint256, uint256, uint256));
    }

    function _measureWriteOps(Mip8StorageDemo demo, uint256 slotA, uint256 slotB, uint256 valueA, uint256 valueB)
        internal
        returns (uint256 firstGas, uint256 secondGas)
    {
        (bool ok, bytes memory ret) =
            address(demo).call(abi.encodeCall(Mip8StorageDemo.measureWrite, (slotA, slotB, valueA, valueB)));
        assertTrue(ok, "measureWrite call should succeed");
        return abi.decode(ret, (uint256, uint256));
    }
}

contract MonadTenMip8PagifiedStateTest is Mip8PagifiedStateTestBase {
    uint256 internal constant READ_PAGE_DISCOUNT = 8000;
    uint256 internal constant PAGE_WRITE_COST = 2800;
    uint256 internal constant COLD_PAGE_WRITE_COST = 10800;
    uint256 internal constant BASE_WRITE_GAS = 108;
    uint256 internal constant STATE_GROWTH_COST = 17000;

    function test_denseArrayReadsWarmByPage() public {
        Mip8StorageDemo adjacent = new Mip8StorageDemo();
        Mip8StorageDemo far = new Mip8StorageDemo();

        (, uint256 adjacentSecond, uint256 adjacentChecksum) = _measureReadOps(adjacent, 0, 1);
        (, uint256 farSecond, uint256 farChecksum) = _measureReadOps(far, 0, PAGE_CROSSING_INDEX);

        assertEq(adjacentChecksum, 0, "same-page dense read checksum");
        assertEq(farChecksum, 0, "different-page dense read checksum");
        assertEq(
            farSecond - adjacentSecond,
            READ_PAGE_DISCOUNT,
            "same-page second dense read should realize the MIP-8 page discount"
        );
    }

    function test_denseArrayWritesWarmByPage() public {
        Mip8StorageDemo adjacent = new Mip8StorageDemo();
        Mip8StorageDemo far = new Mip8StorageDemo();

        (, uint256 adjacentSecond) = _measureWriteOps(adjacent, 0, 1, 1, 2);
        (, uint256 farSecond) = _measureWriteOps(far, 0, PAGE_CROSSING_INDEX, 1, 2);

        assertEq(
            farSecond - adjacentSecond,
            COLD_PAGE_WRITE_COST,
            "same-page second dense write should realize the MIP-8 page discount"
        );
    }

    function test_mappingStructFieldsBenefitButDifferentKeysDoNot() public {
        Mip8StorageDemo sparseReadDemo = new Mip8StorageDemo();
        uint256 sparseSlot1 = sparseReadDemo.sparseSlot(1);
        uint256 sparseSlot2 = sparseReadDemo.sparseSlot(2);

        Mip8StorageDemo recordReadDemo = new Mip8StorageDemo();
        (uint256 recordSlotA, uint256 recordSlotB) = recordReadDemo.recordSlots(1);

        (, uint256 sparseReadSecond, uint256 sparseChecksum) = _measureReadOps(sparseReadDemo, sparseSlot1, sparseSlot2);
        (, uint256 recordReadSecond, uint256 recordChecksum) = _measureReadOps(recordReadDemo, recordSlotA, recordSlotB);

        assertEq(sparseChecksum, 0, "different-key mapping read checksum");
        assertEq(recordChecksum, 0, "same-entry record read checksum");
        assertEq(
            sparseReadSecond - recordReadSecond, READ_PAGE_DISCOUNT, "same-entry record fields should share a read page"
        );

        Mip8StorageDemo sparseWriteDemo = new Mip8StorageDemo();
        uint256 sparseWriteSlot1 = sparseWriteDemo.sparseSlot(1);
        uint256 sparseWriteSlot2 = sparseWriteDemo.sparseSlot(2);
        (, uint256 sparseWriteSecond) = _measureWriteOps(sparseWriteDemo, sparseWriteSlot1, sparseWriteSlot2, 50, 60);

        Mip8StorageDemo recordWriteDemo = new Mip8StorageDemo();
        (uint256 recordWriteSlotA, uint256 recordWriteSlotB) = recordWriteDemo.recordSlots(1);
        (, uint256 recordWriteSecond) = _measureWriteOps(recordWriteDemo, recordWriteSlotA, recordWriteSlotB, 70, 80);

        assertEq(
            sparseWriteSecond - recordWriteSecond,
            COLD_PAGE_WRITE_COST,
            "same-entry record fields should share a write page"
        );
    }

    function test_seededSlotsChargePageWriteOncePerPage() public {
        Mip8StorageDemo adjacent = new Mip8StorageDemo();
        vm.store(address(adjacent), bytes32(uint256(0)), bytes32(uint256(11)));
        vm.store(address(adjacent), bytes32(uint256(1)), bytes32(uint256(22)));

        Mip8StorageDemo far = new Mip8StorageDemo();
        vm.store(address(far), bytes32(uint256(0)), bytes32(uint256(11)));
        vm.store(address(far), bytes32(uint256(PAGE_CROSSING_INDEX)), bytes32(uint256(33)));

        (uint256 adjacentFirst, uint256 adjacentSecond) = _measureWriteOps(adjacent, 0, 1, 111, 222);
        (uint256 farFirst, uint256 farSecond) = _measureWriteOps(far, 0, PAGE_CROSSING_INDEX, 111, 333);

        assertEq(adjacentFirst, farFirst, "first clean write should cost the same on each cold page");
        assertEq(
            farSecond - adjacentSecond, PAGE_WRITE_COST, "same-page clean writes should only charge the page write once"
        );
    }

    function test_dirtyRewriteFallsBackToBaseCost() public {
        Mip8StorageDemo demo = new Mip8StorageDemo();
        vm.store(address(demo), bytes32(uint256(0)), bytes32(uint256(11)));

        (uint256 first, uint256 second) = _measureWriteOps(demo, 0, 0, 111, 222);

        assertEq(first - second, PAGE_WRITE_COST, "dirty rewrite should drop the first-page-write charge");
    }

    function test_zeroToNonzeroToZeroFallsBackToBaseCost() public {
        Mip8StorageDemo demo = new Mip8StorageDemo();

        (uint256 first, uint256 second) = _measureWriteOps(demo, 0, 0, 111, 0);

        assertEq(second, BASE_WRITE_GAS, "zero restoration should only pay the base cost");
        assertEq(
            first - second,
            READ_PAGE_DISCOUNT + PAGE_WRITE_COST + STATE_GROWTH_COST,
            "new value should pay read, page write, and state-growth costs"
        );
    }

    function test_restoringClearedSlotDoesNotRechargeGrowth() public {
        Mip8StorageDemo restored = new Mip8StorageDemo();
        vm.store(address(restored), bytes32(uint256(0)), bytes32(uint256(11)));

        (, uint256 restoreGas) = _measureWriteOps(restored, 0, 0, 0, 222);

        Mip8StorageDemo fresh = new Mip8StorageDemo();
        (, uint256 newSlotGas) = _measureWriteOps(fresh, 0, 1, 111, 222);

        assertEq(restoreGas, BASE_WRITE_GAS, "restoring a cleared slot should only pay base cost");
        assertEq(
            newSlotGas - restoreGas, STATE_GROWTH_COST, "restoring a cleared slot should not recharge state growth"
        );
    }
}

contract MonadNineMip8RegressionTest is Mip8PagifiedStateTestBase {
    function test_readsDoNotWarmByPageBeforeMonadTen() public {
        Mip8StorageDemo adjacent = new Mip8StorageDemo();
        Mip8StorageDemo far = new Mip8StorageDemo();

        (, uint256 adjacentSecond,) = _measureReadOps(adjacent, 0, 1);
        (, uint256 farSecond,) = _measureReadOps(far, 0, PAGE_CROSSING_INDEX);

        assertEq(farSecond, adjacentSecond, "MonadNine must retain per-slot read pricing");
    }

    function test_writesDoNotWarmByPageBeforeMonadTen() public {
        Mip8StorageDemo adjacent = new Mip8StorageDemo();
        Mip8StorageDemo far = new Mip8StorageDemo();

        (, uint256 adjacentSecond) = _measureWriteOps(adjacent, 0, 1, 1, 2);
        (, uint256 farSecond) = _measureWriteOps(far, 0, PAGE_CROSSING_INDEX, 1, 2);

        assertEq(farSecond, adjacentSecond, "MonadNine must retain per-slot write pricing");
    }
}
