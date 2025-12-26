// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title OpcodesAndPrecompilesGasPricing - Contract for measuring Monad gas costs
/// @notice Deploy this and call methods via anvil to measure gas
/// @dev Tests:
///      - Opcodes affected by Monad's cold access pricing
///      - Precompiles with Monad-specific gas costs
contract OpcodesAndPrecompilesGasPricing {
    // Storage slots for SLOAD/SSTORE testing
    mapping(uint256 => uint256) public data;

    constructor() {
        // Pre-populate some slots
        data[1] = 100;
        data[2] = 200;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE ACCESS OPCODES (Cold: 8100 gas)
    // Cold storage = (contract, slot) pair not accessed yet in this tx
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Read a storage slot - measures SLOAD gas
    /// @dev Use a unique key to ensure cold storage access (slot not touched in this tx)
    function testSLOAD(uint256 key) external view returns (uint256) {
        return data[key];
    }

    /// @notice Write to a storage slot - measures SSTORE gas
    /// @dev Use a unique key to ensure cold storage access (slot not touched in this tx)
    function testSSTORE(uint256 key, uint256 value) external {
        data[key] = value;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACCOUNT ACCESS OPCODES (Cold: 10100 gas)
    // Cold account = address not accessed yet in this tx
    // Account includes: balance, nonce, code, storage root
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get balance of an address - measures BALANCE opcode
    /// @dev Use a fresh address to ensure cold account access
    function testBALANCE(address target) external view returns (uint256) {
        return target.balance;
    }

    /// @notice Get code size - measures EXTCODESIZE opcode
    /// @dev Use a fresh address to ensure cold account access
    function testEXTCODESIZE(address target) external view returns (uint256) {
        uint256 size;
        assembly {
            size := extcodesize(target)
        }
        return size;
    }

    /// @notice Copy code to memory - measures EXTCODECOPY opcode
    /// @dev Use a fresh address to ensure cold account access
    function testEXTCODECOPY(address target) external view returns (bytes memory) {
        uint256 size;
        assembly {
            size := extcodesize(target)
        }
        bytes memory code = new bytes(size);
        assembly {
            extcodecopy(target, add(code, 0x20), 0, size)
        }
        return code;
    }

    /// @notice Get code hash - measures EXTCODEHASH opcode
    /// @dev Use a fresh address to ensure cold account access
    function testEXTCODEHASH(address target) external view returns (bytes32) {
        bytes32 hash;
        assembly {
            hash := extcodehash(target)
        }
        return hash;
    }

    /// @notice Call another address - measures CALL opcode
    /// @dev Use a fresh address to ensure cold account access
    function testCALL(address target) external returns (bool) {
        (bool success,) = target.call("");
        return success;
    }

    /// @notice Callcode to another address - measures CALLCODE opcode (deprecated)
    /// @dev Use a fresh address to ensure cold account access
    function testCALLCODE(address target) external returns (bool success) {
        assembly {
            success := callcode(gas(), target, 0, 0, 0, 0, 0)
        }
    }

    /// @notice Delegatecall to another address - measures DELEGATECALL opcode
    /// @dev Use a fresh address to ensure cold account access
    function testDELEGATECALL(address target) external returns (bool) {
        (bool success,) = target.delegatecall("");
        return success;
    }

    /// @notice Staticcall to another address - measures STATICCALL opcode
    /// @dev Use a fresh address to ensure cold account access
    function testSTATICCALL(address target) external view returns (bool) {
        (bool success,) = target.staticcall("");
        return success;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PRECOMPILES - Monad Gas Costs
    // | Precompile  | Address | Ethereum | Monad   | Multiplier |
    // |-------------|---------|----------|---------|------------|
    // | ecRecover   | 0x01    | 3,000    | 6,000   | 2x         |
    // | ecAdd       | 0x06    | 150      | 300     | 2x         |
    // | ecMul       | 0x07    | 6,000    | 30,000  | 5x         |
    // | ecPairing   | 0x08    | 45,000*  | 225,000*| 5x         |
    // | blake2f     | 0x09    | rounds×1 | rounds×2| 2x         |
    // | point eval  | 0x0a    | 50,000   | 200,000 | 4x         |
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Test ecRecover precompile (0x01)
    /// @dev Monad: 6000 gas, Ethereum: 3000 gas
    function testEcRecover() external view returns (address) {
        // Valid ecrecover input: hash + v + r + s
        bytes32 hash = 0x456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef3;
        uint8 v = 28;
        bytes32 r = 0x9242685bf161793cc25603c231bc2f568eb630ea16aa137d2664ac8038825608;
        bytes32 s = 0x4f8ae3bd7535248d0bd448298cc2e2071e56992d0774dc340c368ae950852ada;

        return ecrecover(hash, v, r, s);
    }

    /// @notice Test ecAdd precompile (0x06) - BN254 curve point addition
    /// @dev Monad: 300 gas, Ethereum: 150 gas
    function testEcAdd() external view returns (bytes memory) {
        // Two valid points on BN254 curve (generator point P and 2P)
        bytes memory input = hex"0000000000000000000000000000000000000000000000000000000000000001"
                             hex"0000000000000000000000000000000000000000000000000000000000000002"
                             hex"030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3"
                             hex"15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4";

        (bool success, bytes memory result) = address(0x06).staticcall(input);
        require(success, "ecAdd failed");
        return result;
    }

    /// @notice Test ecMul precompile (0x07) - BN254 curve scalar multiplication
    /// @dev Monad: 30000 gas, Ethereum: 6000 gas
    function testEcMul() external view returns (bytes memory) {
        // Generator point G and scalar 2
        bytes memory input = hex"0000000000000000000000000000000000000000000000000000000000000001"
                             hex"0000000000000000000000000000000000000000000000000000000000000002"
                             hex"0000000000000000000000000000000000000000000000000000000000000002";

        (bool success, bytes memory result) = address(0x07).staticcall(input);
        require(success, "ecMul failed");
        return result;
    }

    /// @notice Test ecPairing precompile (0x08) - BN254 pairing check
    /// @dev Monad: 225000 base + 170000 per point, Ethereum: 45000 + 34000
    /// @dev Uses 1 point pair for testing
    function testEcPairing() external view returns (bool) {
        // Single pairing with point at infinity (simplest valid input)
        // G1 point at infinity (0,0) + valid G2 point
        bytes memory input = hex"0000000000000000000000000000000000000000000000000000000000000000"
                             hex"0000000000000000000000000000000000000000000000000000000000000000"
                             hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
                             hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
                             hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
                             hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa";

        (bool success, bytes memory result) = address(0x08).staticcall(input);
        require(success, "ecPairing failed");

        // Result is 32 bytes, 1 if pairing check passed, 0 otherwise
        return result.length == 32 && result[31] == 0x01;
    }

    /// @notice Test blake2f precompile (0x09) - BLAKE2 compression function
    /// @dev Monad: rounds × 2, Ethereum: rounds × 1
    /// @dev Using 12 rounds for testing
    function testBlake2f() external view returns (bytes memory) {
        // Blake2f input: 4 bytes rounds + 64 bytes h + 128 bytes m + 8 bytes t[0] + 8 bytes t[1] + 1 byte f
        // Using 12 rounds (0x0000000c)
        bytes memory input = hex"0000000c"  // 12 rounds
                             hex"48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5"
                             hex"d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b"
                             hex"6162630000000000000000000000000000000000000000000000000000000000"
                             hex"0000000000000000000000000000000000000000000000000000000000000000"
                             hex"0000000000000000000000000000000000000000000000000000000000000000"
                             hex"0000000000000000000000000000000000000000000000000000000000000000"
                             hex"0300000000000000"  // t[0]
                             hex"0000000000000000"  // t[1]
                             hex"01";  // f (final block)

        (bool success, bytes memory result) = address(0x09).staticcall(input);
        require(success, "blake2f failed");
        return result;
    }
}
