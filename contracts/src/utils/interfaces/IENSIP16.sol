// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IENSIP16 {
    // Emitted when a new subname is registered.
    // A subname without expiration should set type(uint256).max
    // Context can attach any arbitrary data, such as resource id to keep track of EAC
    event NameRegistered(
        uint256 indexed tokenId,
        string label,
        uint64 expiration,
        address registeredBy,
        uint256 context
    );

    // Emitted when a new token id is generated
    event TokenRegenerated(uint256 oldTokenId, uint256 newTokenId, uint256 context);

    // Standard ERC1155 transfer event for name ownership changes
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value // must always be 1
    );

    // Standard ERC1155 transfer event for multiple name ownership changes
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    // Emitted when a name is renewed

    event ExpiryUpdated(uint256 indexed tokenId, uint64 newExpiration);

    // Emitted when subregistry is updated
    event SubregistryUpdated(uint256 indexed id, address subregistry);

    // Emitted when resolver is updated
    event ResolverUpdated(uint256 indexed id, address resolver);
}
