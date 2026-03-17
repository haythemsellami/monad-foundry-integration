// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

contract PagifiedStateDemo {
    uint256 internal constant DENSE_BASE_SLOT = 0;
    uint256 internal constant SPARSE_ROOT_SLOT = 256;
    uint256 internal constant RECORD_ROOT_SLOT = 257;

    struct Pair {
        uint256 a;
        uint256 b;
    }

    uint256[256] internal dense;
    mapping(uint256 => uint256) internal sparse;
    mapping(uint256 => Pair) internal records;

    function seedDense(uint256 index, uint256 value) external {
        dense[index] = value;
    }

    function seedSparse(uint256 key, uint256 value) external {
        sparse[key] = value;
    }

    function seedRecord(uint256 key, uint256 a, uint256 b) external {
        records[key] = Pair({a: a, b: b});
    }

    function denseSlot(uint256 index) external pure returns (uint256) {
        return DENSE_BASE_SLOT + index;
    }

    function sparseSlot(uint256 key) external pure returns (uint256 slot) {
        return _mappingSlot(key, SPARSE_ROOT_SLOT);
    }

    function recordSlots(uint256 key) external pure returns (uint256 first, uint256 second) {
        first = _mappingSlot(key, RECORD_ROOT_SLOT);
        second = first + 1;
    }

    function measureRead(uint256 slotA, uint256 slotB)
        external
        view
        returns (uint256 first, uint256 second, uint256 checksum)
    {
        assembly {
            let before := gas()
            let a := sload(slotA)
            let afterFirst := gas()
            let b := sload(slotB)
            let afterSecond := gas()

            first := sub(before, afterFirst)
            second := sub(afterFirst, afterSecond)
            checksum := add(a, b)
        }
    }

    function measureWrite(uint256 slotA, uint256 slotB, uint256 valueA, uint256 valueB)
        external
        returns (uint256 first, uint256 second)
    {
        assembly {
            let before := gas()
            sstore(slotA, valueA)
            let afterFirst := gas()
            sstore(slotB, valueB)
            let afterSecond := gas()

            first := sub(before, afterFirst)
            second := sub(afterFirst, afterSecond)
        }
    }

    function _mappingSlot(uint256 key, uint256 rootSlot) internal pure returns (uint256 slot) {
        bytes32 hash = keccak256(abi.encode(key, rootSlot));
        slot = uint256(hash);
    }
}
