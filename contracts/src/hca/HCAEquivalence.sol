// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IHCAFactoryBasic} from "./interfaces/IHCAFactoryBasic.sol";

/// @dev Provides sender-identity resolution for Hidden Contract Accounts (HCAs). An HCA is a
/// contract-based account whose actions should be attributed to its registered owner rather
/// than to the contract address itself.
///
/// Queries the HCA factory to resolve `msg.sender` to the real owner. If the factory is not
/// configured (address zero), or the caller is not a registered HCA (returns address zero),
/// `msg.sender` is returned unchanged.
///
/// This enables transparent proxy wallet support: contracts using HCA-aware `_msgSender()`
/// automatically attribute actions to the account owner regardless of whether the caller is
/// an EOA or an HCA proxy.
///
abstract contract HCAEquivalence {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The HCA factory contract
    IHCAFactoryBasic public immutable HCA_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes HCAEquivalence.
    /// @param hcaFactory The HCA factory contract.
    constructor(IHCAFactoryBasic hcaFactory) {
        HCA_FACTORY = hcaFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the HCA owner if `msg.sender` is a registered HCA, otherwise returns `msg.sender`.
    function _msgSenderWithHcaEquivalence() internal view returns (address) {
        address msgSender = msg.sender;
        if (address(HCA_FACTORY) == address(0))
            return msgSender;
        address accountOwner = HCA_FACTORY.getAccountOwner(msgSender);
        if (accountOwner == address(0))
            return msgSender;
        return accountOwner;
    }
}
