// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {
    INameWrapper,
    CAN_EXTEND_EXPIRY,
    CANNOT_BURN_FUSES,
    CANNOT_TRANSFER,
    CANNOT_SET_RESOLVER,
    CANNOT_CREATE_SUBDOMAIN,
    IS_DOT_ETH,
    PARENT_CANNOT_CONTROL
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {InvalidOwner} from "../CommonErrors.sol";
import {REGISTRATION_ROLE_BITMAP} from "../registrar/ETHRegistrar.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @title LockedWrappedReceiver
/// @dev AbstractWrapperReceiver for locked NameWrapper tokens.
///
/// There are (2) LockedWrapperReceiver implementations:
/// 1. LockedMigrationController only accepts .eth 2LD tokens.
/// 2. WrapperRegistry only accepts emancipated (N+1)-LD children with a matching N-LD parent node.
///
/// eg. transfer("nick.eth") => LockedMigrationController
///     ↪ ETHRegistry.subregistry("nick") = WrapperRegistry("nick.eth")
///     transfer("sub.nick.eth") => WrapperRegistry("nick.eth")
///     ↪ WrapperRegistry("nick.eth").subregistry("sub") = WrapperRegistry("sub.nick.eth")
///     transfer("abc.sub.nick.eth") => WrapperRegistry("sub.nick.eth")
///     ↪ WrapperRegistry("sub.nick.eth").subregistry("abc") = WrapperRegistry("abc.sub.nick.eth")
///
/// Upon successful migration:
/// * subregistry is bound to a WrapperRegistry (does not have `ROLE_SET_SUBREGISTRY`)
/// * subregistry is canonical (does not have `ROLE_SET_PARENT`) and knows its name
/// * subregistry migrates emancipated children with the same parent
///
abstract contract LockedWrapperReceiver is AbstractWrapperReceiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The shared factory for verifiable deployments.
    VerifiableFactory public immutable VERIFIABLE_FACTORY;

    /// @notice The `WrapperRegistry` implementation contract.
    address public immutable WRAPPER_REGISTRY_IMPL;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes LockedWrapperReceiver.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param graveyard The ENSv1 `BaseRegistrar` token graveyard.
    /// @param verifiableFactory The shared factory for verifiable deployments.
    /// @param wrapperRegistryImpl The `WrapperRegistry` implementation contract.
    constructor(
        INameWrapper nameWrapper,
        address graveyard,
        VerifiableFactory verifiableFactory,
        address wrapperRegistryImpl
    ) AbstractWrapperReceiver(nameWrapper, graveyard) {
        VERIFIABLE_FACTORY = verifiableFactory;
        WRAPPER_REGISTRY_IMPL = wrapperRegistryImpl;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Returns the DNS-encoded name for this registry.
    function getWrappedName() public view virtual returns (bytes memory) {
        return NAME_WRAPPER.names(getWrappedNode());
    }

    /// @notice Returns the NameWrapper node (namehash).
    function getWrappedNode() public view virtual returns (bytes32);

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractWrapperReceiver
    function _migrateWrapped(
        uint256[] calldata ids,
        LibMigration.Data[] calldata mds
    ) internal override {
        IRegistry parentRegistry = _getRegistry();
        bytes32 parentNode = getWrappedNode();
        for (uint256 i; i < ids.length; ++i) {
            LibMigration.Data memory md = mds[i];
            if (md.owner == address(0)) {
                revert InvalidOwner();
            }
            bytes32 node = bytes32(ids[i]);
            bytes32 labelHash = keccak256(bytes(md.label));
            if (node != NameCoder.namehash(parentNode, labelHash)) {
                revert LibMigration.NameDataMismatch(uint256(node));
            }
            // by construction: 1 <= length(label) <= 255
            // same as NameCoder.assertLabelSize()
            // see: V1Fixture.t.sol: `test_nameWrapper_labelTooShort()` and `test_nameWrapper_labelTooLong()`.

            (, uint32 fuses, uint64 expiry) = NAME_WRAPPER.getData(uint256(node));
            if (_isLocked(fuses)) {
                if (NAME_WRAPPER.getApproved(uint256(node)) != address(0)) {
                    revert LibMigration.FrozenTokenApproval(uint256(node));
                }

                if ((fuses & CANNOT_SET_RESOLVER) == 0) {
                    NAME_WRAPPER.setResolver(node, address(0)); // clear ENSv1 resolver
                } else {
                    md.resolver = _REGISTRY_V1.resolver(node); // replace with ENSv1 resolver
                }

                // create subregistry
                IRegistry subregistry = IRegistry(
                    VERIFIABLE_FACTORY.deployProxy(
                        WRAPPER_REGISTRY_IMPL,
                        uint256(node),
                        abi.encodeCall(
                            IWrapperRegistry.initialize,
                            (
                                node,
                                parentRegistry,
                                md.label,
                                md.owner,
                                _subregistryRoleBitmapFromFuses(fuses)
                            )
                        )
                    )
                );

                // add name to ENSv2
                // PermissionedRegistry._register() => CannotSetPastExpiry :: see expiry check
                // PermissionedRegistry._register() => LabelAlreadyRegistered :: only have ROLE_REGISTER_RESERVED
                // ERC1155._safeTransferFrom() => ERC1155InvalidReceiver :: see owner check
                _inject(
                    md.label,
                    md.owner,
                    subregistry,
                    md.resolver,
                    _tokenRoleBitmapFromFuses(fuses),
                    expiry
                );
            } else if (_isEmancipatedChild(fuses)) {
                NAME_WRAPPER.setResolver(node, address(0)); // clear ENSv1 resolver
                NAME_WRAPPER.unwrap(parentNode, labelHash, GRAVEYARD); // unwrap and transfer to graveyard

                // add name to ENSv2 (same as UnlockedMigrationController)
                _inject(
                    md.label,
                    md.owner,
                    md.subregistry,
                    md.resolver,
                    REGISTRATION_ROLE_BITMAP,
                    expiry
                );
            } else {
                revert LibMigration.NameNotLocked(uint256(node));
            }
        }
    }

    /// @dev Register a locked name.
    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) internal virtual returns (uint256 tokenId);

    /// @dev The ENSv2 registry being migrated to.
    function _getRegistry() internal view virtual returns (IRegistry);

    /// @dev Determine if `label` is emancipated but not-yet migrated.
    function _isMigratableChild(string memory label) internal view returns (bool) {
        bytes32 node = NameCoder.namehash(getWrappedNode(), keccak256(bytes(label)));
        (address ownerV1, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
        return ownerV1 != address(0) && ownerV1 != address(this) && _isEmancipatedChild(fuses);
    }

    /// @dev Returns `true` if the NameWrapper token fuses are not frozen.
    function _notFrozen(uint32 fuses) internal pure returns (bool) {
        return (fuses & CANNOT_BURN_FUSES) == 0;
    }

    /// @dev Returns `true` if the NameWrapper token is emancipated and not 2LD .eth.
    function _isEmancipatedChild(uint32 fuses) internal pure returns (bool) {
        // PARENT_CANNOT_CONTROL must be set for the entire ancestory.
        // see: V1Fixture.t.sol: `test_nameWrapper_PARENT_CANNOT_CONTROL_withoutParent()`
        return (fuses & (IS_DOT_ETH | PARENT_CANNOT_CONTROL)) == PARENT_CANNOT_CONTROL;
    }

    /// @dev Convert fuses to equivalent subregistry root roles.
    function _subregistryRoleBitmapFromFuses(
        uint32 fuses
    ) internal pure returns (uint256 roleBitmap) {
        if ((fuses & CANNOT_CREATE_SUBDOMAIN) == 0) {
            roleBitmap |= RegistryRolesLib.ROLE_REGISTRAR;
        }
        if (_notFrozen(fuses)) {
            roleBitmap |= roleBitmap << 128; // give admin
        }
        roleBitmap |= RegistryRolesLib.ROLE_RENEW | RegistryRolesLib.ROLE_RENEW_ADMIN;
    }

    /// @dev Convert fuses to equivalent token roles.
    function _tokenRoleBitmapFromFuses(uint32 fuses) internal pure returns (uint256 roleBitmap) {
        if ((fuses & CAN_EXTEND_EXPIRY) != 0) {
            roleBitmap |= RegistryRolesLib.ROLE_RENEW;
        }
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            roleBitmap |= RegistryRolesLib.ROLE_SET_RESOLVER;
        }
        if (_notFrozen(fuses)) {
            roleBitmap |= roleBitmap << 128; // give admin
        }
        if ((fuses & CANNOT_TRANSFER) == 0) {
            roleBitmap |= RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        }
    }
}
