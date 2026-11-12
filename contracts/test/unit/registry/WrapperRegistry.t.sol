// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {PARENT_CANNOT_CONTROL} from "@ens/contracts/wrapper/NameWrapper.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {LibMigration} from "~src/migration/libraries/LibMigration.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {
    IWrapperRegistryInitializable
} from "~src/registry/interfaces/IWrapperRegistryInitializable.sol";
import {WrapperRegistry} from "~src/registry/WrapperRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PublicResolverV2} from "~src/resolver/PublicResolverV2.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";

/// @dev An emancipated subname whose token is gone (its owner unwrapped it) has no wrapped token to
/// migrate, so only the v1 owner may recreate the label, and only as itself.
contract WrapperRegistryTest is MigrationControllerFixture {
    WrapperRegistry wrapperRegistryImpl;
    PublicResolverV2 publicResolver;

    address childOwner = makeAddr("childOwner");

    string constant PARENT_LABEL = "parent";
    string constant CHILD_LABEL = "child";

    /// @dev Creates an emancipated child owned by `childOwner`, then burns its token.
    function _unwrappedEmancipatedChild(bytes memory parentName, bytes32 parentNode)
        internal
        returns (bytes32 childNode)
    {
        bytes memory childName = createWrappedChild(parentName, CHILD_LABEL, PARENT_CANNOT_CONTROL);
        childNode = NameCoder.namehash(childName, 0);
        vm.prank(testOwner);
        nameWrapper.safeTransferFrom(testOwner, childOwner, uint256(childNode), 1, "");
        assertEq(nameWrapper.ownerOf(uint256(childNode)), childOwner, "childOwner holds the token");

        vm.prank(childOwner);
        nameWrapper.unwrap(parentNode, keccak256(bytes(CHILD_LABEL)), childOwner);
        assertEq(nameWrapper.ownerOf(uint256(childNode)), address(0), "no token left to migrate");
    }

    function setUp() public {
        deployMigrationControllerFixture();

        publicResolver = new PublicResolverV2(nameWrapper, rootRegistry, contractNamer);
        wrapperRegistryImpl = new WrapperRegistry(
            nameWrapper,
            address(graveyard),
            verifiableFactory,
            address(ensV1Resolver),
            registryUpgradeSet,
            labelStore,
            boxedRenderer,
            publicResolverSet,
            address(publicResolver),
            address(this)
        );
    }

    /// @dev The parent is wrapped with `CANNOT_UNWRAP` because the wrapper only lets a parent
    ///      emancipate a child when the parent itself can never be unwrapped.
    function _wrappedParent() internal returns (bytes memory name, bytes32 node) {
        name = registerWrappedETH2LD(PARENT_LABEL, 1);
        node = NameCoder.namehash(name, 0);
    }

    /// @dev Deploys the parent's subregistry and registers the parent label in the ETH registry.
    function _wrapperRegistry(bytes32 parentNode) internal returns (WrapperRegistry) {
        address proxy =
            verifiableFactory.deployProxy(
                address(wrapperRegistryImpl),
                uint256(parentNode),
                abi.encodeCall(IWrapperRegistryInitializable.initialize, (parentNode, ethRegistry))
            );
        // The premigration reserved the parent label, so claiming it needs that role.
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTER_RESERVED, premigrationController);
        vm.prank(premigrationController);
        ethRegistry.register(PARENT_LABEL, testOwner, IRegistry(proxy), address(0), 0, _soon());
        return WrapperRegistry(proxy);
    }

    /// @dev The owner of an emancipated child can recreate the label after unwrapping it, and the
    ///      parent's owner cannot take it in the process.
    function test_emancipatedChildWithoutTokenIsClaimedOnlyByItsV1Owner() external {
        (bytes memory parentName, bytes32 parentNode) = _wrappedParent();
        WrapperRegistry wrapper = _wrapperRegistry(parentNode);

        // An emancipated child exists in v1, is handed to `childOwner` and unwrapped by them.
        bytes32 childNode = _unwrappedEmancipatedChild(parentName, parentNode);
        (, uint32 fuses, ) = nameWrapper.getData(uint256(childNode));
        assertTrue(fuses & PARENT_CANNOT_CONTROL == PARENT_CANNOT_CONTROL, "still emancipated");

        // The parent's owner cannot claim the label.
        vm.expectRevert(LibMigration.NameRequiresMigration.selector);
        vm.prank(testOwner);
        wrapper.register(CHILD_LABEL, testOwner, IRegistry(address(0)), address(0), 0, _soon());

        // The v1 owner recreates it, as itself, regardless of the owner argument.
        vm.prank(childOwner);
        uint256 tokenId =
            wrapper.register(CHILD_LABEL, testOwner, IRegistry(address(0)), address(0), 0, _soon());
        assertEq(wrapper.ownerOf(tokenId), childOwner, "the v1 owner keeps the name");
    }

    /// @dev While the token exists, the label still requires migration and cannot be registered.
    function test_wrappedEmancipatedChildStillRequiresMigration() external {
        (bytes memory parentName, bytes32 parentNode) = _wrappedParent();
        WrapperRegistry wrapper = _wrapperRegistry(parentNode);

        createWrappedChild(parentName, CHILD_LABEL, PARENT_CANNOT_CONTROL);

        vm.expectRevert(LibMigration.NameRequiresMigration.selector);
        vm.prank(childOwner);
        wrapper.register(CHILD_LABEL, childOwner, IRegistry(address(0)), address(0), 0, _soon());
    }
}
