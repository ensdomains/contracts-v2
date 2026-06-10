// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {IETHRegistrarController} from "@ens/contracts/ethregistrar/IETHRegistrarController.sol";
import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {
    ReverseRegistrar,
    ADDR_REVERSE_NODE
} from "@ens/contracts/reverseRegistrar/ReverseRegistrar.sol";
import {PublicResolver} from "@ens/contracts/resolvers/PublicResolver.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";

import {LibLabel} from "~src/utils/LibLabel.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {TestnetV1PremigrationRegistrar} from "~src/testnet/TestnetV1PremigrationRegistrar.sol";
import {V1Fixture} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract TestnetV1PremigrationRegistrarTest is V1Fixture, V2Fixture {
    TestnetV1PremigrationRegistrar registrar;
    ReverseRegistrar reverseRegistrar;
    DefaultReverseRegistrar defaultReverseRegistrar;
    PublicResolver publicResolver;

    IRegistry premigrationRegistry = IRegistry(makeAddr("premigrationRegistry"));
    address premigrationResolver = makeAddr("premigrationResolver");

    string testLabel = "test";
    bytes32 testReferrer = keccak256("referrer");
    address user = makeAddr("user");

    function setUp() external {
        deployV1Fixture();
        deployV2Fixture();

        reverseRegistrar = new ReverseRegistrar(registryV1);
        registryV1.setOwner(ADDR_REVERSE_NODE, address(reverseRegistrar));
        defaultReverseRegistrar = new DefaultReverseRegistrar();

        registrar = new TestnetV1PremigrationRegistrar(
            baseRegistrar,
            registryV1,
            reverseRegistrar,
            defaultReverseRegistrar,
            ethRegistry,
            premigrationRegistry,
            premigrationResolver
        );

        publicResolver = new PublicResolver(
            registryV1,
            INameWrapper(address(nameWrapper)),
            address(registrar), // trustedETHController
            address(reverseRegistrar) // trustedReverseRegistrar
        );

        baseRegistrar.addController(address(registrar));
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(registrar)
        );
        reverseRegistrar.setController(address(registrar), true);
        defaultReverseRegistrar.setController(address(registrar), true);
    }

    function _defaultRegistration()
        internal
        view
        returns (IETHRegistrarController.Registration memory)
    {
        return
            IETHRegistrarController.Registration({
                label: testLabel,
                owner: user,
                duration: registrar.MIN_REGISTRATION_DURATION(),
                secret: bytes32(0),
                resolver: address(0),
                data: new bytes[](0),
                reverseRecord: 0,
                referrer: testReferrer
            });
    }

    function _ethNode(bytes32 labelhash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(registrar.ETH_NODE(), labelhash));
    }

    function test_constructor() external view {
        assertEq(address(registrar.BASE()), address(baseRegistrar), "BASE");
        assertEq(address(registrar.ENS_REGISTRY()), address(registryV1), "ENS_REGISTRY");
        assertEq(
            address(registrar.REVERSE_REGISTRAR()),
            address(reverseRegistrar),
            "REVERSE_REGISTRAR"
        );
        assertEq(
            address(registrar.DEFAULT_REVERSE_REGISTRAR()),
            address(defaultReverseRegistrar),
            "DEFAULT_REVERSE_REGISTRAR"
        );
        assertEq(address(registrar.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
        assertEq(
            address(registrar.PREMIGRATION_REGISTRY()),
            address(premigrationRegistry),
            "PREMIGRATION_REGISTRY"
        );
        assertEq(
            registrar.PREMIGRATION_RESOLVER(),
            premigrationResolver,
            "PREMIGRATION_RESOLVER"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // available()
    ////////////////////////////////////////////////////////////////////////

    function test_available() external view {
        assertTrue(registrar.available(testLabel));
    }

    function test_available_labelTooShort() external view {
        assertFalse(registrar.available("ab"));
    }

    function test_available_registered() external {
        registrar.register(_defaultRegistration());
        assertFalse(registrar.available(testLabel), "registered");

        uint256 tokenId = LibLabel.id(testLabel);
        vm.warp(baseRegistrar.nameExpires(tokenId) + baseRegistrar.GRACE_PERIOD() + 1);
        assertTrue(registrar.available(testLabel), "after grace");
    }

    ////////////////////////////////////////////////////////////////////////
    // register()
    ////////////////////////////////////////////////////////////////////////

    function test_register() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        uint256 tokenId = LibLabel.id(testLabel);
        uint256 expires = block.timestamp + registration.duration;

        vm.expectEmit();
        emit TestnetV1PremigrationRegistrar.NameRegistered(
            testLabel,
            bytes32(tokenId),
            user,
            0,
            0,
            expires,
            testReferrer
        );
        vm.prank(user);
        registrar.register(registration);

        // v1 registration
        assertEq(baseRegistrar.ownerOf(tokenId), user, "ownerOf");
        assertEq(baseRegistrar.nameExpires(tokenId), expires, "nameExpires");
        assertEq(registryV1.owner(_ethNode(bytes32(tokenId))), user, "node owner");

        // v2 reservation
        IPermissionedRegistry.State memory state = ethRegistry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, uint64(expires), "expiry");
        assertEq(state.latestOwner, address(0), "latestOwner");
        assertEq(
            address(ethRegistry.getSubregistry(testLabel)),
            address(premigrationRegistry),
            "subregistry"
        );
        assertEq(ethRegistry.getResolver(testLabel), premigrationResolver, "resolver");
    }

    function test_register_refundsOverpayment() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        vm.deal(user, 1 ether);
        vm.prank(user);
        registrar.register{value: 0.5 ether}(registration);

        assertEq(user.balance, 1 ether, "user balance");
        assertEq(address(registrar).balance, 0, "registrar balance");
    }

    function test_register_refundFailed() external {
        RegisterCaller caller = new RegisterCaller(registrar);
        IETHRegistrarController.Registration memory registration = _defaultRegistration();

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetV1PremigrationRegistrar.RefundFailed.selector,
                address(caller),
                0.5 ether
            )
        );
        caller.callRegister{value: 0.5 ether}(registration);
    }

    function test_register_durationTooShort() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.duration = registrar.MIN_REGISTRATION_DURATION() - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetV1PremigrationRegistrar.DurationTooShort.selector,
                registration.duration
            )
        );
        registrar.register(registration);
    }

    function test_register_nameNotAvailable_registered() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registrar.register(registration);

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetV1PremigrationRegistrar.NameNotAvailable.selector,
                testLabel
            )
        );
        registrar.register(registration);
    }

    function test_register_nameNotAvailable_labelTooShort() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.label = "ab";

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetV1PremigrationRegistrar.NameNotAvailable.selector,
                registration.label
            )
        );
        registrar.register(registration);
    }

    function test_register_resolverRequiredWhenDataSupplied() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.data = new bytes[](1);
        registration.data[0] = "";

        vm.expectRevert(
            TestnetV1PremigrationRegistrar.ResolverRequiredWhenDataSupplied.selector
        );
        registrar.register(registration);
    }

    function test_register_resolverRequiredForReverseRecord() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.reverseRecord = registrar.REVERSE_RECORD_ETHEREUM_BIT();

        vm.expectRevert(
            TestnetV1PremigrationRegistrar.ResolverRequiredForReverseRecord.selector
        );
        registrar.register(registration);
    }

    function test_register_expiryTooLarge() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.duration = type(uint64).max;
        uint256 expires = block.timestamp + registration.duration;

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetV1PremigrationRegistrar.ExpiryTooLarge.selector,
                expires
            )
        );
        registrar.register(registration);
    }

    ////////////////////////////////////////////////////////////////////////
    // register() with resolver / reverse records
    ////////////////////////////////////////////////////////////////////////

    function test_register_withResolverAndData() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        uint256 tokenId = LibLabel.id(testLabel);
        bytes32 node = _ethNode(bytes32(tokenId));
        registration.resolver = address(publicResolver);
        registration.data = new bytes[](1);
        registration.data[0] = abi.encodeCall(publicResolver.setText, (node, "url", "https://ens.domains"));

        vm.prank(user);
        registrar.register(registration);

        assertEq(baseRegistrar.ownerOf(tokenId), user, "ownerOf");
        assertEq(registryV1.owner(node), user, "node owner");
        assertEq(registryV1.resolver(node), address(publicResolver), "node resolver");
        assertEq(publicResolver.text(node, "url"), "https://ens.domains", "text");

        // no reverse record requested
        assertEq(registryV1.owner(reverseRegistrar.node(user)), address(0), "reverse owner");
        assertEq(defaultReverseRegistrar.nameForAddr(user), "", "default reverse");
    }

    function test_register_reverseRecordEthereum() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.resolver = address(publicResolver);
        registration.reverseRecord = registrar.REVERSE_RECORD_ETHEREUM_BIT();

        vm.prank(user);
        registrar.register(registration);

        bytes32 reverseNode = reverseRegistrar.node(user);
        assertEq(registryV1.owner(reverseNode), user, "reverse owner");
        assertEq(registryV1.resolver(reverseNode), address(publicResolver), "reverse resolver");
        assertEq(publicResolver.name(reverseNode), "test.eth", "reverse name");
        assertEq(defaultReverseRegistrar.nameForAddr(user), "", "default reverse");
    }

    function test_register_reverseRecordDefault() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.resolver = address(publicResolver);
        registration.reverseRecord = registrar.REVERSE_RECORD_DEFAULT_BIT();

        vm.prank(user);
        registrar.register(registration);

        assertEq(defaultReverseRegistrar.nameForAddr(user), "test.eth", "default reverse");
        assertEq(
            registryV1.owner(reverseRegistrar.node(user)),
            address(0),
            "reverse owner"
        );
    }

    function test_register_reverseRecordBoth() external {
        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        registration.resolver = address(publicResolver);
        registration.reverseRecord =
            registrar.REVERSE_RECORD_ETHEREUM_BIT() | registrar.REVERSE_RECORD_DEFAULT_BIT();

        vm.prank(user);
        registrar.register(registration);

        bytes32 reverseNode = reverseRegistrar.node(user);
        assertEq(registryV1.owner(reverseNode), user, "reverse owner");
        assertEq(publicResolver.name(reverseNode), "test.eth", "reverse name");
        assertEq(defaultReverseRegistrar.nameForAddr(user), "test.eth", "default reverse");
    }

    ////////////////////////////////////////////////////////////////////////
    // register() premigration branches
    ////////////////////////////////////////////////////////////////////////

    function test_register_renewsExistingReservation() external {
        address reservedResolver = makeAddr("reservedResolver");
        uint64 reservedExpiry = uint64(block.timestamp + 1 days);
        ethRegistry.register(
            testLabel,
            address(0), // reserve
            IRegistry(address(0)),
            reservedResolver,
            0,
            reservedExpiry
        );
        uint256 tokenId = ethRegistry.getState(LibLabel.id(testLabel)).tokenId;

        IETHRegistrarController.Registration memory registration = _defaultRegistration();
        uint256 expires = block.timestamp + registration.duration;
        registrar.register(registration);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, uint64(expires), "expiry");
        assertEq(state.tokenId, tokenId, "tokenId");

        // renewal keeps the original reservation's subregistry and resolver
        assertEq(address(ethRegistry.getSubregistry(testLabel)), address(0), "subregistry");
        assertEq(ethRegistry.getResolver(testLabel), reservedResolver, "resolver");
    }

    function test_register_keepsLaterReservation() external {
        uint64 reservedExpiry = uint64(block.timestamp + 365 days);
        ethRegistry.register(
            testLabel,
            address(0), // reserve
            IRegistry(address(0)),
            address(0),
            0,
            reservedExpiry
        );

        registrar.register(_defaultRegistration());

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, reservedExpiry, "expiry");
    }

    function test_register_skipsRegisteredName() external {
        address ownerV2 = makeAddr("ownerV2");
        uint64 registeredExpiry = uint64(block.timestamp + 1 days);
        ethRegistry.register(
            testLabel,
            ownerV2,
            IRegistry(address(0)),
            address(0),
            0,
            registeredExpiry
        );

        registrar.register(_defaultRegistration());

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.REGISTERED), "status");
        assertEq(state.expiry, registeredExpiry, "expiry");
        assertEq(state.latestOwner, ownerV2, "latestOwner");
    }
}

/// @dev Calls `register` with value but cannot receive the refund.
contract RegisterCaller {
    TestnetV1PremigrationRegistrar internal immutable REGISTRAR;

    constructor(TestnetV1PremigrationRegistrar registrar) {
        REGISTRAR = registrar;
    }

    function callRegister(IETHRegistrarController.Registration memory registration)
        external
        payable
    {
        REGISTRAR.register{value: msg.value}(registration);
    }
}
