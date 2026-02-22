// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {
    INameWrapper,
    IS_DOT_ETH,
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

uint32 constant FUSES_TO_BURN = CANNOT_BURN_FUSES |
    CANNOT_TRANSFER |
    CANNOT_SET_RESOLVER |
    CANNOT_SET_TTL |
    CANNOT_CREATE_SUBDOMAIN;

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
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

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

    // TODO: gas analysis and optimization
    // NOTE: converting this to an internal call requires catching many reverts
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
            // 1 <= length(label) <= 255

            (, uint32 fuses, uint64 expiry) = NAME_WRAPPER.getData(uint256(node));
            // ignore owner, only we can call this function => we own it

            // cannot be set without PARENT_CANNOT_CONTROL
            if ((fuses & CANNOT_UNWRAP) == 0) {
                revert MigrationErrors.NameNotLocked(uint256(node));
            }

            // sync expiry
            if ((fuses & IS_DOT_ETH) != 0) {
                require((fuses & CAN_EXTEND_EXPIRY) == 0, "2LD is always renewable by anyone");
                //fuses &= ~CAN_EXTEND_EXPIRY; // 2LD is always renewable by anyone
                expiry = uint64(NAME_WRAPPER.registrar().nameExpires(uint256(labelHash))); // does not revert
            }
            // NameWrapper subtracts GRACE_PERIOD from expiry during _beforeTransfer()
            // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/NameWrapper.sol#L822
            // expired names cannot be transferred:
            assert(expiry >= block.timestamp);
            // PermissionedRegistry._register() => CannotSetPastExpiration
            // wont happen as this operation is synchronous

            address resolver;
            if ((fuses & CANNOT_SET_RESOLVER) != 0) {
                resolver = NAME_WRAPPER.ens().resolver(node); // copy V1 resolver
            } else {
                resolver = md.resolver; // accepts any value
                NAME_WRAPPER.setResolver(node, address(0)); // clear V1 resolver / TODO: use ENSV2Resolver?
            }

            (uint256 tokenRoles, uint256 registryRoles) = _generateRoleBitmapsFromFuses(fuses);
            // PermissionedRegistry._register() => _grantRoles() => _checkRoleBitmap()
            // wont happen as roles are correct by construction

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
            _inject(md.label, md.owner, subregistry, resolver, tokenRoles, expiry);
            // PermissionedRegistry._register() => NameAlreadyRegistered
            // ERC1155._safeTransferFrom() => ERC1155InvalidReceiver

            // Burn all migration fuses
            NAME_WRAPPER.setFuses(node, uint16(FUSES_TO_BURN));
        }
    }

    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) internal virtual returns (uint256 tokenId);

    function _parentNode() internal view virtual returns (bytes32);

    /// @notice Generates role bitmaps based on fuses.
    /// @param fuses The current fuses on the name
    /// @return tokenRoles The token roles in parent registry.
    /// @return registryRoles The root roles in token subregistry.
    function _generateRoleBitmapsFromFuses(
        uint32 fuses
    ) internal pure returns (uint256 tokenRoles, uint256 registryRoles) {
        // Check if fuses are permanently frozen
        bool fusesFrozen = (fuses & CANNOT_BURN_FUSES) != 0;

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
