// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {RegistryHelper} from "~src/utils/RegistryHelper.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract RegistryHelperTest is V2Fixture {
    RegistryHelper helper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address resolver1 = makeAddr("resolver1");

    uint256 constant REGISTRATION_ROLES =
        RegistryRolesLib.ROLE_SET_SUBREGISTRY |
        RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN |
        RegistryRolesLib.ROLE_SET_RESOLVER |
        RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
        RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;

    function setUp() external {
        deployV2Fixture();
        helper = new RegistryHelper(
            rootRegistry,
            ethRegistry,
            verifiableFactory,
            address(userRegistryImpl),
            address(0) // no WrapperRegistry impl for now
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // findOwner
    ////////////////////////////////////////////////////////////////////////

    function test_findOwner_eth() external view {
        assertEq(helper.findOwner(NameCoder.encode("eth")), address(this));
    }

    function test_findOwner_registered() external {
        _registerOnEth("alice", alice);
        assertEq(helper.findOwner(NameCoder.encode("alice.eth")), alice);
    }

    function test_findOwner_unregistered() external view {
        assertEq(helper.findOwner(NameCoder.encode("nobody.eth")), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // findExpiry
    ////////////////////////////////////////////////////////////////////////

    function test_findExpiry_registered() external {
        _registerOnEth("alice", alice);
        uint64 expiry = helper.findExpiry(NameCoder.encode("alice.eth"));
        assertEq(expiry, uint64(block.timestamp + 365 days));
    }

    function test_findExpiry_unregistered() external view {
        assertEq(helper.findExpiry(NameCoder.encode("nobody.eth")), 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // isCanonical
    ////////////////////////////////////////////////////////////////////////

    function test_isCanonical_eth() external view {
        assertTrue(helper.isCanonical(NameCoder.encode("eth")));
    }

    function test_isCanonical_withSubregistry() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");
        assertTrue(helper.isCanonical(NameCoder.encode("alice.eth")));
    }

    function test_isCanonical_noSubregistry() external {
        _registerOnEth("alice", alice);
        assertFalse(helper.isCanonical(NameCoder.encode("alice.eth")));
    }

    ////////////////////////////////////////////////////////////////////////
    // isVerified (name-based)
    ////////////////////////////////////////////////////////////////////////

    function test_isVerified_eth() external view {
        assertTrue(helper.isVerified(NameCoder.encode("eth")));
    }

    function test_isVerified_aliceEth() external {
        _registerOnEth("alice", alice);
        // eth registry is trusted by endorsement (direct child of root)
        assertTrue(helper.isVerified(NameCoder.encode("alice.eth")));
    }

    function test_isVerified_threeLevel_factoryDeployed() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        vm.prank(alice);
        aliceRegistry.register(
            "sub",
            bob,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLES,
            uint64(block.timestamp + 365 days)
        );

        // alice's UserRegistry was deployed via VerifiableFactory
        assertTrue(helper.isVerified(NameCoder.encode("sub.alice.eth")));
    }

    ////////////////////////////////////////////////////////////////////////
    // isEmancipated (name-based)
    ////////////////////////////////////////////////////////////////////////

    function test_isEmancipated_eth() external view {
        assertTrue(helper.isEmancipated(NameCoder.encode("eth")));
    }

    function test_isEmancipated_aliceEth() external {
        _registerOnEth("alice", alice);
        // eth registry has no dangerous roles on ROOT_RESOURCE
        assertTrue(helper.isEmancipated(NameCoder.encode("alice.eth")));
    }

    function test_isEmancipated_failsWithDangerousRoles() external {
        // alice's UserRegistry has ALL_ROLES for alice on ROOT, including dangerous roles
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        vm.prank(alice);
        aliceRegistry.register(
            "sub",
            bob,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLES,
            uint64(block.timestamp + 365 days)
        );

        // sub.alice.eth is NOT emancipated because alice's registry has dangerous roles
        assertFalse(helper.isEmancipated(NameCoder.encode("sub.alice.eth")));
    }

    function test_isEmancipated_afterRevokingDangerousRoles() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        vm.prank(alice);
        aliceRegistry.register(
            "sub",
            bob,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLES,
            uint64(block.timestamp + 365 days)
        );

        assertFalse(helper.isEmancipated(NameCoder.encode("sub.alice.eth")));

        // Revoke all dangerous roles from alice's registry
        uint256 dangerousRoles = helper.DANGEROUS_ROOT_ROLES();
        vm.prank(alice);
        aliceRegistry.revokeRootRoles(dangerousRoles, alice);

        assertTrue(helper.isEmancipated(NameCoder.encode("sub.alice.eth")));
    }

    ////////////////////////////////////////////////////////////////////////
    // isVerified / isEmancipated (registry-based)
    ////////////////////////////////////////////////////////////////////////

    function test_isVerified_registry_factoryDeployed() external {
        UserRegistry aliceRegistry = deployUserRegistry(alice, EACBaseRolesLib.ALL_ROLES, 1);
        assertTrue(helper.isVerified(IRegistry(address(aliceRegistry))));
    }

    function test_isVerified_registry_ethRegistry() external view {
        // ethRegistry is not factory-deployed but trusted as infrastructure
        assertTrue(helper.isVerified(IRegistry(address(ethRegistry))));
    }

    function test_isVerified_registry_rootRegistry() external view {
        assertTrue(helper.isVerified(IRegistry(address(rootRegistry))));
    }

    function test_isVerified_registry_untrusted() external view {
        assertFalse(helper.isVerified(IRegistry(address(0xdead))));
    }

    function test_isEmancipated_registry_withDangerousRoles() external {
        UserRegistry aliceRegistry = deployUserRegistry(alice, EACBaseRolesLib.ALL_ROLES, 2);
        assertFalse(helper.isEmancipated(IRegistry(address(aliceRegistry))));
    }

    function test_isEmancipated_registry_afterRevoke() external {
        UserRegistry aliceRegistry = deployUserRegistry(alice, EACBaseRolesLib.ALL_ROLES, 3);

        uint256 dangerousRoles = helper.DANGEROUS_ROOT_ROLES();
        vm.prank(alice);
        aliceRegistry.revokeRootRoles(dangerousRoles, alice);

        assertTrue(helper.isEmancipated(IRegistry(address(aliceRegistry))));
    }

    ////////////////////////////////////////////////////////////////////////
    // getLabels
    ////////////////////////////////////////////////////////////////////////

    function test_getLabels_eth() external view {
        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("eth"));

        assertEq(labels.length, 1);
        assertEq(labels[0].label, "eth");
        assertEq(address(labels[0].registry), address(ethRegistry));
        assertEq(labels[0].owner, address(this));
        assertTrue(labels[0].flags & helper.FLAG_HAS_OWNER() != 0, "FLAG_HAS_OWNER");
        assertTrue(labels[0].flags & helper.FLAG_HAS_EXPIRY() != 0, "FLAG_HAS_EXPIRY");
        assertTrue(labels[0].flags & helper.FLAG_IS_VERIFIED() != 0, "FLAG_IS_VERIFIED");
        assertTrue(labels[0].flags & helper.FLAG_IS_CANONICAL() != 0, "FLAG_IS_CANONICAL");
        assertTrue(labels[0].flags & helper.FLAG_IS_EMANCIPATED() != 0, "FLAG_IS_EMANCIPATED");
    }

    function test_getLabels_aliceEth() external {
        _registerOnEth("alice", alice);

        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("alice.eth"));

        assertEq(labels.length, 2);

        // labels[0] = "alice" (leaf)
        assertEq(labels[0].label, "alice");
        assertEq(labels[0].owner, alice);
        assertTrue(labels[0].flags & helper.FLAG_HAS_OWNER() != 0, "alice:FLAG_HAS_OWNER");
        assertTrue(labels[0].flags & helper.FLAG_IS_VERIFIED() != 0, "alice:FLAG_IS_VERIFIED");
        assertTrue(labels[0].flags & helper.FLAG_IS_EMANCIPATED() != 0, "alice:FLAG_IS_EMANCIPATED");

        // labels[1] = "eth"
        assertEq(labels[1].label, "eth");
        assertTrue(labels[1].flags & helper.FLAG_IS_VERIFIED() != 0, "eth:FLAG_IS_VERIFIED");
        assertTrue(labels[1].flags & helper.FLAG_IS_EMANCIPATED() != 0, "eth:FLAG_IS_EMANCIPATED");
    }

    function test_getLabels_dangerousRoles_affectsEmancipation() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        vm.prank(alice);
        aliceRegistry.register(
            "sub",
            bob,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLES,
            uint64(block.timestamp + 365 days)
        );

        RegistryHelper.LabelInfo[] memory labels =
            helper.getLabels(NameCoder.encode("sub.alice.eth"));

        // sub's parent (alice's registry) has dangerous roles on ROOT_RESOURCE
        assertTrue(labels[0].flags & helper.FLAG_IS_VERIFIED() != 0, "sub:FLAG_IS_VERIFIED");
        assertFalse(
            labels[0].flags & helper.FLAG_IS_EMANCIPATED() != 0,
            "sub:FLAG_IS_EMANCIPATED should be false"
        );

        // alice's parent (ethRegistry) has no dangerous roles
        assertTrue(labels[1].flags & helper.FLAG_IS_EMANCIPATED() != 0, "alice:FLAG_IS_EMANCIPATED");

        // eth is governed by root (trusted unconditionally)
        assertTrue(labels[2].flags & helper.FLAG_IS_EMANCIPATED() != 0, "eth:FLAG_IS_EMANCIPATED");
    }

    function test_getLabels_expiredName() external {
        _registerOnEth("alice", alice);

        vm.warp(block.timestamp + 366 days);

        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("alice.eth"));

        assertEq(labels[0].owner, address(0));
        assertFalse(labels[0].flags & helper.FLAG_HAS_OWNER() != 0, "expired:FLAG_HAS_OWNER");
        assertFalse(labels[0].flags & helper.FLAG_HAS_TOKEN() != 0, "expired:FLAG_HAS_TOKEN");
        assertEq(labels[0].tokenId, 0, "expired:tokenId should be zero");
        assertTrue(labels[0].expiry != 0, "expired:expiry nonzero");
        assertTrue(labels[0].flags & helper.FLAG_HAS_EXPIRY() != 0, "expired:FLAG_HAS_EXPIRY");
    }

    function test_getLabels_unregisteredName_noToken() external view {
        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("nobody.eth"));

        assertEq(labels[0].owner, address(0));
        assertFalse(labels[0].flags & helper.FLAG_HAS_OWNER() != 0, "unregistered:FLAG_HAS_OWNER");
        assertFalse(labels[0].flags & helper.FLAG_HAS_TOKEN() != 0, "unregistered:FLAG_HAS_TOKEN");
        assertEq(labels[0].tokenId, 0, "unregistered:tokenId should be zero");
    }

    function test_getLabels_registeredName_hasToken() external {
        _registerOnEth("alice", alice);

        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("alice.eth"));

        assertTrue(labels[0].flags & helper.FLAG_HAS_OWNER() != 0, "registered:FLAG_HAS_OWNER");
        assertTrue(labels[0].flags & helper.FLAG_HAS_TOKEN() != 0, "registered:FLAG_HAS_TOKEN");
        assertTrue(labels[0].tokenId != 0, "registered:tokenId should be nonzero");
    }

    function test_getLabels_threeLevel() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        vm.prank(alice);
        aliceRegistry.register(
            "sub",
            bob,
            IRegistry(address(0)),
            resolver1,
            REGISTRATION_ROLES,
            uint64(block.timestamp + 180 days)
        );

        RegistryHelper.LabelInfo[] memory labels =
            helper.getLabels(NameCoder.encode("sub.alice.eth"));

        assertEq(labels.length, 3);
        assertEq(labels[0].label, "sub");
        assertEq(labels[0].owner, bob);
        assertEq(labels[0].resolver, resolver1);
        assertEq(labels[1].label, "alice");
        assertEq(labels[1].owner, alice);
        assertEq(labels[2].label, "eth");
    }

    function test_getLabels_rootName() external view {
        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode(""));
        assertEq(labels.length, 0);
    }

    function test_getLabels_canonical_missingSetParent() external {
        // Deploy subregistry but never call setParent
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);

        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("alice.eth"));

        // Forward link exists (ethRegistry.getSubregistry("alice") == aliceRegistry)
        // but reverse link is missing (aliceRegistry.getParent() == (address(0), ""))
        assertEq(address(labels[0].registry), address(aliceRegistry), "subregistry should be set");
        assertFalse(
            labels[0].flags & helper.FLAG_IS_CANONICAL() != 0,
            "canonical:missing setParent should not be canonical"
        );
    }

    function test_getLabels_canonical_wrongParentLabel() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        // setParent with wrong label
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "bob");

        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("alice.eth"));

        assertFalse(
            labels[0].flags & helper.FLAG_IS_CANONICAL() != 0,
            "canonical:wrong label should not be canonical"
        );
    }

    function test_getLabels_canonical_wrongParentRegistry() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        // setParent pointing to wrong registry
        vm.prank(alice);
        aliceRegistry.setParent(rootRegistry, "alice");

        RegistryHelper.LabelInfo[] memory labels = helper.getLabels(NameCoder.encode("alice.eth"));

        assertFalse(
            labels[0].flags & helper.FLAG_IS_CANONICAL() != 0,
            "canonical:wrong parent registry should not be canonical"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // findCanonicalName / findCanonicalRegistry
    ////////////////////////////////////////////////////////////////////////

    function test_findCanonicalName() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        bytes memory name = helper.findCanonicalName(IRegistry(address(aliceRegistry)));
        assertEq(name, NameCoder.encode("alice.eth"));
    }

    function test_findCanonicalRegistry() external {
        UserRegistry aliceRegistry = _registerWithSubregistry("alice", alice);
        vm.prank(alice);
        aliceRegistry.setParent(ethRegistry, "alice");

        IRegistry found = helper.findCanonicalRegistry(NameCoder.encode("alice.eth"));
        assertEq(address(found), address(aliceRegistry));
    }

    ////////////////////////////////////////////////////////////////////////
    // Edge cases
    ////////////////////////////////////////////////////////////////////////

    function test_isVerified_rootName() external view {
        assertTrue(helper.isVerified(NameCoder.encode("")));
    }

    function test_isEmancipated_rootName() external view {
        assertTrue(helper.isEmancipated(NameCoder.encode("")));
    }

    function test_getLabels_brokenChain() external view {
        // sub.nobody.eth: "nobody" is not registered, so the chain breaks
        RegistryHelper.LabelInfo[] memory labels =
            helper.getLabels(NameCoder.encode("sub.nobody.eth"));

        assertEq(labels.length, 3);

        // sub: parent is address(0) (nobody has no subregistry), all fields zero
        assertEq(labels[0].label, "sub");
        assertEq(labels[0].owner, address(0));
        assertEq(labels[0].flags, 0, "sub: no flags on broken chain");

        // nobody: parent is ethRegistry, name is not registered but no revert
        assertEq(labels[1].label, "nobody");
        assertEq(labels[1].owner, address(0));
        assertFalse(labels[1].flags & helper.FLAG_HAS_OWNER() != 0, "nobody:FLAG_HAS_OWNER");
        assertTrue(labels[1].flags & helper.FLAG_IS_VERIFIED() != 0, "nobody:FLAG_IS_VERIFIED");
        assertTrue(labels[1].flags & helper.FLAG_IS_EMANCIPATED() != 0, "nobody:FLAG_IS_EMANCIPATED");

        // eth: normal
        assertEq(labels[2].label, "eth");
        assertTrue(labels[2].flags & helper.FLAG_IS_VERIFIED() != 0, "eth:FLAG_IS_VERIFIED");
    }

    function test_isVerified_brokenChain() external view {
        // sub.nobody.eth: chain breaks at nobody (no subregistry)
        // registries = [address(0), address(0), ethRegistry, rootRegistry]
        // Loop checks registries[1] = address(0) -> not verified
        assertFalse(helper.isVerified(NameCoder.encode("sub.nobody.eth")));
    }

    function test_isEmancipated_brokenChain() external view {
        assertFalse(helper.isEmancipated(NameCoder.encode("sub.nobody.eth")));
    }

    function test_isVerified_unregistered() external view {
        // nobody.eth: name doesn't exist but registry chain (ethRegistry) is valid
        assertTrue(helper.isVerified(NameCoder.encode("nobody.eth")));
    }

    function test_isEmancipated_unregistered() external view {
        // nobody.eth: name doesn't exist but registry chain is emancipated
        assertTrue(helper.isEmancipated(NameCoder.encode("nobody.eth")));
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _registerOnEth(string memory label, address owner) internal {
        ethRegistry.register(
            label,
            owner,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLES,
            uint64(block.timestamp + 365 days)
        );
    }

    function _registerWithSubregistry(string memory label, address owner)
        internal
        returns (UserRegistry registry)
    {
        registry = deployUserRegistry(
            owner,
            EACBaseRolesLib.ALL_ROLES,
            uint256(keccak256(bytes(label)))
        );

        ethRegistry.register(
            label,
            owner,
            IRegistry(address(registry)),
            address(0),
            REGISTRATION_ROLES,
            uint64(block.timestamp + 365 days)
        );
    }
}
