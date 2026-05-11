// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {RegistryURIRendererLib} from "./libraries/RegistryURIRendererLib.sol";

contract BasicURIRenderer is IRegistryURIRenderer {
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

    constructor(IRegistry rootRegistry, ILabelStore labelStore) {
        ROOT_REGISTRY = rootRegistry;
        LABEL_STORE = labelStore;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IRegistryURIRenderer
    function renderURI(IRegistry registry, uint256 tokenId) external view returns (string memory) {
        string memory label = LABEL_STORE.getLabel(tokenId);
        bytes memory canonicalName = LibRegistry.findCanonicalName(ROOT_REGISTRY, registry);
        RegistryURIRendererLib.Data memory data;
        data.label = label;
        if (canonicalName.length > 0) {
            data.canonicalName = NameCoder.decode(canonicalName);
        }
        return RegistryURIRendererLib.metadataURI(data);
    }
}
