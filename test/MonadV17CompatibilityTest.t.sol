// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MonadVm} from "monad-std/MonadVm.sol";

interface IEvmVersionVm {
    function getEvmVersion() external pure returns (string memory evm);
    function setEvmVersion(string calldata evm) external;
}

contract VmSetEvmVersionMonadTest is Test {
    IEvmVersionVm constant evm = IEvmVersionVm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
    address constant CLZ_TARGET = address(uint160(0x0c17));

    function setUp() public {
        // CLZ (0x1e) is available in MonadNine/MonadNext and unavailable in MonadEight.
        vm.etch(CLZ_TARGET, hex"60011e60005260206000f3");
    }

    function test_setEvmVersion_switchesBetweenMonadHardforks() public {
        evm.setEvmVersion("MonadEight");
        assertEq(evm.getEvmVersion(), "monadeight");
        (bool ok,) = _callClzProbe();
        assertFalse(ok, "CLZ must be unavailable on MonadEight");

        evm.setEvmVersion("MonadNine");
        assertEq(evm.getEvmVersion(), "monadnine");
        bytes memory ret;
        (ok, ret) = _callClzProbe();
        assertTrue(ok, "CLZ must be available on MonadNine");
        assertEq(abi.decode(ret, (uint256)), 255);
    }

    function test_setEvmVersion_acceptsNamespacedMonadHardforks() public {
        evm.setEvmVersion("monad:MonadEight");
        assertEq(evm.getEvmVersion(), "monadeight");
        (bool ok,) = _callClzProbe();
        assertFalse(ok, "namespaced MonadEight should disable CLZ");

        evm.setEvmVersion("m:MonadNext");
        assertEq(evm.getEvmVersion(), "monadnext");
        bytes memory ret;
        (ok, ret) = _callClzProbe();
        assertTrue(ok, "m:MonadNext should enable CLZ");
        assertEq(abi.decode(ret, (uint256)), 255);
    }

    function test_setEvmVersion_acceptsEthereumNamesButStaysInMonadFamily() public {
        evm.setEvmVersion("MonadEight");
        assertEq(evm.getEvmVersion(), "monadeight");

        evm.setEvmVersion("shanghai");

        // Ethereum EVM names are accepted for compatibility but map through Monad's
        // default execution hardfork instead of switching the executor to Ethereum.
        assertEq(evm.getEvmVersion(), "monadten");
        (bool ok, bytes memory ret) = _callClzProbe();
        assertTrue(ok, "Ethereum EVM aliases must keep execution in a Monad hardfork");
        assertEq(abi.decode(ret, (uint256)), 255);
    }

    function test_setEvmVersion_rejectsForeignNetworkHardfork() public {
        (bool ok,) = address(evm).call(abi.encodeWithSelector(IEvmVersionVm.setEvmVersion.selector, "tempo:T3"));

        assertFalse(ok, "foreign network hardfork names must be rejected in Monad mode");
    }

    function _callClzProbe() internal view returns (bool ok, bytes memory ret) {
        return CLZ_TARGET.staticcall(hex"");
    }
}

contract GasReportSubject {
    uint256 public value;

    function touchStorage(uint256 next) external returns (uint256 previous) {
        previous = value;
        value = next;
    }
}

contract GasReportMonadCheatcodeTest is Test {
    MonadVm constant monad = MonadVm(0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA);
    GasReportSubject subject;

    function setUp() public {
        subject = new GasReportSubject();
    }

    function test_monadCheatcodeCallsDoNotHideUserContractGas() public {
        subject.touchStorage(1);
        monad.setEpoch(17, false);
        subject.touchStorage(2);

        assertEq(subject.value(), 2);
    }
}
