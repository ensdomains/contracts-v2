// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {SimplePublicSuffixList} from "@ens/contracts/dnsregistrar/SimplePublicSuffixList.sol";

import {TemporaryDNSRegistrar} from "~src/dns/TemporaryDNSRegistrar.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract TemporaryDNSRegistrarTest is V2Fixture {
    SimplePublicSuffixList publicSuffixList;
    TemporaryDNSRegistrar registrar;
    address dnsTLDResolver = makeAddr("DNSTLDResolver");
    address tokenOwner = makeAddr("TokenOwner");
    bytes[] names;

    function setUp() external {
        deployV2Fixture();

        names.push(NameCoder.encode("com"));
        names.push(NameCoder.encode("ens"));

        publicSuffixList = new SimplePublicSuffixList();
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

    function test_setDefaultResolver() external {
        registrar.setDefaultResolver(dnsTLDResolver);
    }

    function test_setDefaultResolver_notAuthorized() external {
        address actor = makeAddr("actor");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        vm.prank(actor);
        registrar.setDefaultResolver(dnsTLDResolver);
    }

    function test_syncSuffixes(bool multi) external {
        if (multi)
            registrar.syncSuffixes(names);

        for (uint256 i; i < names.length; ++i) {
            if (!multi)
                registrar.syncSuffix(names[i]);

            string memory label = NameCoder.firstLabel(names[i]);
            IPermissionedRegistry.State memory state = rootRegistry.getState(LibLabel.id(label));

            assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.REGISTERED), "status");
            assertEq(state.latestOwner, tokenOwner, "owner");
            assertEq(rootRegistry.getResolver(label), dnsTLDResolver, "resolver");
        }
    }

    function test_syncSuffixes_notTLD(bool multi) external {
        bytes memory invalidName = NameCoder.encode("co.uk");

        bytes[] memory invalidNames = new bytes[](1);
        invalidNames[0] = invalidName;
        publicSuffixList.addPublicSuffixes(invalidNames);

        vm.expectRevert(
            abi.encodeWithSelector(TemporaryDNSRegistrar.InvalidSuffix.selector, invalidName)
        );
        if (multi) {
            registrar.syncSuffixes(invalidNames);
        } else {
            registrar.syncSuffix(invalidName);
        }
    }
}
