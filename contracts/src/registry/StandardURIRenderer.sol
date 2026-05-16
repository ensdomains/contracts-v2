// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {IStandardRegistry} from "./interfaces/IStandardRegistry.sol";
import {RegistryURIRendererLib} from "./libraries/RegistryURIRendererLib.sol";

/// @notice An onchain metadata URI rendereder.
contract StandardURIRenderer is IRegistryURIRenderer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IRegistry public immutable ROOT_REGISTRY;

    /// @notice The shared label database.
    ILabelStore public immutable LABEL_STORE;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The ENSv2 root registry.
    /// @param labelStore The shared label database.
    constructor(IRegistry rootRegistry, ILabelStore labelStore) {
        ROOT_REGISTRY = rootRegistry;
        LABEL_STORE = labelStore;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IRegistryURIRenderer
    function renderURI(IStandardRegistry registry, uint256 tokenId)
        external
        view
        returns (string memory)
    {
        string memory label = LABEL_STORE.getLabel(tokenId);

        RegistryURIRendererLib.Data memory data;
        data.tokenId = tokenId;
        data.label = label;

        data.owner = registry.findOwner(label);
        data.expiry = registry.findExpiry(label);

        bytes memory canonicalName = LibRegistry.findCanonicalName(ROOT_REGISTRY, registry);
        if (canonicalName.length > 0) {
            data.canonicalName = NameCoder.decode(canonicalName);
        }

        return RegistryURIRendererLib.metadataURI(data);
    }
}
