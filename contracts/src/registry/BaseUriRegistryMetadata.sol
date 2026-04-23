// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";

/// @notice `IRegistryMetadata` implementation that returns a single shared base URI for all tokens.
///         The base URI can be updated by accounts holding the metadata update role in the root resource.
contract BaseUriRegistryMetadata is EnhancedAccessControl, IRegistryMetadata {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Role bit allowing an account to update the token base URI.
    uint256 private constant _ROLE_UPDATE_METADATA = 1 << 0;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Shared base URI returned for every token.
    string private _tokenBaseUri;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes BaseUriRegistryMetadata, granting all roles to the caller.
    /// @param hcaFactory The HCA factory.
    constructor(IHCAFactoryBasic hcaFactory) HCAEquivalence(hcaFactory) {
        _grantRoles(ROOT_RESOURCE, EACBaseRolesLib.ALL_ROLES, _msgSender(), true);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IRegistryMetadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Replaces the shared base URI for all tokens.
    /// @dev Restricted to accounts holding the metadata update role on the root resource.
    /// @param uri The new base URI to store.
    function setTokenBaseUri(
        string calldata uri
    ) external onlyRoles(ROOT_RESOURCE, _ROLE_UPDATE_METADATA) {
        _tokenBaseUri = uri;
    }

    /// @notice Returns the metadata URI for the given token.
    /// @dev Because this implementation uses a single shared URI, the token ID parameter is ignored.
    /// @param {tokenId} Ignored.
    /// @return The shared base URI.
    function tokenUri(uint256 /* tokenId */) external view returns (string memory) {
        return _tokenBaseUri;
    }
}
