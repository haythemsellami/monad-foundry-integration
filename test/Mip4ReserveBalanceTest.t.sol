// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface IReserveBalance {
    function dippedIntoReserve() external returns (bool);
}

contract MonadNineMip4ReserveBalanceTest is Test {
    address constant RESERVE_BALANCE = address(0x0000000000000000000000000000000000001001);
    bytes4 constant DIPPED_INTO_RESERVE_SELECTOR = IReserveBalance.dippedIntoReserve.selector;

    function test_cleanCallReturnsFalse() public {
        (bool success, bytes memory ret) = RESERVE_BALANCE.call(abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR));

        assertTrue(success, "plain CALL should succeed");
        assertEq(ret.length, 32, "success path should ABI-encode a bool");
        assertFalse(abi.decode(ret, (bool)), "clean transaction should not be in violation");
    }

    function test_staticcallRejected() public view {
        (bool success, bytes memory ret) =
            RESERVE_BALANCE.staticcall(abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR));

        assertFalse(success, "STATICCALL must be rejected");
        assertEq(ret.length, 0, "STATICCALL rejection should have empty returndata");
    }

    function test_delegatecallRejected() public {
        (bool success, bytes memory ret) =
            RESERVE_BALANCE.delegatecall(abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR));

        assertFalse(success, "DELEGATECALL must be rejected");
        assertEq(ret.length, 0, "DELEGATECALL rejection should have empty returndata");
    }

    function test_callcodeRejected() public {
        ReserveBalanceCaller caller = new ReserveBalanceCaller();
        bool success = caller.callViaCallcode(abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR));
        assertFalse(success, "CALLCODE must be rejected");
    }

    function test_staticContextPropagationRejected() public {
        ReserveBalanceCaller caller = new ReserveBalanceCaller();

        (bool outerSuccess, bytes memory ret) = address(caller)
            .staticcall(
                abi.encodeCall(ReserveBalanceCaller.forwardCall, (abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR)))
            );

        assertTrue(outerSuccess, "outer STATICCALL to helper should succeed");
        (bool innerSuccess, bytes memory innerRet) = abi.decode(ret, (bool, bytes));
        assertFalse(innerSuccess, "inner CALL should inherit static context and fail");
        assertEq(innerRet.length, 0, "static-context rejection should have empty returndata");
    }

    function test_shortInputHitsFallback() public {
        (bool success, bytes memory ret) = RESERVE_BALANCE.call(hex"deadbe");

        assertFalse(success, "short calldata must revert");
        assertEq(string(ret), "method not supported");
    }

    function test_unknownSelectorHitsFallback() public {
        (bool success, bytes memory ret) = RESERVE_BALANCE.call(hex"deadbeef");

        assertFalse(success, "unknown selector must revert");
        assertEq(string(ret), "method not supported");
    }

    function test_nonzeroValueRejected() public {
        vm.deal(address(this), 1);

        (bool success, bytes memory ret) =
            RESERVE_BALANCE.call{value: 1}(abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR));

        assertFalse(success, "nonzero value must be rejected");
        assertEq(string(ret), "value is nonzero");
    }

    function test_extraInputRejected() public {
        (bool success, bytes memory ret) =
            RESERVE_BALANCE.call(abi.encodePacked(DIPPED_INTO_RESERVE_SELECTOR, bytes1(0x01)));

        assertFalse(success, "extra calldata must revert");
        assertEq(string(ret), "input is invalid");
    }
}

contract MonadEightMip4RegressionTest is Test {
    address constant RESERVE_BALANCE = address(0x0000000000000000000000000000000000001001);
    bytes4 constant DIPPED_INTO_RESERVE_SELECTOR = IReserveBalance.dippedIntoReserve.selector;

    function test_precompileAbsentBeforeMonadNine() public {
        (bool success, bytes memory ret) = RESERVE_BALANCE.call(abi.encodeWithSelector(DIPPED_INTO_RESERVE_SELECTOR));

        assertTrue(success, "absent precompile should behave like a plain call to an empty account");
        assertEq(ret.length, 0, "absent precompile should return empty returndata");
    }
}

contract ReserveBalanceCaller {
    address constant RESERVE_BALANCE = address(0x0000000000000000000000000000000000001001);

    bool public lastResult;

    function forwardCall(bytes calldata data) external returns (bool success, bytes memory ret) {
        (success, ret) = RESERVE_BALANCE.call(data);
    }

    function callViaCallcode(bytes calldata data) external returns (bool success) {
        address target = RESERVE_BALANCE;
        bytes memory callData = data;
        assembly {
            success := callcode(gas(), target, 0, add(callData, 0x20), mload(callData), 0, 0)
        }
    }

    function callWithData(bytes calldata data) external payable returns (bool success, bytes memory ret) {
        (success, ret) = RESERVE_BALANCE.call{value: msg.value}(data);
    }

    function callDippedStatus() external returns (bool success, bool hasBool, bool dipped) {
        bytes memory ret;
        (success, ret) = RESERVE_BALANCE.call(abi.encodeWithSelector(IReserveBalance.dippedIntoReserve.selector));
        hasBool = ret.length == 32;
        if (hasBool) {
            dipped = abi.decode(ret, (bool));
        }
    }

    function snapshot() external {
        lastResult = IReserveBalance(RESERVE_BALANCE).dippedIntoReserve();
    }
}

contract RefundSink {
    receive() external payable {}

    function refund(address payable to, uint256 amount) external {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "refund failed");
    }
}

contract DelegatedReserveProbe {
    IReserveBalance constant RESERVE = IReserveBalance(address(0x0000000000000000000000000000000000001001));

    bool public lastBefore;
    bool public lastDuring;
    bool public lastAfter;
    bool public lastChildCallOk;
    bool public lastChildDipped;
    bool public lastAfterRevert;

    receive() external payable {}

    function spendAndRecord(address payable sink, uint256 amount) external {
        lastBefore = RESERVE.dippedIntoReserve();

        (bool ok,) = sink.call{value: amount}("");
        require(ok, "spend failed");

        lastDuring = RESERVE.dippedIntoReserve();
    }

    function spendRestoreAndRecord(RefundSink sink, uint256 amount) external {
        lastBefore = RESERVE.dippedIntoReserve();

        (bool ok,) = address(sink).call{value: amount}("");
        require(ok, "spend failed");

        lastDuring = RESERVE.dippedIntoReserve();
        sink.refund(payable(address(this)), amount);
        lastAfter = RESERVE.dippedIntoReserve();
    }

    function childSpendRevertAndRecord(RefundSink sink, uint256 amount) external {
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeCall(DelegatedReserveProbe.childSpendRevert, (sink, amount)));

        lastChildCallOk = ok;
        lastChildDipped = !ok && ret.length == 32 && abi.decode(ret, (bool));
        lastAfterRevert = RESERVE.dippedIntoReserve();
    }

    function childSpendRevert(RefundSink sink, uint256 amount) external {
        require(msg.sender == address(this), "only self");

        (bool ok,) = address(sink).call{value: amount}("");
        require(ok, "spend failed");

        bool dipped = RESERVE.dippedIntoReserve();
        assembly {
            mstore(0x00, dipped)
            revert(0x00, 0x20)
        }
    }
}
