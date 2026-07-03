// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";

/// @dev Mixin for delegated contract naming. 
abstract contract DelegatedContractNamer is ERC165, IContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Delegated contract namer.
    IContractNamer public immutable CONTRACT_NAMER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param contractNamer Delegated contract namer.
    constructor(IContractNamer contractNamer) {
        CONTRACT_NAMER = contractNamer;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IContractNamer).interfaceId || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IContractNamer
    function isContractNamer(address namer) external view returns (bool) {
        return CONTRACT_NAMER.isContractNamer(namer);
    }
}
