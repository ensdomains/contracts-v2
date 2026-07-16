// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {CloneProxyBytecode} from "@ensdomains/verifiable-factory/CloneProxyBytecode.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Test} from "forge-std/Test.sol";

import {MockExecutorModule, MockValidatorModule} from "../../mocks/MockStandaloneHCAStack.sol";

import {StandaloneHCADeployer} from "~src/hca/StandaloneHCADeployer.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {ApprovedUpgradeGate} from "~src/registry/ApprovedUpgradeGate.sol";

contract StandaloneHCADeployerTest is Test {
    uint256 internal constant USER_SALT = 7;

    address internal owner = makeAddr("owner");
    address internal otherOwner = makeAddr("other-owner");
    address internal relayer = makeAddr("relayer");
    address internal attacker = makeAddr("attacker");

    VerifiableFactory internal factory;
    StandaloneSingleOwnerHCA internal implementation;
    StandaloneSingleOwnerHCA internal otherImplementation;
    StandaloneHCADeployer internal deployer;

    function setUp() public {
        factory = new VerifiableFactory();
        implementation = new StandaloneSingleOwnerHCA(
            makeAddr("entry-point"),
            address(new MockValidatorModule()),
            address(new MockExecutorModule()),
            "",
            new ApprovedUpgradeGate(address(this)),
            ApprovedUpgradeGate(address(0))
        );
        otherImplementation = new StandaloneSingleOwnerHCA(
            makeAddr("other-entry-point"),
            address(new MockValidatorModule()),
            address(new MockExecutorModule()),
            "",
            new ApprovedUpgradeGate(address(this)),
            ApprovedUpgradeGate(address(0))
        );
        deployer = new StandaloneHCADeployer(factory);
    }

    function test_constructorPinsDeploymentConfiguration() public view {
        assertEq(address(deployer.VERIFIABLE_FACTORY()), address(factory));
    }

    function test_constructorRejectsZeroConfiguration() public {
        vm.expectRevert(StandaloneHCADeployer.VerifiableFactoryCannotBeZero.selector);
        new StandaloneHCADeployer(IVerifiableFactory(address(0)));
    }

    function test_deploymentSaltBindsOwnerImplementationAndUserSalt() public view {
        assertEq(
            deployer.deploymentSalt(owner, address(implementation), USER_SALT),
            uint256(keccak256(abi.encode(USER_SALT, owner, address(implementation))))
        );
        assertNotEq(
            deployer.deploymentSalt(owner, address(implementation), USER_SALT),
            deployer.deploymentSalt(otherOwner, address(implementation), USER_SALT)
        );
        assertNotEq(
            deployer.deploymentSalt(owner, address(implementation), USER_SALT),
            deployer.deploymentSalt(owner, address(implementation), USER_SALT + 1)
        );
        assertNotEq(
            deployer.deploymentSalt(owner, address(implementation), USER_SALT),
            deployer.deploymentSalt(owner, address(otherImplementation), USER_SALT)
        );
    }

    function test_deploysExpectedOwnerBoundAddressFromArbitraryRelayer() public {
        address expected = _expectedAddress(owner, address(implementation), USER_SALT);

        vm.prank(relayer);
        address hca = deployer.deploy(owner, address(implementation), USER_SALT);

        assertEq(hca, expected);
        assertEq(StandaloneSingleOwnerHCA(payable(hca)).owner(), owner);
        assertEq(factory.verifyContract(hca), address(implementation));
    }

    function test_unexpectedImplementationCannotCaptureExpectedAddress() public {
        address expected = _expectedAddress(owner, address(implementation), USER_SALT);

        vm.prank(attacker);
        address otherHca = deployer.deploy(owner, address(otherImplementation), USER_SALT);

        assertNotEq(otherHca, expected);
        assertEq(StandaloneSingleOwnerHCA(payable(otherHca)).owner(), owner);
        assertEq(factory.verifyContract(otherHca), address(otherImplementation));

        vm.prank(relayer);
        address hca = deployer.deploy(owner, address(implementation), USER_SALT);

        assertEq(hca, expected);
        assertEq(StandaloneSingleOwnerHCA(payable(hca)).owner(), owner);
        assertEq(factory.verifyContract(hca), address(implementation));
    }

    function test_differentOwnersReceiveDifferentAccounts() public {
        vm.prank(relayer);
        address first = deployer.deploy(owner, address(implementation), USER_SALT);

        vm.prank(attacker);
        address second = deployer.deploy(otherOwner, address(implementation), USER_SALT);

        assertNotEq(first, second);
        assertEq(StandaloneSingleOwnerHCA(payable(first)).owner(), owner);
        assertEq(StandaloneSingleOwnerHCA(payable(second)).owner(), otherOwner);
    }

    function test_rejectsZeroOwnerOrImplementation() public {
        vm.expectRevert(StandaloneHCADeployer.OwnerCannotBeZero.selector);
        deployer.deploy(address(0), address(implementation), USER_SALT);

        vm.expectRevert(StandaloneHCADeployer.HCAImplementationCannotBeZero.selector);
        deployer.deploy(owner, address(0), USER_SALT);
    }

    function _expectedAddress(address owner_, address implementation_, uint256 userSalt)
        internal
        view
        returns (address)
    {
        bytes32 outerSalt =
            keccak256(
                abi.encode(
                    address(deployer),
                    deployer.deploymentSalt(owner_, implementation_, userSalt)
                )
            );
        bytes memory bytecode = CloneProxyBytecode.creationCode(factory.proxyLogic(), outerSalt);
        return Create2.computeAddress(outerSalt, keccak256(bytecode), address(factory));
    }
}
