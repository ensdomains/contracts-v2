// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {LibString} from "../utils/LibString.sol";

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";

/// @notice An immutable IRegistryURIRenderer that injects registry address
/// and token ID into a URI string using fragments.  Ownable for contract naming.
///
/// The registry address does not include "0x".
///
/// Format: "{PREFIX}{registryAsHexAddress}{AFTER_REGISTRY}{tokenIdAsDecimal}{AFTER_TOKEN}"
///
/// eg.       PREFIX = "https://metadata/0x"
///   AFTER_REGISTRY = "/"
///      AFTER_TOKEN = ".json"
///
/// renderURI(1, 2) => "https://metadata/0x0000000000000000000000000000000000000001/2.json"
///
contract StaticURIRenderer is Ownable, ERC165, IRegistryURIRenderer {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice URI fragment before registry address.
    string public PREFIX;

    /// @notice URI fragment between registry address and token.
    string public AFTER_REGISTRY;

    /// @notice URI fragment after token.
    string public AFTER_TOKEN;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param owner_ Contract owner.
    /// @param prefix URI fragment before registry address.
    /// @param afterRegistry URI fragment between registry address and token.
    /// @param afterToken URI fragment after token.
    constructor(
        address owner_,
        string memory prefix,
        string memory afterRegistry,
        string memory afterToken
    )
        Ownable(owner_)
    {
        PREFIX = prefix;
        AFTER_REGISTRY = afterRegistry;
        AFTER_TOKEN = afterToken;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IRegistryURIRenderer).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IRegistryURIRenderer
    function renderURI(IRegistry registry, uint256 tokenId) external view returns (string memory) {
        return
            string.concat(
                PREFIX,
                LibString.toAddressString(address(registry)),
                AFTER_REGISTRY,
                LibString.toString(tokenId),
                AFTER_TOKEN
            );
    }
}
