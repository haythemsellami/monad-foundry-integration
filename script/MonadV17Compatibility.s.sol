// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

interface IScriptReserveBalance {
    function dippedIntoReserve() external returns (bool);
}

contract MonadScriptProbe {
    address constant RESERVE_BALANCE = address(0x0000000000000000000000000000000000001001);

    function requireReserveBalancePrecompile() external returns (bool) {
        (bool success, bytes memory ret) =
            RESERVE_BALANCE.call(abi.encodeWithSelector(IScriptReserveBalance.dippedIntoReserve.selector));

        require(success, "reserve call failed");
        require(ret.length == 32, "reserve return must be bool");
        require(!abi.decode(ret, (bool)), "clean script tx should not dip into reserve");

        return true;
    }
}

contract MonadReserveBalanceScript is Script {
    function run() external {
        vm.startBroadcast();

        MonadScriptProbe probe = new MonadScriptProbe();
        require(probe.requireReserveBalancePrecompile(), "probe failed");

        vm.stopBroadcast();
    }
}
