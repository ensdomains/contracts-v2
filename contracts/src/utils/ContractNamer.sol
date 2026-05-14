// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";

/// @notice Shared `IContractNamer` instance.
contract ContractNamer is ERC165, Ownable, IContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param owner_ The contract owner.
    constructor(address owner_) Ownable(owner_) {}

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
        return owner() == namer;
    }
}
