// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IAddressSet} from "./interfaces/IAddressSet.sol";

uint256 constant ROLE_APPROVE = 0;
uint256 constant ROLE_APPROVE_ADMIN = ROLE_APPROVE << 128;

/// @notice An arbitrary set of addresses managed by EAC.
contract PermissionedAddresses is EnhancedAccessControl, IAddressSet {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev TODO
    mapping(address addr => bool approved) internal _approved;

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

    /// @notice Add or remove `addr` from the set.
    /// @param addr The address to approve.
    /// @param approved If `true`, added, otherwise removed.
    function approve(address addr, bool approved) external onlyRootRoles(ROLE_APPROVE) {
        _approved[addr] = approved;
    }

    /// @inheritdoc IAddressSet
    function includes(address addr) external view returns (bool) {
        return _approved[addr];
    }
}
