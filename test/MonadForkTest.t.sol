// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/// @title MonadForkTest
/// @notice Tests that Monad gas costs and state are preserved when forking from mainnet
/// @dev Uses vm.createSelectFork to fork from https://rpc.monad.xyz at a specific block
contract MonadForkTest is Test {
    // Monad Gas Constants (must match exactly)
    uint256 constant MONAD_COLD_SLOAD_COST = 8100;
    uint256 constant MONAD_COLD_ACCOUNT_ACCESS_COST = 10100;
    uint256 constant WARM_ACCESS_COST = 100;

    // Measurement overhead differs by operation type:
    // - SLOAD: only pushes result to stack (19 gas overhead)
    // - Account access: pops address, pushes result (25 gas overhead)
    uint256 constant SLOAD_MEASUREMENT_OVERHEAD = 19;
    uint256 constant ACCOUNT_MEASUREMENT_OVERHEAD = 25;

    // Expected measured values (exact, no tolerance)
    uint256 constant EXPECTED_COLD_SLOAD_GAS = MONAD_COLD_SLOAD_COST + SLOAD_MEASUREMENT_OVERHEAD;
    uint256 constant EXPECTED_COLD_ACCOUNT_GAS = MONAD_COLD_ACCOUNT_ACCESS_COST + ACCOUNT_MEASUREMENT_OVERHEAD;
    uint256 constant EXPECTED_WARM_SLOAD_GAS = WARM_ACCESS_COST + SLOAD_MEASUREMENT_OVERHEAD;
    uint256 constant EXPECTED_WARM_ACCOUNT_GAS = WARM_ACCESS_COST + ACCOUNT_MEASUREMENT_OVERHEAD;

    // Monad mainnet RPC
    string constant MONAD_RPC_URL = "https://rpc.monad.xyz";

    // ShMonad vault address on Monad mainnet
    address constant SHMONAD_VAULT = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;

    // Known state at block 48800000
    uint256 constant FORK_BLOCK_NUMBER = 48800000;
    uint256 constant EXPECTED_TOTAL_ASSETS = 370749935274347246933536085;

    // Storage slot for testing (using a fresh slot each test)
    uint256 public storageSlot;

    uint256 forkId;

    function setUp() public {
        // Fork from Monad mainnet at specific block
        forkId = vm.createSelectFork(MONAD_RPC_URL, FORK_BLOCK_NUMBER);
    }

    // =========================================================================
    // STATE PRESERVATION TESTS
    // =========================================================================

    /// @notice Verify state is correctly preserved from mainnet fork
    /// @dev Checks ShMonad vault totalAssets() matches known value at fork block
    function test_fork_state_preserved() public {
        // Call totalAssets() on ShMonad vault
        (bool success, bytes memory data) = SHMONAD_VAULT.staticcall(
            abi.encodeWithSignature("totalAssets()")
        );

        assertTrue(success, "totalAssets() call failed");

        uint256 totalAssets = abi.decode(data, (uint256));

        console.log("ShMonad totalAssets:", totalAssets);
        console.log("Expected:", EXPECTED_TOTAL_ASSETS);

        assertEq(
            totalAssets,
            EXPECTED_TOTAL_ASSETS,
            "Fork state mismatch: totalAssets must match known value at fork block"
        );
    }

    /// @notice Verify we're on the correct fork block
    function test_fork_block_number() public view {
        assertEq(
            block.number,
            FORK_BLOCK_NUMBER,
            "Fork block number must match expected"
        );
    }

    // =========================================================================
    // GAS COST PRESERVATION TESTS
    // =========================================================================

    /// @notice Test cold SLOAD uses exact Monad cost (8100 + overhead)
    function test_fork_cold_sload_cost() public {
        uint256 gasBefore = gasleft();
        uint256 value = storageSlot;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, value) }

        uint256 gasUsed = gasBefore - gasAfter;

        console.log("Cold SLOAD gas on fork:", gasUsed);
        console.log("Expected:", EXPECTED_COLD_SLOAD_GAS);

        assertEq(
            gasUsed,
            EXPECTED_COLD_SLOAD_GAS,
            "Cold SLOAD must cost 8119 (8100 + 19 overhead)"
        );
    }

    /// @notice Test cold BALANCE uses exact Monad cost (10100 + overhead)
    function test_fork_cold_balance_cost() public {
        // Use address that hasn't been accessed in this tx
        address target = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "fork_balance"))))
        );

        uint256 gasBefore = gasleft();
        uint256 bal = target.balance;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, bal) }

        uint256 gasUsed = gasBefore - gasAfter;

        console.log("Cold BALANCE gas on fork:", gasUsed);
        console.log("Expected:", EXPECTED_COLD_ACCOUNT_GAS);

        assertEq(
            gasUsed,
            EXPECTED_COLD_ACCOUNT_GAS,
            "Cold BALANCE must cost 10125 (10100 + 25 overhead)"
        );
    }

    /// @notice Test warm access uses exact cost (100 + overhead)
    function test_fork_warm_access_cost() public {
        // First access (cold) - warm up the slot
        uint256 warmup = storageSlot;
        assembly { mstore(0, warmup) }

        // Second access should be warm
        uint256 gasBefore = gasleft();
        uint256 value = storageSlot;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, value) }

        uint256 gasUsed = gasBefore - gasAfter;

        console.log("Warm SLOAD gas on fork:", gasUsed);
        console.log("Expected:", EXPECTED_WARM_SLOAD_GAS);

        assertEq(
            gasUsed,
            EXPECTED_WARM_SLOAD_GAS,
            "Warm SLOAD must cost 119 (100 + 19 overhead)"
        );
    }

    /// @notice Test cold EXTCODESIZE uses exact Monad cost
    function test_fork_cold_extcodesize_cost() public {
        address target = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "fork_extcodesize"))))
        );

        uint256 gasBefore = gasleft();
        uint256 size = target.code.length;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, size) }

        uint256 gasUsed = gasBefore - gasAfter;

        console.log("Cold EXTCODESIZE gas on fork:", gasUsed);
        console.log("Expected:", EXPECTED_COLD_ACCOUNT_GAS);

        assertEq(
            gasUsed,
            EXPECTED_COLD_ACCOUNT_GAS,
            "Cold EXTCODESIZE must cost 10125 (10100 + 25 overhead)"
        );
    }

    /// @notice Test cold EXTCODEHASH uses exact Monad cost
    function test_fork_cold_extcodehash_cost() public {
        address target = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "fork_extcodehash"))))
        );

        uint256 gasBefore = gasleft();
        bytes32 hash = target.codehash;
        uint256 gasAfter = gasleft();

        assembly { mstore(0, hash) }

        uint256 gasUsed = gasBefore - gasAfter;

        console.log("Cold EXTCODEHASH gas on fork:", gasUsed);
        console.log("Expected:", EXPECTED_COLD_ACCOUNT_GAS);

        assertEq(
            gasUsed,
            EXPECTED_COLD_ACCOUNT_GAS,
            "Cold EXTCODEHASH must cost 10125 (10100 + 25 overhead)"
        );
    }

    /// @notice Test cold/warm difference is exactly 10000 (Monad) not 2500 (Ethereum)
    function test_fork_cold_warm_difference() public {
        address target = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, "fork_diff"))))
        );

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

        assertEq(
            difference,
            MONAD_COLD_ACCOUNT_ACCESS_COST - WARM_ACCESS_COST,
            "Cold/warm difference must be 10000 (Monad pricing)"
        );
    }
}
