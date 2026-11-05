// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Define the storage layout for `UpgradeablePermissionedRegistry`.
library RegistryStorageLayout {
    // see: ERC1155Singleton.sol
    uint256 constant SLOT_ERC1155_OWNERS = 0;
    uint256 constant SLOT_ERC1155_OPERATOR_APPROVALS = SLOT_ERC1155_OWNERS + 1;
    uint256 constant SLOT_ERC1155_END = SLOT_ERC1155_OPERATOR_APPROVALS + 1;

    // see: EnhancedAccessControl.sol
    uint256 constant SLOT_EAC_ROLES = SLOT_ERC1155_END;
    uint256 constant SLOT_EAC_ROLE_COUNTS = SLOT_EAC_ROLES + 1;
    uint256 constant GAP_EAC = 256;
    uint256 constant SLOT_EAC_END = SLOT_EAC_ROLE_COUNTS + GAP_EAC + 1;

    // see: PermissionedRegistry.sol
    uint256 constant SLOT_PERMREG_PARENT_REGISTRY = SLOT_EAC_END;
    uint256 constant SLOT_PERMREG_CHILD_LABEL = SLOT_PERMREG_PARENT_REGISTRY + 1;
    uint256 constant SLOT_PERMREG_URI = SLOT_PERMREG_CHILD_LABEL + 1;
    uint256 constant SLOT_PERMREG_URI_RENDERER = SLOT_PERMREG_URI + 1;
    uint256 constant SLOT_PERMREG_ENTRIES = SLOT_PERMREG_URI_RENDERER + 1;
    uint256 constant GAP_PERMREG = 256;
    uint256 constant SLOT_PERMREG_END = SLOT_PERMREG_ENTRIES + GAP_PERMREG + 1;

    // see: WrapperRegistry.sol
    uint256 constant SLOT_WRAPREG_NODE = SLOT_PERMREG_END;
    uint256 constant SLOT_WRAPREG_INITIAL_ROLES = SLOT_WRAPREG_NODE + 1;
    uint256 constant SLOT_WRAPREG_END = SLOT_WRAPREG_INITIAL_ROLES + 1;
}
