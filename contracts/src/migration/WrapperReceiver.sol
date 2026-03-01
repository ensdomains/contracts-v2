// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {
    INameWrapper,
    CAN_EXTEND_EXPIRY,
    CANNOT_UNWRAP,
    CANNOT_BURN_FUSES,
    CANNOT_TRANSFER,
    CANNOT_SET_RESOLVER,
    CANNOT_SET_TTL,
    CANNOT_CREATE_SUBDOMAIN
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IWrapperRegistry, MIN_DATA_SIZE} from "../registry/interfaces/IWrapperRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {WrappedErrorLib} from "../utils/WrappedErrorLib.sol";

import {MigrationErrors} from "./MigrationErrors.sol";

/// @dev Fuses which translate directly to PermissionedRegistry logic.
uint32 constant FUSES_TO_BURN = CANNOT_BURN_FUSES |
    CANNOT_TRANSFER |
    CANNOT_SET_RESOLVER |
    CANNOT_SET_TTL |
    CANNOT_CREATE_SUBDOMAIN;

/// @title WrappedReceiver
/// @notice Abstract IERC1155Receiver which handles NameWrapper token migration via transfer.
///         Contains of all of the NameWrapper logic.
///
/// There are (2) WrapperReceivers:
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
/// * subregistry is bound to a WrapperRegistry (token does not have `SET_SUBREGISTRY` role)
/// * subregistry knows the parent node (namehash)
/// * subregistry migrates children of the same parent
///
/// @dev Interface selector: `0x1a4ec815`
abstract contract WrapperReceiver is ERC165, IERC1155Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    INameWrapper public immutable NAME_WRAPPER;
    VerifiableFactory public immutable VERIFIABLE_FACTORY;
    address public immutable WRAPPER_REGISTRY_IMPL;

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Restrict `msg.sender` to `NAME_WRAPPER`.
    ///      Reverts wrapped errors for use inside of legacy IERC1155Receiver handler.
    modifier onlyWrapper() {
        if (msg.sender != address(NAME_WRAPPER)) {
            WrappedErrorLib.wrapAndRevert(
                abi.encodeWithSelector(UnauthorizedCaller.selector, msg.sender)
            );
        }
        _;
    }

    /// @dev Avoid `abi.decode()` failure for obviously invalid data.
    ///      Reverts wrapped errors for use inside of legacy IERC1155Receiver handler.
    modifier withData(bytes calldata data, uint256 minimumSize) {
        if (data.length < minimumSize) {
            WrappedErrorLib.wrapAndRevert(
                abi.encodeWithSelector(IWrapperRegistry.InvalidData.selector)
            );
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        INameWrapper nameWrapper,
        VerifiableFactory verifiableFactory,
        address wrapperRegistryImpl
    ) {
        NAME_WRAPPER = nameWrapper;
        VERIFIABLE_FACTORY = verifiableFactory;
        WRAPPER_REGISTRY_IMPL = wrapperRegistryImpl;
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(WrapperReceiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IERC1155Receiver
    /// @notice Migrate one NameWrapper token via `safeTransferFrom()`.
    ///         Requires `abi.encode(IWrapperRegistry.Data)` as payload.
    ///         Reverts require `WrappedErrorLib.unwrap()` before processing.
    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 id,
        uint256 /*amount*/,
        bytes calldata data
    ) external onlyWrapper withData(data, MIN_DATA_SIZE) returns (bytes4) {
        uint256[] memory ids = new uint256[](1);
        IWrapperRegistry.Data[] memory mds = new IWrapperRegistry.Data[](1);
        ids[0] = id;
        mds[0] = abi.decode(data, (IWrapperRegistry.Data)); // reverts if invalid
        try this.finishERC1155Migration(ids, mds) {
            return this.onERC1155Received.selector;
        } catch (bytes memory reason) {
            WrappedErrorLib.wrapAndRevert(reason); // convert all errors to wrapped
        }
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Migrate multiple NameWrapper tokens via `safeBatchTransferFrom()`.
    ///         Requires `abi.encode(IWrapperRegistry.Data[])` as payload.
    ///         Reverts require `WrappedErrorLib.unwrap()` before processing.
    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata ids,
        uint256[] calldata /*amounts*/,
        bytes calldata data
    ) external onlyWrapper withData(data, 64 + ids.length * MIN_DATA_SIZE) returns (bytes4) {
        // never happens: caught by ERC1155Fuse
        // if (ids.length != amounts.length) {
        //     revert IERC1155Errors.ERC1155InvalidArrayLength(ids.length, amounts.length);
        // }
        IWrapperRegistry.Data[] memory mds = abi.decode(data, (IWrapperRegistry.Data[])); // reverts if invalid
        try this.finishERC1155Migration(ids, mds) {
            return this.onERC1155BatchReceived.selector;
        } catch (bytes memory reason) {
            WrappedErrorLib.wrapAndRevert(reason); // convert all errors to wrapped
        }
    }

    /// @dev Convert NameWrapper tokens their equivalent ENSv2 form.
    ///      Only callable by ourself and invoked in our `IERC1155Receiver` handlers.
    ///
    /// TODO: gas analysis and optimization
    /// NOTE: converting this to an internal call requires catching many reverts
    function finishERC1155Migration(
        uint256[] calldata ids,
        IWrapperRegistry.Data[] calldata mds
    ) external {
        if (msg.sender != address(this)) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (ids.length != mds.length) {
            revert IERC1155Errors.ERC1155InvalidArrayLength(ids.length, mds.length);
        }
        bytes32 parentNode = _parentNode();
        for (uint256 i; i < ids.length; ++i) {
            // never happens: caught by ERC1155Fuse
            // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L182
            // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L293
            // if (amounts[i] != 1) { ... }
            IWrapperRegistry.Data memory md = mds[i];
            if (md.owner == address(0)) {
                revert IERC1155Errors.ERC1155InvalidReceiver(md.owner);
            }
            bytes32 node = bytes32(ids[i]);
            bytes32 labelHash = keccak256(bytes(md.label));
            if (node != NameCoder.namehash(parentNode, labelHash)) {
                revert MigrationErrors.NameDataMismatch(uint256(node));
            }
            // by construction: 1 <= length(label) <= 255
            // same as NameCoder.assertLabelSize()
            // see: V1Fixture.t.sol: `test_nameWrapper_labelTooShort()` and `test_nameWrapper_labelTooLong()`.

            (address owner, uint32 fuses, uint64 expiry) = NAME_WRAPPER.getData(uint256(node));
            assert(owner == address(this)); // claim: only we can call this function => we own the token
            assert(expiry >= block.timestamp); // claim: expired names cannot be transferred

            // PARENT_CANNOT_CONTROL is required to set CANNOT_UNWRAP, so CANNOT_UNWRAP is sufficient
            // see: V1Fixture.t.sol: `test_nameWrapper_CANNOT_UNWRAP_requires_PARENT_CANNOT_CONTROL()`
            if ((fuses & CANNOT_UNWRAP) == 0) {
                revert MigrationErrors.NameNotLocked(uint256(node));
            }

            if ((fuses & CANNOT_SET_RESOLVER) != 0) {
                md.resolver = NAME_WRAPPER.ens().resolver(node); // replace with V1 resolver
            } else {
                NAME_WRAPPER.setResolver(node, address(0)); // clear V1 resolver
            }

            (
                bool fusesFrozen,
                uint256 tokenRoles,
                uint256 registryRoles
            ) = _generateRoleBitmapsFromFuses(fuses);
            // PermissionedRegistry._register() => _grantRoles() => _checkRoleBitmap() :: roles are correct by construction

            // create subregistry
            IRegistry subregistry = IRegistry(
                VERIFIABLE_FACTORY.deployProxy(
                    WRAPPER_REGISTRY_IMPL,
                    md.salt,
                    abi.encodeCall(
                        IWrapperRegistry.initialize,
                        (
                            IWrapperRegistry.ConstructorArgs({
                                node: node,
                                owner: md.owner,
                                ownerRoles: registryRoles
                            })
                        )
                    )
                )
            );

            // add name to V2
            _inject(md.label, md.owner, subregistry, md.resolver, tokenRoles, expiry);
            // PermissionedRegistry._register() => CannotSetPastExpiration :: see expiry check
            // PermissionedRegistry._register() => NameAlreadyRegistered :: only have ROLE_REGISTER_RESERVED
            // ERC1155._safeTransferFrom() => ERC1155InvalidReceiver :: see owner check

            // Burn all migration fuses
            if (!fusesFrozen) {
                NAME_WRAPPER.setFuses(node, uint16(FUSES_TO_BURN));
            }
        }
    }

    /// @notice The DNS-encoded name of the parent registry.
    function parentName() external view returns (bytes memory) {
        return NAME_WRAPPER.names(_parentNode());
    }

    /// @dev Abstract function for registering a locked name.
    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) internal virtual returns (uint256 tokenId);

    /// @dev Abstract function for the node (namehash) of the parent registry.
    ///      Equivalent to token ID of the parent NameWrapper token.
    function _parentNode() internal view virtual returns (bytes32);

    /// @dev Determine if `label` is emancipated but not-yet migrated.
    function _isMigratableChild(string memory label) internal view returns (bool) {
        bytes32 node = NameCoder.namehash(_parentNode(), keccak256(bytes(label)));
        (address ownerV1, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
        return ownerV1 != address(this) && (fuses & CANNOT_UNWRAP) != 0;
    }

    /// @notice Generates role bitmaps based on fuses.
    /// @param fuses The current fuses on the name
    /// @return fusesFrozen True if fuses are frozen.
    /// @return tokenRoles The token roles in parent registry.
    /// @return registryRoles The root roles in token subregistry.
    function _generateRoleBitmapsFromFuses(
        uint32 fuses
    ) internal pure returns (bool fusesFrozen, uint256 tokenRoles, uint256 registryRoles) {
        // Check if fuses are permanently frozen
        fusesFrozen = (fuses & CANNOT_BURN_FUSES) != 0;

        // Include renewal permissions if expiry can be extended
        if ((fuses & CAN_EXTEND_EXPIRY) != 0) {
            tokenRoles |= RegistryRolesLib.ROLE_RENEW;
            if (!fusesFrozen) {
                tokenRoles |= RegistryRolesLib.ROLE_RENEW_ADMIN;
            }
        }

        // Conditionally add resolver roles
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            tokenRoles |= RegistryRolesLib.ROLE_SET_RESOLVER;
            if (!fusesFrozen) {
                tokenRoles |= RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
            }
        }

        // Add transfer admin role if transfers are allowed
        if ((fuses & CANNOT_TRANSFER) == 0) {
            tokenRoles |= RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        }

        // Owner gets registrar permissions on subregistry only if subdomain creation is allowed
        if ((fuses & CANNOT_CREATE_SUBDOMAIN) == 0) {
            registryRoles |= RegistryRolesLib.ROLE_REGISTRAR;
            if (!fusesFrozen) {
                registryRoles |= RegistryRolesLib.ROLE_REGISTRAR_ADMIN;
            }
        }

        // Add renewal roles to subregistry
        registryRoles |= RegistryRolesLib.ROLE_RENEW;
        registryRoles |= RegistryRolesLib.ROLE_RENEW_ADMIN;
    }
}
