// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Allowlist for approved implementation upgrade targets.
contract ApprovedUpgradeGate is Ownable {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Returns whether an implementation may be used as an upgrade target.
    mapping(address implementation => bool approved) public approvedImplementations;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Approval status changed for an implementation.
    /// @param implementation The implementation address.
    /// @param approved Whether upgrades to the implementation are approved.
    event ImplementationApprovalChanged(address indexed implementation, bool indexed approved);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates the upgrade gate.
    /// @param owner_ The address that controls implementation approvals.
    constructor(address owner_) Ownable(owner_) {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set whether an implementation may be used as an upgrade target.
    /// @param implementation The implementation address.
    /// @param approved Whether upgrades to the implementation are approved.
    function setImplementationApproval(address implementation, bool approved) external onlyOwner {
        approvedImplementations[implementation] = approved;
        emit ImplementationApprovalChanged(implementation, approved);
    }
}
