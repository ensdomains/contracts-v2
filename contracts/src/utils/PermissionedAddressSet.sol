// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";

import {IAddressSet} from "./interfaces/IAddressSet.sol";

/// @dev Nybble 0: authorizes modifying the set. Root only.
uint256 constant ROLE_APPROVE = 1 << 0;

/// @dev Nybble 32: authorizes setting `ROLE_APPROVE`.
uint256 constant ROLE_APPROVE_ADMIN = ROLE_APPROVE << 128;

/// @dev Nybble 1: authorizes contract naming. Root only.
uint256 constant ROLE_SET_NAME = 1 << 4;

/// @dev Nybble 33: authorizes setting `ROLE_SET_NAME`.
uint256 constant ROLE_SET_NAME_ADMIN = ROLE_SET_NAME << 128;

/// @dev Default root roles assigned at construction.
uint256 constant DEFAULT_ROLE_BITMAP =
    ROLE_APPROVE | ROLE_APPROVE_ADMIN | ROLE_SET_NAME | ROLE_SET_NAME_ADMIN;

/// @notice An arbitrary set of addresses managed by EAC.
contract PermissionedAddressSet is EnhancedAccessControl, IAddressSet, IContractNamer {
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

    /// @param hcaFactory The HCA factory.
    /// @param admin The initial admin.
    constructor(IHCAFactoryBasic hcaFactory, address admin) HCAEquivalence(hcaFactory) {
        _grantRoles(ROOT_RESOURCE, DEFAULT_ROLE_BITMAP, admin, false);
    }

    /// @inheritdoc EnhancedAccessControl
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IAddressSet).interfaceId ||
            interfaceId == type(IContractNamer).interfaceId ||
            super.supportsInterface(interfaceId);
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

    /// @inheritdoc IContractNamer
    function isContractNamer(address namer) external view returns (bool) {
        return hasRootRoles(ROLE_SET_NAME, namer);
    }
}
