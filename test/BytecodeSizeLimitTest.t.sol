// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OversizedContract} from "../src/LargeContract.sol";

contract BytecodeSizeLimitTest is Test {
    /// @notice Test deploying a contract that exceeds Ethereum's 24KB limit but is within Monad's 128KB limit
    function testDeployLargeEthereumContract() public {
        OversizedContract oversized = new OversizedContract();

        uint256 size = oversized.size();

        assertGt(size, 24576, "Contract should exceed Ethereum's 24KB limit");
    }
}
