// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IAddressSet} from "./interfaces/IAddressSet.sol";

uint256 constant ROLE_APPROVE = 1 << 0;
uint256 constant ROLE_APPROVE_ADMIN = ROLE_APPROVE << 128;

/// @notice An arbitrary set of addresses managed by EAC.
contract PermissionedAddressSet is EnhancedAccessControl, IAddressSet {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Mapping that determines members of the set.
    mapping(address addr => bool approved) internal _approved;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Inclusion of a member of the set has changed.
    /// @param addr The address.
    /// @param approved If `true`, added, otherwise removed.
    /// @param sender The sender of the change.
    event ApprovalChanged(address indexed addr, bool approved, address indexed sender);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initialize the contract.
    /// @param hcaFactory The HCA factory.
    /// @param admin The initial admin.
    constructor(IHCAFactoryBasic hcaFactory, address admin) HCAEquivalence(hcaFactory) {
        _grantRoles(ROOT_RESOURCE, ROLE_APPROVE | ROLE_APPROVE_ADMIN, admin, false);
    }

    /// @inheritdoc EnhancedAccessControl
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(EnhancedAccessControl) returns (bool) {
        return type(IAddressSet).interfaceId == interfaceId || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Add or remove a member from the set.
    /// @param addr The address to approve.
    /// @param approved If `true`, added, otherwise removed.
    function approve(address addr, bool approved) external onlyRootRoles(ROLE_APPROVE) {
        require(_approved[addr] != approved);
        _approved[addr] = approved;
        emit ApprovalChanged(addr, approved, _msgSender());
    }

    /// @inheritdoc IAddressSet
    function includes(address addr) external view returns (bool) {
        return _approved[addr];
    }
}
