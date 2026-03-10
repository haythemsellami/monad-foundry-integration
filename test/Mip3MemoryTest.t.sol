// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/// @title Mip3MemoryTest
/// @notice MIP-3 linear memory cost model integration tests.
/// @dev Run under two profiles:
///      - FOUNDRY_PROFILE=monad_nine forge test --match-contract MonadNine
///      - FOUNDRY_PROFILE=monad_eight forge test --match-contract MonadEight
///
///      MIP-3 spec (MonadNine+):
///        memory_cost(num_words) = num_words / 2
///        8 MB (262,144 words) pooled cap across the call stack
///
///      MonadEight uses upstream REVM quadratic formula (3*n + n^2/512).

// =============================================================================
// MonadNine: Exact MIP-3 Assertions
// =============================================================================

contract MonadNineMip3Test is Test {
    // MIP-3 constants
    uint256 constant MEMORY_LIMIT = 8 * 1024 * 1024; // 8 MB

    // -------------------------------------------------------------------------
    // Linear memory pricing (MSTORE)
    // -------------------------------------------------------------------------

    /// @notice Stepped expansion: expand from A to B, measure the delta.
    /// @dev We first expand memory to a known baseline, then measure two
    ///      equal-sized expansions. Both deltas must be identical under
    ///      the linear model. This avoids depending on Solidity's initial
    ///      free memory pointer or absolute PUSH opcode costs.
    function test_LinearMemoryCost_SteppedExpansion() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Pre-expand to 4096 bytes to establish a stable baseline
        // (clears Solidity's free-pointer overhead from the measurement).
        assembly { mstore(4064, 0) }

        // Step 1: expand from 4096 to 8192 (delta = 4096 bytes = 128 words)
        assembly {
            gasBefore := gas()
            mstore(8160, 0)
            gasAfter := gas()
        }
        uint256 step1Cost = gasBefore - gasAfter;

        // Step 2: expand from 8192 to 12288 (delta = 4096 bytes = 128 words)
        assembly {
            gasBefore := gas()
            mstore(12256, 0)
            gasAfter := gas()
        }
        uint256 step2Cost = gasBefore - gasAfter;

        console.log("Step 1 (4K -> 8K) cost:", step1Cost);
        console.log("Step 2 (8K -> 12K) cost:", step2Cost);

        // Under linear model, equal-sized expansions cost the same.
        // Both should be: MSTORE(3) + memory_delta(128/2 = 64) + PUSH overhead
        assertEq(step1Cost, step2Cost, "Linear model: equal-sized steps must cost the same");
    }

    /// @notice Verify the delta between two expansions matches `words/2`.
    /// @dev Expand from 4 KB to 8 KB (delta = 128 words), then from 8 KB to 16 KB
    ///      (delta = 256 words). The second expansion's memory component should be
    ///      exactly 2x the first, since 256/2 = 128 vs 128/2 = 64.
    function test_LinearMemoryCost_ProportionalDeltas() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Pre-expand to 4 KB
        assembly { mstore(4064, 0) }

        // Expand to 8 KB: delta = 128 words, memory cost delta = 64
        assembly {
            gasBefore := gas()
            mstore(8160, 0)
            gasAfter := gas()
        }
        uint256 cost4to8 = gasBefore - gasAfter;

        // Expand to 16 KB: delta = 256 words, memory cost delta = 128
        assembly {
            gasBefore := gas()
            mstore(16352, 0)
            gasAfter := gas()
        }
        uint256 cost8to16 = gasBefore - gasAfter;

        console.log("Cost 4K->8K:", cost4to8);
        console.log("Cost 8K->16K:", cost8to16);

        // The MSTORE static gas and PUSH overhead are the same in both.
        // So the difference is purely memory: 128 - 64 = 64 gas.
        uint256 delta = cost8to16 - cost4to8;
        assertEq(delta, 64, "Doubling expansion size adds exactly 64 gas (128 words / 2)");
    }

    // -------------------------------------------------------------------------
    // 8 MB cap
    // -------------------------------------------------------------------------

    /// @notice Near-8 MB allocation succeeds.
    /// @dev Allocates 8 MB - 4 KB. The 4 KB headroom accounts for the child
    ///      contract's Solidity overhead (ABI decoding, free pointer). This is
    ///      a deliberate approximation, not an exact boundary proof.
    function test_Near8MB_Succeeds() public {
        MemoryAllocator allocator = new MemoryAllocator();
        // 8 MB - 4 KB headroom for child's Solidity overhead
        uint256 size = MEMORY_LIMIT - 4096;
        (bool ok,) = address(allocator).call(abi.encodeCall(MemoryAllocator.allocateRaw, (size)));
        assertTrue(ok, "Near-8 MB allocation must succeed");
    }

    /// @notice 8 MB + 32 bytes always reverts (exceeds pooled cap).
    function test_8MB_Plus32_Reverts() public {
        MemoryAllocator allocator = new MemoryAllocator();
        (bool ok,) = address(allocator).call(abi.encodeCall(MemoryAllocator.allocateRaw, (MEMORY_LIMIT + 32)));
        assertFalse(ok, "8 MB + 32 must revert (MemoryLimitOOG)");
    }

    // -------------------------------------------------------------------------
    // Pooled parent/child cap
    // -------------------------------------------------------------------------

    /// @notice Parent near limit, small child succeeds.
    function test_PooledCap_SmallChildSucceeds() public {
        PooledCapTester tester = new PooledCapTester();
        // Parent uses 6 MB, child uses 512 KB — well within the 8 MB cap
        (bool ok,) =
            address(tester).call(abi.encodeCall(PooledCapTester.parentThenChild, (6 * 1024 * 1024, 512 * 1024)));
        assertTrue(ok, "Child 512 KB should succeed (parent used 6 MB)");
    }

    /// @notice Parent near limit, large child fails.
    function test_PooledCap_LargeChildFails() public {
        PooledCapTester tester = new PooledCapTester();
        // Parent uses 7 MB, child tries 2 MB — exceeds the 8 MB cap
        bool childOk = tester.parentThenChildExpectFailure(7 * 1024 * 1024, 2 * 1024 * 1024);
        assertFalse(childOk, "Child 2 MB should fail (parent used 7 MB, only ~1 MB remains)");
    }

    /// @notice Child memory release: two sibling calls of the same size both succeed.
    /// @dev SharedMemory checkpoint is restored between child calls, so the second
    ///      sibling gets the same budget as the first.
    function test_SiblingChildMemoryRelease() public {
        MemoryAllocator child1 = new MemoryAllocator();
        MemoryAllocator child2 = new MemoryAllocator();

        // Each child allocates 4 MB. Sequentially, both should succeed
        // because child1's memory is released before child2 runs.
        uint256 childSize = 4 * 1024 * 1024;

        (bool ok1,) = address(child1).call(abi.encodeCall(MemoryAllocator.allocateRaw, (childSize)));
        assertTrue(ok1, "First child 4 MB must succeed");

        (bool ok2,) = address(child2).call(abi.encodeCall(MemoryAllocator.allocateRaw, (childSize)));
        assertTrue(ok2, "Second child 4 MB must succeed (first child's memory released)");
    }

    // -------------------------------------------------------------------------
    // MCOPY canary
    // -------------------------------------------------------------------------

    /// @notice MCOPY with dst >> src triggers memory expansion at dst.
    function test_Mcopy_DstExpansion() public {
        // Set up source data at offset 0
        assembly { mstore(0, 0xdeadbeef) }

        // MCOPY: copy 32 bytes from src=0 to dst=4096
        // Memory expands to max(dst, src) + len = 4096 + 32 = 4128
        assembly { mcopy(4096, 0, 32) }

        // Verify the data was actually copied
        bytes32 result;
        assembly { result := mload(4096) }
        assertEq(uint256(result), 0xdeadbeef, "MCOPY must copy data to high dst");
    }

    /// @notice MCOPY with src >> dst triggers memory expansion at src.
    function test_Mcopy_SrcExpansion() public {
        // Place data at a high offset (src)
        assembly { mstore(4064, 0xcafebabe) }

        // MCOPY: copy 32 bytes from src=4064 to dst=0
        assembly { mcopy(0, 4064, 32) }

        bytes32 result;
        assembly { result := mload(0) }
        assertEq(uint256(result), 0xcafebabe, "MCOPY must copy data from high src to low dst");
    }

    // -------------------------------------------------------------------------
    // CREATE / CREATE2 canary
    // -------------------------------------------------------------------------

    /// @notice CREATE with initcode at a high offset forces memory expansion.
    function test_Create_MemoryExpansion() public {
        bool ok;
        assembly {
            // Initcode: PUSH1 0x00 PUSH1 0x00 RETURN = 0x60006000f3 (5 bytes)
            // Store at offset 4064 → memory expands to 4096 bytes
            mstore(4064, shl(216, 0x60006000f3))
            ok := iszero(iszero(create(0, 4064, 5)))
        }
        assertTrue(ok, "CREATE with high-offset initcode must succeed");
    }

    /// @notice CREATE2 with initcode at a high offset forces memory expansion.
    function test_Create2_MemoryExpansion() public {
        bool ok;
        assembly {
            // Store at offset 8160 → memory expands to 8192 bytes
            mstore(8160, shl(216, 0x60006000f3))
            ok := iszero(iszero(create2(0, 8160, 5, 42)))
        }
        assertTrue(ok, "CREATE2 with high-offset initcode must succeed");
    }

    // -------------------------------------------------------------------------
    // KECCAK256 canary
    // -------------------------------------------------------------------------

    /// @notice KECCAK256 over a large range forces memory expansion.
    function test_Keccak256_MemoryExpansion() public {
        bytes32 hash;
        assembly {
            // Hash 4096 bytes starting at offset 0 → expands to 128 words
            hash := keccak256(0, 4096)
        }
        assertTrue(uint256(hash) != 0, "KECCAK256 must return a hash");
    }

    // -------------------------------------------------------------------------
    // RETURN canary
    // -------------------------------------------------------------------------

    /// @notice RETURN with large return data forces memory expansion inside callee.
    function test_Return_MemoryExpansion() public {
        ReturnAllocator ra = new ReturnAllocator();
        (bool ok, bytes memory data) = address(ra).call(abi.encodeCall(ReturnAllocator.returnLargeData, (4096)));
        assertTrue(ok, "RETURN with 4096-byte payload must succeed");
        // ABI encoding: 32 bytes offset + 32 bytes length + 4096 bytes data
        // abi.decode strips the envelope, so we get the inner bytes.
        bytes memory decoded = abi.decode(data, (bytes));
        assertEq(decoded.length, 4096, "Decoded return data must be 4096 bytes");
    }
}

// =============================================================================
// MonadEight: Hardfork-Gating Semantics
// =============================================================================

contract MonadEightMip3RegressionTest is Test {
    /// @notice Over-8 MB allocation succeeds on MonadEight (cap not active).
    function test_Over8MB_Succeeds_NoCap() public {
        MemoryAllocator allocator = new MemoryAllocator();
        // Allocate 9 MB — should succeed because the 8 MB cap is MonadNine+ only
        uint256 size = 9 * 1024 * 1024;
        (bool ok,) = address(allocator).call{gas: 200_000_000}(abi.encodeCall(MemoryAllocator.allocateRaw, (size)));
        assertTrue(ok, "9 MB allocation must succeed on MonadEight (no MIP-3 cap)");
    }
}

// =============================================================================
// Differential: Same test runnable under both profiles
// =============================================================================

/// @notice Gas probe contract for differential comparison.
/// @dev Run the same test under monad_eight and monad_nine profiles.
///      MonadEight (quadratic) should cost more than MonadNine (linear)
///      for large memory expansions.
contract Mip3DifferentialTest is Test {
    /// @notice Measure gas for a 1 MB MSTORE expansion.
    /// @dev Under MonadEight (quadratic): much more expensive.
    ///      Under MonadNine (linear): 1 MB = 32768 words, cost = 16384.
    function test_Differential_LargeMstore() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Pre-expand to 4 KB to clear Solidity overhead
        assembly { mstore(4064, 0) }

        // Expand to 1 MB
        assembly {
            gasBefore := gas()
            mstore(sub(0x100000, 32), 0)
            gasAfter := gas()
        }
        uint256 cost = gasBefore - gasAfter;
        console.log("1 MB MSTORE expansion cost:", cost);
        // No assertion — the wrapper script compares across profiles
    }

    /// @notice Measure gas for a large MCOPY expansion.
    function test_Differential_LargeMcopy() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Set up source at offset 0
        assembly { mstore(0, 0xdeadbeef) }

        // MCOPY: copy 32 bytes to dst = 1 MB, forcing expansion
        assembly {
            gasBefore := gas()
            mcopy(0x100000, 0, 32)
            gasAfter := gas()
        }
        uint256 cost = gasBefore - gasAfter;
        console.log("1 MB MCOPY expansion cost:", cost);
    }

    /// @notice Measure total gas for CREATE2 including memory expansion.
    /// @dev The memory expansion happens on the mstore that places initcode.
    ///      We measure both together to capture the full cost difference.
    function test_Differential_HighOffsetCreate2() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Pre-expand to 4 KB to clear Solidity overhead
        assembly { mstore(4064, 0) }

        assembly {
            // Initcode at offset ~512 KB — this mstore forces the expansion
            let offset := sub(0x80000, 32)

            gasBefore := gas()
            mstore(offset, shl(216, 0x60006000f3))
            pop(create2(0, offset, 5, 0x1234))
            gasAfter := gas()
        }
        uint256 cost = gasBefore - gasAfter;
        console.log("512 KB CREATE2 (with expansion) cost:", cost);
    }
}

// =============================================================================
// Helper Contracts
// =============================================================================

/// @notice Allocates memory to a given size using inline assembly.
/// @dev Both functions use ABI decoding (normal Solidity external functions),
///      so the child contract consumes some memory for its own overhead
///      (free pointer, ABI decoder). Cap tests account for this with headroom.
contract MemoryAllocator {
    /// @notice Expand memory to `size` bytes.
    function allocate(uint256 size) external pure {
        assembly {
            mstore(sub(size, 32), 0)
        }
    }

    /// @notice Expand memory to `size` bytes (same as allocate).
    function allocateRaw(uint256 size) external pure {
        assembly {
            // Touch the last word to force expansion to `size` bytes
            mstore(sub(size, 32), 0)
        }
    }
}

/// @notice Tests parent + child memory pooling.
contract PooledCapTester {
    /// @notice Parent allocates parentSize, then calls child to allocate childSize.
    function parentThenChild(uint256 parentSize, uint256 childSize) external {
        // Parent expansion
        assembly { mstore(sub(parentSize, 32), 0) }

        // Child call
        MemoryAllocator child = new MemoryAllocator();
        child.allocateRaw(childSize);
    }

    /// @notice Parent allocates, child tries to allocate — returns whether child succeeded.
    function parentThenChildExpectFailure(uint256 parentSize, uint256 childSize) external returns (bool childOk) {
        // Parent expansion
        assembly { mstore(sub(parentSize, 32), 0) }

        // Child call via low-level call so parent survives the revert
        MemoryAllocator child = new MemoryAllocator();
        (childOk,) = address(child).call(abi.encodeCall(MemoryAllocator.allocateRaw, (childSize)));
    }
}

/// @notice Executes non-allocator memory-expanding opcode canaries over RPC.
contract RpcOpcodeCanary {
    address public lastCreate2;
    bool public lastCreate2Ok;

    /// @notice Run CREATE2 with initcode placed at a high memory offset.
    /// @dev Expands memory to ~512 KB before executing CREATE2.
    function create2HighOffset() external returns (address created) {
        assembly {
            let offset := sub(0x80000, 32)
            mstore(offset, shl(216, 0x60006000f3))
            created := create2(0, offset, 5, 0x1234)
        }

        lastCreate2 = created;
        lastCreate2Ok = created != address(0);
    }
}

/// @notice Returns a buffer of `size` zero bytes.
contract ReturnAllocator {
    function returnLargeData(uint256 size) external pure returns (bytes memory) {
        bytes memory data = new bytes(size);
        return data;
    }
}
