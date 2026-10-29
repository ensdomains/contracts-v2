// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {
    IEACGrantInitializable,
    Grant
} from "~src/access-control/interfaces/IEACGrantInitializable.sol";
import {UserRegistryWithUpgradeAuthority} from "~src/registry/UserRegistryWithUpgradeAuthority.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {ILabelStore} from "~src/utils/interfaces/ILabelStore.sol";
import {IRegistryURIRenderer} from "~src/registry/interfaces/IRegistryURIRenderer.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {
    TrustedRegistryUpgradeAuthority,
    UPGRADE_ROLE_BITMAP
} from "~src/utils/TrustedRegistryUpgradeAuthority.sol";

contract TrustedRegistryUpgradeAuthorityTest is Test {
    VerifiableFactory factory;
    TrustedRegistryUpgradeAuthority authority;
    UserRegistryWithUpgradeAuthority userRegistryImpl;
    BadUserRegistry badUserRegistryImpl;
    BadUserRegistry badUserRegistry;

    address admin = makeAddr("admin");
    uint256 privateKey = 4;
    address signer;

    function setUp() external {
        signer = vm.addr(privateKey);
        authority = new TrustedRegistryUpgradeAuthority(address(this), signer);

        factory = new VerifiableFactory();
        userRegistryImpl = new UserRegistryWithUpgradeAuthority(
            ILabelStore(address(0)),
            IRegistryURIRenderer(address(0)),
            address(1),
            authority
        );

        badUserRegistryImpl = new BadUserRegistry(
            ILabelStore(address(0)),
            IRegistryURIRenderer(address(0)),
            address(1)
        );

        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(admin, EACBaseRolesLib.ALL_ROLES);
        badUserRegistry = BadUserRegistry(
            factory.deployProxy(
                address(badUserRegistryImpl),
                0,
                abi.encodeCall(IEACGrantInitializable.initialize, (grants))
            )
        );
    }

    function test_upgrade() external {
        _prepareForUpgrade();

        bytes memory data = "";
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(
                privateKey,
                keccak256(abi.encode(badUserRegistry, admin, userRegistryImpl, data))
            );

        authority.upgrade(
            address(badUserRegistry),
            admin,
            address(userRegistryImpl),
            data,
            abi.encodePacked(r, s, v)
        );
    }

    function test_upgrade_wrongProxy() external {
        _prepareForUpgrade();
        vm.expectRevert(
            abi.encodeWithSelector(TrustedRegistryUpgradeAuthority.UpgradeNotAuthorized.selector)
        );
        authority.upgrade(
            address(0),
            address(0),
            address(0),
            "",
            _sign(keccak256(abi.encode(address(1), address(0), address(0), "")))
        );
    }

    function test_upgrade_wrongAdmin() external {
        _prepareForUpgrade();
        vm.expectRevert(
            abi.encodeWithSelector(TrustedRegistryUpgradeAuthority.UpgradeNotAuthorized.selector)
        );
        authority.upgrade(
            address(0),
            address(0),
            address(0),
            "",
            _sign(keccak256(abi.encode(address(0), address(1), address(0), "")))
        );
    }

    function test_upgrade_wrongImplementation() external {
        _prepareForUpgrade();
        vm.expectRevert(
            abi.encodeWithSelector(TrustedRegistryUpgradeAuthority.UpgradeNotAuthorized.selector)
        );
        authority.upgrade(
            address(0),
            address(0),
            address(0),
            "",
            _sign(keccak256(abi.encode(address(0), address(0), address(1), "")))
        );
    }

    function test_upgrade_wrongCalldata() external {
        _prepareForUpgrade();
        vm.expectRevert(
            abi.encodeWithSelector(TrustedRegistryUpgradeAuthority.UpgradeNotAuthorized.selector)
        );
        authority.upgrade(
            address(0),
            address(0),
            address(0),
            "",
            _sign(keccak256(abi.encode(address(0), address(0), address(0), "1")))
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _prepareForUpgrade() internal {
        vm.prank(admin);
        badUserRegistry.grantRootRoles(UPGRADE_ROLE_BITMAP, address(authority));
        vm.prank(admin);
        badUserRegistry.revokeRootRoles(UPGRADE_ROLE_BITMAP, admin);
        assertTrue(
            badUserRegistry.isOnlyAssignee(
                badUserRegistry.ROOT_RESOURCE(),
                UPGRADE_ROLE_BITMAP,
                address(authority)
            )
        );
    }

    function _sign(bytes32 hash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encodePacked(r, s, v);
    }
}


contract BadUserRegistry is UserRegistry {
    constructor(ILabelStore labelStore, IRegistryURIRenderer uriRenderer, address namer)
        UserRegistry(labelStore, uriRenderer, namer)
    {}
    function canUpgradeFrom(address) external pure override returns (bool) {
        return true;
    }
}
