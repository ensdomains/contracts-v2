// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IRegistryURIRenderer} from "~src/registry/interfaces/IRegistryURIRenderer.sol";

contract MockURIRenderer is IRegistryURIRenderer {
    string internal _uri;
    constructor(string memory uri) {
        _uri = uri;
    }
    function renderURI(IRegistry, uint256) external view returns (string memory) {
        return _uri;
    }
}
