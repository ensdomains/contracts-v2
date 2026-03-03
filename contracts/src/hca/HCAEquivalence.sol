// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IHCAFactoryBasic} from "./interfaces/IHCAFactoryBasic.sol";

/// @dev Replaces msg.sender
abstract contract HCAEquivalence {
    /// @notice The HCA factory contract
    IHCAFactoryBasic public immutable HCA_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(IHCAFactoryBasic hcaFactory) {
        HCA_FACTORY = hcaFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Returns either the account owner of an HCA or the original sender
    function _msgSenderWithHcaEquivalence() internal view returns (address) {
        if (address(HCA_FACTORY) == address(0)) return msg.sender;
        address accountOwner = HCA_FACTORY.getAccountOwner(msg.sender);
        if (accountOwner == address(0)) return msg.sender;
        return accountOwner;
    }
}
