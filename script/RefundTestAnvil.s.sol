// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

/// @title RefundTestAnvil
/// @notice Script to test refund behavior on anvil with real transactions
/// @dev Run with:
///      1. Start anvil: anvil (standard) or anvil --monad (monad)
///      2. Run script: forge script script/RefundTestAnvil.s.sol --rpc-url http://localhost:8545 --broadcast
///
/// Expected results:
/// - Standard anvil: User gets refund, pays less than gas_used
/// - Monad anvil: No refund, user pays full gas cost
contract RefundTestAnvil is Script {
    function run() external {
        // Use anvil's default private key (account 0)
        uint256 privateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address sender = vm.addr(privateKey);

        console.log("=== REFUND TEST ON ANVIL ===");
        console.log("Sender:", sender);
        console.log("Sender balance:", sender.balance);

        vm.startBroadcast(privateKey);

        // Deploy storage contract
        StorageForRefund storage_ = new StorageForRefund();
        console.log("Storage contract deployed at:", address(storage_));

        // Set initial value (so clearing earns refund)
        storage_.setValue(1);
        console.log("Set value to 1");

        vm.stopBroadcast();

        // Record balance before clearing
        uint256 balanceBefore = sender.balance;
        console.log("Balance before clear:", balanceBefore);

        vm.startBroadcast(privateKey);

        // Clear storage (this earns 4800 refund in Ethereum, none in Monad)
        uint256 gasStart = gasleft();
        storage_.clearValue();
        uint256 gasEnd = gasleft();
        uint256 gasUsed = gasStart - gasEnd;

        vm.stopBroadcast();

        uint256 balanceAfter = sender.balance;
        uint256 balanceSpent = balanceBefore - balanceAfter;

        console.log("");
        console.log("=== RESULTS ===");
        console.log("Gas used (internal):", gasUsed);
        console.log("Balance before:", balanceBefore);
        console.log("Balance after:", balanceAfter);
        console.log("Balance spent:", balanceSpent);
        console.log("");
        console.log("If no refund (Monad): balance spent should equal tx cost");
        console.log("If refund (Ethereum): balance spent should be less");
    }
}

contract StorageForRefund {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function clearValue() external {
        value = 0;
    }
}
