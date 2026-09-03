// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {GatewayProvider} from "@ens/contracts/ccipRead/GatewayProvider.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {DNSAliasResolver} from "~src/dns/DNSAliasResolver.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";

/// @dev Dedicated unit coverage for alias rewrite rules (no public DNS gateway).
contract DNSAliasResolverTest is Test {
    DNSAliasResolver aliasResolver;

    function setUp() external {
        LabelStore labelStore = new LabelStore(IContractNamer(address(0)));
        PermissionedRegistry root =
            new PermissionedRegistry(labelStore, address(this), EACBaseRolesLib.ALL_ROLES);
        GatewayProvider gateways = new GatewayProvider(address(this), new string[](0));
        aliasResolver = new DNSAliasResolver(root, gateways, IContractNamer(address(0)));
    }

    function test_rewrite_replaceEntireName() external view {
        bytes memory name = NameCoder.encode("example.com");
        bytes memory rewritten = aliasResolver.rewriteNameWithContext(name, bytes("alice.eth"));
        assertEq(rewritten, NameCoder.encode("alice.eth"));
    }

    function test_rewrite_suffixReplacement() external view {
        bytes memory name = NameCoder.encode("nick.com");
        bytes memory rewritten = aliasResolver.rewriteNameWithContext(name, bytes("com base.eth"));
        assertEq(rewritten, NameCoder.encode("nick.base.eth"));
    }

    function test_rewrite_suffixReplacement_subtree() external view {
        bytes memory name = NameCoder.encode("sub.nick.com");
        bytes memory rewritten = aliasResolver.rewriteNameWithContext(name, bytes("com base.eth"));
        assertEq(rewritten, NameCoder.encode("sub.nick.base.eth"));
    }

    function test_rewrite_revert_noSuffixMatch() external {
        bytes memory name = NameCoder.encode("example.org");
        vm.expectRevert(
            abi.encodeWithSelector(
                DNSAliasResolver.NoSuffixMatch.selector, name, NameCoder.encode("com")
            )
        );
        aliasResolver.rewriteNameWithContext(name, bytes("com base.eth"));
    }
}
