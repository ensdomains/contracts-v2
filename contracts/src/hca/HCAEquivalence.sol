// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IHCAFactoryBasic} from "./interfaces/IHCAFactoryBasic.sol";

/// @dev Provides sender-identity resolution for Hidden Contract Accounts (HCAs). An HCA is a
/// contract-based account whose actions should be attributed to its registered owner rather
/// than to the contract address itself.
///
/// Queries the HCA factory to resolve `msg.sender` to the real owner. If the factory is not
/// configured (address zero), or the caller has explicitly selected an HCA implementation but
/// is not a registered HCA, `msg.sender` is returned unchanged.
///
/// A configured factory may revert when the caller has neither a registered HCA owner nor an
/// explicitly selected implementation. This keeps HCA-aware protocol calls from silently using
/// a DAO-selected implementation that the caller has not opted into.
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

    /// @param hcaFactory The HCA factory contract.
    constructor(IHCAFactoryBasic hcaFactory) {
        HCA_FACTORY = hcaFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the HCA owner if `msg.sender` is a registered HCA, otherwise returns `msg.sender`.
    ///      A configured factory may require the caller to have explicitly selected an implementation.
    function _msgSenderWithHcaEquivalence() internal view returns (address) {
        if (address(HCA_FACTORY) == address(0))
            return msg.sender;
        address accountOwner = HCA_FACTORY.getAccountOwner(msg.sender);
        if (accountOwner == address(0))
            return msg.sender;
        return accountOwner;
    }
}
