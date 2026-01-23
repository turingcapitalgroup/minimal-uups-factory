// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { Test } from "forge-std/Test.sol";
import { MinimalUUPSFactory } from "../src/MinimalUUPSFactory.sol";

/// @dev Mock UUPS implementation for testing
contract MockImplementation {
    /// @dev ERC-1967 implementation slot
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address public owner;
    bool public initialized;

    error AlreadyInitialized();
    error Unauthorized();

    function initialize(address _owner) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        owner = _owner;
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data) external {
        if (msg.sender != owner) revert Unauthorized();
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        if (data.length > 0) {
            (bool success,) = newImplementation.delegatecall(data);
            require(success);
        }
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}

contract MinimalUUPSFactoryTest is Test {
    MinimalUUPSFactory public factory;
    MockImplementation public implementation;

    address public owner = address(0x1234);

    function setUp() public {
        factory = new MinimalUUPSFactory();
        implementation = new MockImplementation();
    }

    function test_Deploy() public {
        address proxy = factory.deploy(address(implementation));
        assertTrue(proxy != address(0));
        assertTrue(proxy.code.length > 0);
    }

    function test_DeployAndCall() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);

        assertTrue(proxy != address(0));
        assertEq(MockImplementation(proxy).owner(), owner);
        assertTrue(MockImplementation(proxy).initialized());
    }

    function test_DeployDeterministic() public {
        bytes32 salt = keccak256("test");
        address predicted = factory.predictDeterministicAddress(address(implementation), salt);

        address proxy = factory.deployDeterministic(address(implementation), salt);

        assertEq(proxy, predicted);
        assertTrue(proxy.code.length > 0);
    }

    function test_DeployDeterministicAndCall() public {
        bytes32 salt = keccak256("test");
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address predicted = factory.predictDeterministicAddress(address(implementation), salt);

        address proxy = factory.deployDeterministicAndCall(address(implementation), salt, initData);

        assertEq(proxy, predicted);
        assertEq(MockImplementation(proxy).owner(), owner);
    }

    function test_ProxyDelegatesToImplementation() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);

        assertEq(MockImplementation(proxy).version(), "1.0.0");
    }

    function test_ProxyIsUpgradeableViaUUPS() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);

        // Deploy new implementation
        MockImplementation newImpl = new MockImplementation();

        // Upgrade via UUPS (only owner can upgrade)
        vm.prank(owner);
        MockImplementation(proxy).upgradeToAndCall(address(newImpl), "");

        // Proxy still works
        assertEq(MockImplementation(proxy).version(), "1.0.0");
    }

    function test_InitCodeHash() public view {
        bytes32 hash = factory.initCodeHash(address(implementation));
        assertTrue(hash != bytes32(0));
    }

    function test_EmitsProxyDeployed() public {
        vm.expectEmit(false, true, false, false);
        emit MinimalUUPSFactory.ProxyDeployed(address(0), address(implementation));
        factory.deploy(address(implementation));
    }
}
