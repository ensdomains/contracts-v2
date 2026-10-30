// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {SimplePublicSuffixList} from "@ens/contracts/dnsregistrar/SimplePublicSuffixList.sol";

import {TemporaryDNSRegistrar, TLD_ROLE_BITMAP} from "~src/dns/TemporaryDNSRegistrar.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract TemporaryDNSRegistrarTest is V2Fixture {
    SimplePublicSuffixList publicSuffixList;
    TemporaryDNSRegistrar registrar;

    address dnsTLDResolver = makeAddr("DNSTLDResolver");
    address tokenOwner = makeAddr("TokenOwner");
    address actor = makeAddr("actor");

    string availableLabel = "available";
    string reservedLabel = "reserved";
    string registeredLabel = "registered";
    string assignedLabel = "assigned";

    function setUp() external {
        deployV2Fixture();

        publicSuffixList = new SimplePublicSuffixList();

        rootRegistry.register(
            reservedLabel,
            address(0),
            IRegistry(address(0)),
            address(1),
            0,
            uint64(block.timestamp + 1000)
        );
        rootRegistry.register(
            registeredLabel,
            tokenOwner,
            IRegistry(address(0)),
            address(1),
            TLD_ROLE_BITMAP,
            type(uint64).max
        );
        rootRegistry.register(
            assignedLabel,
            actor,
            IRegistry(address(0)),
            address(1),
            0,
            type(uint64).max
        );

        bytes[] memory names = new bytes[](4);
        names[0] = NameCoder.encode(availableLabel);
        names[1] = NameCoder.encode(reservedLabel);
        names[2] = NameCoder.encode(registeredLabel);
        names[3] = NameCoder.encode(assignedLabel);
        publicSuffixList.addPublicSuffixes(names);

        registrar = new TemporaryDNSRegistrar(
            address(this),
            rootRegistry,
            tokenOwner,
            publicSuffixList,
            dnsTLDResolver
        );

        vm.prank(tokenOwner);
        rootRegistry.setApprovalForAll(address(registrar), true);

        rootRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(registrar)
        );
    }

    function test_constructor() external view {
        assertEq(registrar.owner(), address(this), "owner");
        assertEq(address(registrar.ROOT_REGISTRY()), address(rootRegistry), "ROOT_REGISTRY");
        assertEq(address(registrar.TOKEN_OWNER()), address(tokenOwner), "TOKEN_OWNER");
        assertEq(
            address(registrar.PUBLIC_SUFFIX_LIST()),
            address(publicSuffixList),
            "PUBLIC_SUFFIX_LIST"
        );
        assertEq(registrar.defaultResolver(), dnsTLDResolver, "defaultResolver");
    }

    function test_TLD_ROLE_BITMAP_hasRequiredRoles() external pure {
        uint256 requiredRoleBitmap =
            RegistryRolesLib.ROLE_UNREGISTER | RegistryRolesLib.ROLE_UNREGISTER_ADMIN;
        assertEq(TLD_ROLE_BITMAP & requiredRoleBitmap, requiredRoleBitmap);
    }

    function test_setDefaultResolver(address resolver) external {
        registrar.setDefaultResolver(resolver);
        assertEq(registrar.defaultResolver(), resolver, "defaultResolver");

        registrar.syncTLD(availableLabel);
        assertEq(rootRegistry.getResolver(availableLabel), resolver);
    }

    function test_setDefaultResolver_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        vm.prank(actor);
        registrar.setDefaultResolver(dnsTLDResolver);
    }

    function test_syncTLDs() external {
        string[] memory labels = new string[](3);
        labels[0] = availableLabel;
        labels[1] = reservedLabel;
        labels[2] = registeredLabel;
        registrar.syncTLDs(labels);
        for (uint256 i; i < labels.length; ++i) {
            _checkSync(labels[i]);
        }
    }

    function test_syncTLD_empty() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        registrar.syncTLD("");
    }

    function test_syncTLD_notPublic() external {
        string[4] memory tlds = ["eth", "reverse", "__dne", "co.uk"];
        for (uint256 i; i < tlds.length; ++i) {
            assertFalse(publicSuffixList.isPublicSuffix(NameCoder.encode(tlds[i])));
            vm.expectRevert(
                abi.encodeWithSelector(TemporaryDNSRegistrar.TLDNotPublic.selector, tlds[i])
            );
            registrar.syncTLD(tlds[i]);
        }
    }

    function test_syncTLD_available() external {
        assertEq(
            uint8(rootRegistry.getStatus(LibLabel.id(availableLabel))),
            uint8(IPermissionedRegistry.Status.AVAILABLE),
            "before"
        );
        registrar.syncTLD(availableLabel);
        _checkSync(availableLabel);
    }

    function test_syncTLD_reserved() external {
        assertEq(
            uint8(rootRegistry.getStatus(LibLabel.id(reservedLabel))),
            uint8(IPermissionedRegistry.Status.RESERVED),
            "before"
        );
        registrar.syncTLD(reservedLabel);
        _checkSync(reservedLabel);
    }

    function test_syncTLD_registered() external {
        assertEq(rootRegistry.findOwner(registeredLabel), tokenOwner, "before");
        registrar.syncTLD(registeredLabel);
        _checkSync(registeredLabel);
    }

    function test_syncTLD_assigned() external {
        assertEq(rootRegistry.findOwner(assignedLabel), actor, "before");
        vm.expectRevert(
            abi.encodeWithSelector(TemporaryDNSRegistrar.TLDNotOwned.selector, assignedLabel, actor)
        );
        registrar.syncTLD(assignedLabel);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _checkSync(string memory label) internal view {
        IPermissionedRegistry.State memory state = rootRegistry.getState(LibLabel.id(label));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.REGISTERED), "status");
        assertEq(state.latestOwner, tokenOwner, "owner");
        assertEq(state.expiry, type(uint64).max, "expiry");
        assertEq(rootRegistry.getResolver(label), dnsTLDResolver, "resolver");
        assertEq(rootRegistry.roles(state.tokenId, tokenOwner), TLD_ROLE_BITMAP, "roles");
    }
}
