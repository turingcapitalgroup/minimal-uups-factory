// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { Test } from "forge-std/Test.sol";
import { MinimalUUPSFactory } from "../src/MinimalUUPSFactory.sol";

/* //////////////////////////////////////////////////////////////
                          MOCK IMPLEMENTATIONS
//////////////////////////////////////////////////////////////*/

/// @dev Standard UUPS-shaped implementation used for most tests.
/// Has no `receive()` / `payable fallback()` — so a delegatecall through the proxy with value
/// will fail unless `data.length > 0` matches a payable function.
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

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}

/// @dev Variant returning a different version string — proves an upgrade actually swapped the implementation
/// (otherwise version() would be the same after upgrade and tests would silently pass).
contract MockImplementationV2 is MockImplementation {
    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}

/// @dev Implementation that explicitly accepts ETH via `receive()`. Used to test the
/// `data.length == 0 && msg.value > 0` branch of deployAndCall / deployDeterministicAndCall.
contract MockImplementationPayable is MockImplementation {
    receive() external payable { }
}

/// @dev Implementation whose `initialize` always reverts. Used to test that init-call reverts
/// bubble up through deployAndCall.
contract MockImplementationFailingInit {
    error InitFailed();

    function initialize(address) external pure {
        revert InitFailed();
    }
}

/* //////////////////////////////////////////////////////////////
                          TEST SUITE
//////////////////////////////////////////////////////////////*/

contract MinimalUUPSFactoryTest is Test {
    /// @dev ERC-1967 implementation storage slot.
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MinimalUUPSFactory public factory;
    MockImplementation public implementation;

    address public owner = address(0x1234);
    address public alice = address(0xA11CE);

    function setUp() public {
        factory = new MinimalUUPSFactory();
        implementation = new MockImplementation();
    }

    /* //////////////////////////////////////////////////////////////
                                deploy()
    //////////////////////////////////////////////////////////////*/

    function test_Deploy_Success() public {
        address proxy = factory.deploy(address(implementation));

        assertTrue(proxy != address(0), "proxy is zero address");
        assertTrue(proxy.code.length > 0, "proxy has no bytecode");
        assertEq(_readImplementation(proxy), address(implementation), "ERC-1967 slot mismatch");
    }

    function test_Deploy_EmitsProxyDeployed() public {
        // We can't predict the proxy address (non-deterministic CREATE) so we don't check topic1.
        // We DO assert the indexed implementation matches.
        vm.expectEmit(false, true, false, false);
        emit MinimalUUPSFactory.ProxyDeployed(address(0), address(implementation));
        factory.deploy(address(implementation));
    }

    function test_Deploy_TwoCalls_ReturnDifferentProxies() public {
        address a = factory.deploy(address(implementation));
        address b = factory.deploy(address(implementation));
        assertTrue(a != b, "two non-deterministic deployments returned the same proxy");
    }

    /* //////////////////////////////////////////////////////////////
                            deployAndCall()
    //////////////////////////////////////////////////////////////*/

    /// @notice Branch: `data.length > 0`, init succeeds.
    function test_DeployAndCall_WithInitData_Succeeds() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));

        address proxy = factory.deployAndCall(address(implementation), initData);

        assertEq(_readImplementation(proxy), address(implementation), "ERC-1967 slot mismatch");
        assertTrue(MockImplementation(proxy).initialized(), "initialize did not run");
        assertEq(MockImplementation(proxy).owner(), owner, "owner not set by init");
    }

    /// @notice Branch: `data.length > 0`, init reverts. Revert reason must bubble.
    function test_DeployAndCall_InitReverts_BubblesError() public {
        MockImplementationFailingInit failingImpl = new MockImplementationFailingInit();
        bytes memory initData = abi.encodeCall(MockImplementationFailingInit.initialize, (owner));

        vm.expectRevert(MockImplementationFailingInit.InitFailed.selector);
        factory.deployAndCall(address(failingImpl), initData);
    }

    /// @notice Branch: `data.length == 0 && msg.value > 0`, impl accepts ETH.
    function test_DeployAndCall_NoData_WithValue_ForwardsETH() public {
        MockImplementationPayable payableImpl = new MockImplementationPayable();
        uint256 ethToForward = 1 ether;

        vm.deal(address(this), ethToForward);
        address proxy = factory.deployAndCall{ value: ethToForward }(address(payableImpl), "");

        assertEq(proxy.balance, ethToForward, "ETH not forwarded to proxy");
        assertEq(_readImplementation(proxy), address(payableImpl), "ERC-1967 slot mismatch");
    }

    /// @notice Branch: `data.length == 0 && msg.value > 0`, impl rejects ETH → DeploymentFailed.
    function test_DeployAndCall_NoData_WithValue_ImplRejectsETH_RevertsWithDeploymentFailed() public {
        // `implementation` (MockImplementation) has no receive() or payable fallback.
        vm.deal(address(this), 1 ether);

        vm.expectRevert(MinimalUUPSFactory.DeploymentFailed.selector);
        factory.deployAndCall{ value: 1 ether }(address(implementation), "");
    }

    /// @notice Branch: `data.length == 0 && msg.value == 0`. Pure no-op deployment, just emits event.
    function test_DeployAndCall_NoData_NoValue_OnlyEmitsEvent() public {
        vm.expectEmit(false, true, false, false);
        emit MinimalUUPSFactory.ProxyDeployed(address(0), address(implementation));

        address proxy = factory.deployAndCall(address(implementation), "");

        assertTrue(proxy.code.length > 0, "proxy has no bytecode");
        assertEq(proxy.balance, 0, "proxy unexpectedly received ETH");
        assertFalse(MockImplementation(proxy).initialized(), "should not be initialized when no data");
    }

    /* //////////////////////////////////////////////////////////////
                        deployDeterministic()
    //////////////////////////////////////////////////////////////*/

    function test_DeployDeterministic_Success() public {
        bytes32 salt = keccak256("deterministic-test");

        address predicted = factory.predictDeterministicAddress(address(implementation), salt);
        address proxy = factory.deployDeterministic(address(implementation), salt);

        assertEq(proxy, predicted, "deployed address != predicted");
        assertTrue(proxy.code.length > 0, "proxy has no bytecode");
        assertEq(_readImplementation(proxy), address(implementation), "ERC-1967 slot mismatch");
    }

    function test_DeployDeterministic_EmitsProxyDeployed() public {
        bytes32 salt = keccak256("deterministic-emit-test");
        address predicted = factory.predictDeterministicAddress(address(implementation), salt);

        vm.expectEmit(true, true, false, false);
        emit MinimalUUPSFactory.ProxyDeployed(predicted, address(implementation));
        factory.deployDeterministic(address(implementation), salt);
    }

    function test_DeployDeterministic_SameSalt_Reverts() public {
        bytes32 salt = keccak256("collision-test");

        factory.deployDeterministic(address(implementation), salt);

        // Second deploy with the same impl + salt produces a CREATE2 collision.
        // OptimisedLibClone bubbles a low-level revert; we don't care about the exact selector,
        // only that the second call reverts.
        vm.expectRevert();
        factory.deployDeterministic(address(implementation), salt);
    }

    function test_DeployDeterministic_DifferentSalts_DifferentAddresses() public {
        address a = factory.deployDeterministic(address(implementation), keccak256("salt-a"));
        address b = factory.deployDeterministic(address(implementation), keccak256("salt-b"));
        assertTrue(a != b, "different salts produced same address");
    }

    /* //////////////////////////////////////////////////////////////
                    deployDeterministicAndCall()
    //////////////////////////////////////////////////////////////*/

    /// @notice Branch: `data.length > 0`, init succeeds.
    function test_DeployDeterministicAndCall_WithInitData_Succeeds() public {
        bytes32 salt = keccak256("dac-success");
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));

        address predicted = factory.predictDeterministicAddress(address(implementation), salt);
        address proxy = factory.deployDeterministicAndCall(address(implementation), salt, initData);

        assertEq(proxy, predicted, "deployed != predicted");
        assertEq(_readImplementation(proxy), address(implementation), "ERC-1967 slot mismatch");
        assertTrue(MockImplementation(proxy).initialized(), "init did not run");
        assertEq(MockImplementation(proxy).owner(), owner, "owner not set by init");
    }

    /// @notice Branch: `data.length > 0`, init reverts. Revert reason must bubble.
    function test_DeployDeterministicAndCall_InitReverts_BubblesError() public {
        MockImplementationFailingInit failingImpl = new MockImplementationFailingInit();
        bytes32 salt = keccak256("dac-init-reverts");
        bytes memory initData = abi.encodeCall(MockImplementationFailingInit.initialize, (owner));

        vm.expectRevert(MockImplementationFailingInit.InitFailed.selector);
        factory.deployDeterministicAndCall(address(failingImpl), salt, initData);
    }

    /// @notice Branch: `data.length == 0 && msg.value > 0`, impl accepts ETH.
    function test_DeployDeterministicAndCall_NoData_WithValue_ForwardsETH() public {
        MockImplementationPayable payableImpl = new MockImplementationPayable();
        bytes32 salt = keccak256("dac-eth-success");
        uint256 ethToForward = 1 ether;

        address predicted = factory.predictDeterministicAddress(address(payableImpl), salt);
        vm.deal(address(this), ethToForward);

        address proxy = factory.deployDeterministicAndCall{ value: ethToForward }(address(payableImpl), salt, "");

        assertEq(proxy, predicted, "deployed != predicted");
        assertEq(proxy.balance, ethToForward, "ETH not forwarded to proxy");
    }

    /// @notice Branch: `data.length == 0 && msg.value > 0`, impl rejects ETH → DeploymentFailed.
    function test_DeployDeterministicAndCall_NoData_WithValue_ImplRejectsETH_RevertsWithDeploymentFailed() public {
        bytes32 salt = keccak256("dac-eth-reject");
        vm.deal(address(this), 1 ether);

        vm.expectRevert(MinimalUUPSFactory.DeploymentFailed.selector);
        factory.deployDeterministicAndCall{ value: 1 ether }(address(implementation), salt, "");
    }

    /// @notice Branch: `data.length == 0 && msg.value == 0`. Pure no-op deployment, just emits event.
    function test_DeployDeterministicAndCall_NoData_NoValue_OnlyEmitsEvent() public {
        bytes32 salt = keccak256("dac-noop");
        address predicted = factory.predictDeterministicAddress(address(implementation), salt);

        vm.expectEmit(true, true, false, false);
        emit MinimalUUPSFactory.ProxyDeployed(predicted, address(implementation));

        address proxy = factory.deployDeterministicAndCall(address(implementation), salt, "");

        assertEq(proxy, predicted, "deployed != predicted");
        assertEq(proxy.balance, 0, "proxy unexpectedly received ETH");
    }

    function test_DeployDeterministicAndCall_SameSalt_Reverts() public {
        bytes32 salt = keccak256("dac-collision");
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));

        factory.deployDeterministicAndCall(address(implementation), salt, initData);

        vm.expectRevert();
        factory.deployDeterministicAndCall(address(implementation), salt, initData);
    }

    /* //////////////////////////////////////////////////////////////
                            initCodeHash()
    //////////////////////////////////////////////////////////////*/

    function test_InitCodeHash_NonZero() public view {
        bytes32 hash = factory.initCodeHash(address(implementation));
        assertTrue(hash != bytes32(0), "init code hash is zero");
    }

    function test_InitCodeHash_Deterministic() public view {
        bytes32 a = factory.initCodeHash(address(implementation));
        bytes32 b = factory.initCodeHash(address(implementation));
        assertEq(a, b, "initCodeHash is not deterministic for same input");
    }

    function test_InitCodeHash_DifferentImpls_DifferentHashes() public {
        MockImplementation other = new MockImplementation();
        require(address(other) != address(implementation), "test setup: same impl address");

        bytes32 hashA = factory.initCodeHash(address(implementation));
        bytes32 hashB = factory.initCodeHash(address(other));

        assertTrue(hashA != hashB, "different impls produced same init code hash");
    }

    /* //////////////////////////////////////////////////////////////
                    predictDeterministicAddress()
    //////////////////////////////////////////////////////////////*/

    function test_PredictDeterministicAddress_Deterministic() public view {
        bytes32 salt = keccak256("predict-test");
        address a = factory.predictDeterministicAddress(address(implementation), salt);
        address b = factory.predictDeterministicAddress(address(implementation), salt);
        assertEq(a, b, "predictDeterministicAddress is not deterministic");
    }

    function test_PredictDeterministicAddress_DifferentSalts_DifferentAddresses() public view {
        address a = factory.predictDeterministicAddress(address(implementation), keccak256("salt-a"));
        address b = factory.predictDeterministicAddress(address(implementation), keccak256("salt-b"));
        assertTrue(a != b, "different salts predicted same address");
    }

    function test_PredictDeterministicAddress_DifferentImpls_DifferentAddresses() public {
        MockImplementation other = new MockImplementation();
        bytes32 salt = keccak256("same-salt");

        address a = factory.predictDeterministicAddress(address(implementation), salt);
        address b = factory.predictDeterministicAddress(address(other), salt);
        assertTrue(a != b, "different impls predicted same address");
    }

    function test_PredictDeterministicAddress_MatchesActualDeploy() public {
        bytes32 salt = keccak256("predict-actual");
        address predicted = factory.predictDeterministicAddress(address(implementation), salt);
        address actual = factory.deployDeterministic(address(implementation), salt);
        assertEq(actual, predicted, "predicted address differs from actual deployment");
    }

    /* //////////////////////////////////////////////////////////////
                       PROXY → IMPLEMENTATION DELEGATION
    //////////////////////////////////////////////////////////////*/

    function test_ProxyDelegatesToImplementation() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);

        // Calling a pure view function on the proxy must delegate to the implementation.
        assertEq(MockImplementation(proxy).version(), "1.0.0", "proxy did not delegate to implementation");
    }

    /// @notice Verify the upgrade actually swapped the implementation. The previous version of this
    /// test compared `version()` after upgrading to a new MockImplementation that returned the SAME
    /// "1.0.0" — making the assertion a tautology. Here we upgrade to MockImplementationV2 (which
    /// returns "2.0.0") AND read the ERC-1967 slot to prove the swap landed.
    function test_ProxyIsUpgradeableViaUUPS() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);
        assertEq(MockImplementation(proxy).version(), "1.0.0", "pre-upgrade version mismatch");

        MockImplementationV2 newImpl = new MockImplementationV2();
        address implBefore = _readImplementation(proxy);

        vm.prank(owner);
        MockImplementation(proxy).upgradeToAndCall(address(newImpl), "");

        // ERC-1967 slot moved.
        address implAfter = _readImplementation(proxy);
        assertEq(implAfter, address(newImpl), "ERC-1967 impl slot did not change to newImpl");
        assertTrue(implAfter != implBefore, "ERC-1967 impl slot unchanged");

        // Behavior changed (different version string proves the new code runs).
        assertEq(MockImplementation(proxy).version(), "2.0.0", "post-upgrade version did not change");
    }

    function test_ProxyUpgradeByNonOwner_Reverts() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);

        MockImplementationV2 newImpl = new MockImplementationV2();

        vm.prank(alice);
        vm.expectRevert(MockImplementation.Unauthorized.selector);
        MockImplementation(proxy).upgradeToAndCall(address(newImpl), "");
    }

    function test_ReinitializeProxy_Reverts() public {
        bytes memory initData = abi.encodeCall(MockImplementation.initialize, (owner));
        address proxy = factory.deployAndCall(address(implementation), initData);

        vm.expectRevert(MockImplementation.AlreadyInitialized.selector);
        MockImplementation(proxy).initialize(alice);
    }

    /* //////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _readImplementation(address proxy) internal view returns (address impl) {
        impl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPL_SLOT))));
    }

    receive() external payable { }
}
