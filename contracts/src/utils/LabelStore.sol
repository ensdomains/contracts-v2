// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {ILabelStore} from "./interfaces/ILabelStore.sol";

import {LibLabel} from "./LibLabel.sol";

/// @notice Shared label database.
contract LabelStore is ILabelStore {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev The truncated labelhash to label mapping.
    mapping(uint256 storageId => string label) internal _labels;

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ILabelStore
    function setLabel(string calldata label) external {
        NameCoder.assertLabelSize(label);
        uint256 labelId = LibLabel.id(label);
        uint256 storageId = _storageId(labelId);
        if (bytes(_labels[storageId]).length == 0) {
            _labels[storageId] = label;
            emit Label(bytes32(labelId), label);
        }
    }

    /// @inheritdoc ILabelStore
    function getLabel(uint256 anyId) public view returns (string memory) {
        return _labels[_storageId(anyId)];
    }

    /// @dev Convert `anyId` to `storageId`.
    function _storageId(uint256 anyId) internal pure returns (uint256) {
        return LibLabel.withVersion(anyId, 0);
    }
}
