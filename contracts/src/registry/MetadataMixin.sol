// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";

/// @title MetadataMixin
/// @notice Mixin contract for Registry implementations to delegate metadata to an external provider
/// @dev Inherit this contract to add metadata functionality to Registry contracts
abstract contract MetadataMixin {
    /// @notice The metadata provider contract
    IRegistryMetadata public immutable METADATA_PROVIDER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the mixin with a metadata provider
    /// @param metadataProvider Address of the metadata provider contract
    constructor(IRegistryMetadata metadataProvider) {
        METADATA_PROVIDER = metadataProvider;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the token URI for a given token ID
    /// @param tokenId The ID of the token to query
    /// @return URI string for the token metadata
    function _tokenURI(uint256 tokenId) internal view virtual returns (string memory) {
        if (address(METADATA_PROVIDER) == address(0)) {
            return "";
        }
        return METADATA_PROVIDER.tokenUri(tokenId);
    }
}
