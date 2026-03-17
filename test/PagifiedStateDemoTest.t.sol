// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PagifiedStateDemo} from "src/PagifiedStateDemo.sol";

contract MonadNextPagifiedStateDemoTest is Test {
    uint256 internal constant PAGE_CROSSING_INDEX = 128;
    uint256 internal constant READ_PAGE_DISCOUNT = 8000;
    uint256 internal constant WRITE_PAGE_DISCOUNT = 8100;

    function test_denseArrayReadsWarmByPage() public {
        PagifiedStateDemo adjacent = new PagifiedStateDemo();
        vm.store(address(adjacent), bytes32(uint256(0)), bytes32(uint256(11)));
        vm.store(address(adjacent), bytes32(uint256(1)), bytes32(uint256(22)));

        PagifiedStateDemo far = new PagifiedStateDemo();
        vm.store(address(far), bytes32(uint256(0)), bytes32(uint256(11)));
        vm.store(address(far), bytes32(uint256(PAGE_CROSSING_INDEX)), bytes32(uint256(33)));

        (uint256 adjacentFirst, uint256 adjacentSecond, uint256 adjacentChecksum) = _measureReadOps(adjacent, 0, 1);
        (uint256 farFirst, uint256 farSecond, uint256 farChecksum) =
            _measureReadOps(far, 0, PAGE_CROSSING_INDEX);

        console.log("MonadNext dense read gas, first slot:", adjacentFirst);
        console.log("MonadNext dense read gas, second slot same page:", adjacentSecond);
        console.log("MonadNext dense read gas, first far slot:", farFirst);
        console.log("MonadNext dense read gas, second far slot:", farSecond);

        assertEq(adjacentChecksum, 33, "same-page dense read checksum");
        assertEq(farChecksum, 44, "different-page dense read checksum");
        assertEq(
            farSecond - adjacentSecond,
            READ_PAGE_DISCOUNT,
            "same-page second dense read should realize the page discount on MonadNext"
        );
    }

    function test_denseArrayWritesWarmByPage() public {
        PagifiedStateDemo adjacent = new PagifiedStateDemo();
        PagifiedStateDemo far = new PagifiedStateDemo();

        (uint256 adjacentFirst, uint256 adjacentSecond) = _measureWriteOps(adjacent, 0, 1, 1, 2);
        (uint256 farFirst, uint256 farSecond) = _measureWriteOps(far, 0, PAGE_CROSSING_INDEX, 1, 2);

        console.log("MonadNext dense write gas, first slot:", adjacentFirst);
        console.log("MonadNext dense write gas, second slot same page:", adjacentSecond);
        console.log("MonadNext dense write gas, first far slot:", farFirst);
        console.log("MonadNext dense write gas, second far slot:", farSecond);

        assertEq(
            farSecond - adjacentSecond,
            WRITE_PAGE_DISCOUNT,
            "same-page second dense write should realize the page discount on MonadNext"
        );
    }

    function test_mappingStructFieldsBenefitButDifferentKeysDoNot() public {
        PagifiedStateDemo sparseReadDemo = new PagifiedStateDemo();
        uint256 sparseSlot1 = sparseReadDemo.sparseSlot(1);
        uint256 sparseSlot2 = sparseReadDemo.sparseSlot(2);
        vm.store(address(sparseReadDemo), bytes32(sparseSlot1), bytes32(uint256(10)));
        vm.store(address(sparseReadDemo), bytes32(sparseSlot2), bytes32(uint256(20)));

        PagifiedStateDemo recordReadDemo = new PagifiedStateDemo();
        (uint256 recordSlotA, uint256 recordSlotB) = recordReadDemo.recordSlots(1);
        vm.store(address(recordReadDemo), bytes32(recordSlotA), bytes32(uint256(30)));
        vm.store(address(recordReadDemo), bytes32(recordSlotB), bytes32(uint256(40)));

        (, uint256 sparseReadSecond, uint256 sparseChecksum) = _measureReadOps(sparseReadDemo, sparseSlot1, sparseSlot2);
        (, uint256 recordReadSecond, uint256 recordChecksum) =
            _measureReadOps(recordReadDemo, recordSlotA, recordSlotB);

        console.log("MonadNext mapping read gas, different keys second slot:", sparseReadSecond);
        console.log("MonadNext mapping read gas, same entry second slot:", recordReadSecond);

        assertEq(sparseChecksum, 30, "different-key mapping read checksum");
        assertEq(recordChecksum, 70, "same-entry record read checksum");
        assertEq(
            sparseReadSecond - recordReadSecond,
            READ_PAGE_DISCOUNT,
            "different mapping keys should stay scattered while same-entry fields benefit"
        );

        PagifiedStateDemo sparseWriteDemo = new PagifiedStateDemo();
        uint256 sparseWriteSlot1 = sparseWriteDemo.sparseSlot(1);
        uint256 sparseWriteSlot2 = sparseWriteDemo.sparseSlot(2);
        (, uint256 sparseWriteSecond) = _measureWriteOps(sparseWriteDemo, sparseWriteSlot1, sparseWriteSlot2, 50, 60);

        PagifiedStateDemo recordWriteDemo = new PagifiedStateDemo();
        (uint256 recordWriteSlotA, uint256 recordWriteSlotB) = recordWriteDemo.recordSlots(1);
        (, uint256 recordWriteSecond) = _measureWriteOps(recordWriteDemo, recordWriteSlotA, recordWriteSlotB, 70, 80);

        console.log("MonadNext mapping write gas, different keys second slot:", sparseWriteSecond);
        console.log("MonadNext mapping write gas, same entry second slot:", recordWriteSecond);

        assertEq(
            sparseWriteSecond - recordWriteSecond,
            WRITE_PAGE_DISCOUNT,
            "same mapping entry fields should write cheaper than different mapping keys"
        );
    }

    function _measureReadOps(PagifiedStateDemo demo, uint256 slotA, uint256 slotB)
        internal
        returns (uint256 firstGas, uint256 secondGas, uint256 checksum)
    {
        (bool ok, bytes memory ret) = address(demo).call(abi.encodeCall(PagifiedStateDemo.measureRead, (slotA, slotB)));
        assertTrue(ok, "measureRead call should succeed");
        return abi.decode(ret, (uint256, uint256, uint256));
    }

    function _measureWriteOps(PagifiedStateDemo demo, uint256 slotA, uint256 slotB, uint256 valueA, uint256 valueB)
        internal
        returns (uint256 firstGas, uint256 secondGas)
    {
        (bool ok, bytes memory ret) =
            address(demo).call(abi.encodeCall(PagifiedStateDemo.measureWrite, (slotA, slotB, valueA, valueB)));
        assertTrue(ok, "measureWrite call should succeed");
        return abi.decode(ret, (uint256, uint256));
    }
}
