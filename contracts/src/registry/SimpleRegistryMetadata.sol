// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";

/// @notice `IRegistryMetadata` implementation that stores a distinct URI per token ID. URIs can be
///         set by accounts holding the metadata update role in the root resource.
contract SimpleRegistryMetadata is EnhancedAccessControl, IRegistryMetadata {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Role bit allowing an account to update individual token URIs.
    uint256 private constant _ROLE_UPDATE_METADATA = 1 << 0;

    /// @dev Admin-tier counterpart of the metadata update role, shifted into the upper half of the bitmap.
    uint256 private constant _ROLE_UPDATE_METADATA_ADMIN = _ROLE_UPDATE_METADATA << 128;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Per-token mapping from token ID to its metadata URI.
    mapping(uint256 id => string uri) private _tokenUris;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(IHCAFactoryBasic hcaFactory) HCAEquivalence(hcaFactory) {
        _grantRoles(ROOT_RESOURCE, EACBaseRolesLib.ALL_ROLES, _msgSender(), true);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IRegistryMetadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Sets the metadata URI for a specific token.
    /// @dev Restricted to accounts holding the metadata update role on the root resource.
    /// @param tokenId The token identifier whose URI is being set.
    /// @param uri The new metadata URI for the token.
    function setTokenUri(
        uint256 tokenId,
        string calldata uri
    ) external onlyRoles(ROOT_RESOURCE, _ROLE_UPDATE_METADATA) {
        _tokenUris[tokenId] = uri;
    }

    /// @notice Returns the metadata URI for the given token.
    /// @param tokenId The token identifier to look up.
    /// @return The stored URI for `tokenId`, or an empty string if none has been set.
    function tokenUri(uint256 tokenId) external view override returns (string memory) {
        return _tokenUris[tokenId];
    }
}
