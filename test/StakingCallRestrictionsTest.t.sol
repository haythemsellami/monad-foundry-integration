// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IMonadStaking} from "monad-std/interfaces/IMonadStaking.sol";

/// @title StakingCallRestrictionsTest
/// @notice Tests that the staking precompile (0x1000) enforces call restrictions
/// @dev Matches C++ execution client behavior:
///      - Only plain CALL is accepted
///      - DELEGATECALL, CALLCODE are rejected
///      - STATICCALL and calls in static context are rejected
///      - Non-zero value transfers are rejected (view functions are not payable)
contract StakingCallRestrictionsTest is Test {
    address constant STAKING_ADDRESS = address(0x0000000000000000000000000000000000001000);

    bytes getEpochData = abi.encodeWithSelector(IMonadStaking.getEpoch.selector);

    function assertDelegatecallRejected(bytes memory data) internal {
        (bool success,) = STAKING_ADDRESS.delegatecall(data);
        assertFalse(success, "DELEGATECALL to staking should be rejected");
    }

    // ============ Regular CALL (accepted) ============

    function test_regularCallAccepted() public {
        (bool success, bytes memory result) = STAKING_ADDRESS.call(getEpochData);
        assertTrue(success, "Regular CALL to staking should succeed");
        // Should return valid ABI-encoded data (64 bytes: uint64 epoch + bool)
        assertEq(result.length, 64, "getEpoch should return 64 bytes");
    }

    // ============ DELEGATECALL (rejected) ============

    function test_delegatecallRejected_getEpoch() public {
        assertDelegatecallRejected(getEpochData);
    }

    function test_delegatecallRejectedViaContract() public {
        StakingCaller caller = new StakingCaller();
        bool success = caller.callViaDelegatecall(getEpochData);
        assertFalse(success, "DELEGATECALL to staking via intermediary should be rejected");
    }

    // ============ STATICCALL (rejected) ============

    function test_staticcallRejected() public {
        (bool success,) = STAKING_ADDRESS.staticcall(getEpochData);
        assertFalse(success, "STATICCALL to staking should be rejected");
    }

    function test_staticcallRejectedViaViewFunction() public {
        StakingCaller caller = new StakingCaller();
        bool success = caller.callViaStaticcall(getEpochData);
        assertFalse(success, "STATICCALL to staking via view wrapper should be rejected");
    }

    // ============ Value transfer (rejected) ============

    function test_valueTransferRejected() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = STAKING_ADDRESS.call{value: 1}(getEpochData);
        assertFalse(success, "CALL with value to staking should be rejected");
    }

    function test_largeValueTransferRejected() public {
        vm.deal(address(this), 10 ether);
        (bool success,) = STAKING_ADDRESS.call{value: 1 ether}(getEpochData);
        assertFalse(success, "CALL with large value to staking should be rejected");
    }

    // ============ CALLCODE (rejected) ============

    function test_callcodeRejected() public {
        StakingCaller caller = new StakingCaller();
        bool success = caller.callViaCallcode(getEpochData);
        assertFalse(success, "CALLCODE to staking should be rejected");
    }

    // ============ Static context propagation (rejected) ============

    function test_callInsideStaticContextRejected() public {
        // Deploy a helper that forwards calls — its forwardCall is non-view so it compiles
        // to CALL, but we call the helper itself via STATICCALL to propagate the static flag
        StakingCaller caller = new StakingCaller();

        // STATICCALL to caller.forwardCallToStaking → caller does CALL to 0x1000
        // The inner CALL inherits is_static=true from the STATICCALL frame
        (bool outerSuccess, bytes memory returnData) = address(caller)
            .staticcall(abi.encodeWithSelector(StakingCaller.forwardCallToStaking.selector, getEpochData));
        // The outer STATICCALL succeeds (helper catches the error),
        // but the inner CALL to staking was rejected
        assertTrue(outerSuccess, "Outer STATICCALL to helper should succeed");
        bool innerSuccess = abi.decode(returnData, (bool));
        assertFalse(innerSuccess, "Inner CALL to staking should be rejected in static context");
    }

    // ============ Multiple selectors rejected via DELEGATECALL ============

    function test_delegatecallRejected_getProposerValId() public {
        assertDelegatecallRejected(abi.encodeWithSelector(IMonadStaking.getProposerValId.selector));
    }

    function test_delegatecallRejected_getConsensusValidatorSet() public {
        assertDelegatecallRejected(
            abi.encodeWithSelector(IMonadStaking.getConsensusValidatorSet.selector, uint32(0))
        );
    }

    function test_delegatecallRejected_getValidator() public {
        assertDelegatecallRejected(abi.encodeWithSelector(IMonadStaking.getValidator.selector, uint64(1)));
    }
}

/// @notice Helper contract to test various call types to the staking precompile
contract StakingCaller {
    address constant STAKING_ADDRESS = address(0x0000000000000000000000000000000000001000);

    function callViaDelegatecall(bytes calldata data) external returns (bool success) {
        (success,) = STAKING_ADDRESS.delegatecall(data);
    }

    function callViaStaticcall(bytes calldata data) external view returns (bool success) {
        (success,) = STAKING_ADDRESS.staticcall(data);
    }

    function callViaCallcode(bytes calldata data) external returns (bool success) {
        address target = STAKING_ADDRESS;
        bytes memory callData = data;
        assembly {
            success := callcode(gas(), target, 0, add(callData, 0x20), mload(callData), 0, 0)
        }
    }

    /// @notice Forwards a CALL to the staking precompile.
    ///         When this function is called via STATICCALL, the inner CALL inherits is_static=true.
    function forwardCallToStaking(bytes calldata data) external returns (bool success) {
        (success,) = STAKING_ADDRESS.call(data);
    }
}
