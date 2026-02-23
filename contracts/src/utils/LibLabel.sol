// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

library LibLabel {
    /// @dev Convert a label to a labelhash.
    function labelhash(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    /// @dev Convert a label to canonical id.
    ///
    /// @param label The label to convert.
    ///
    /// @return The canonical id corresponding to this label.
    function labelToCanonicalId(string memory label) internal pure returns (uint256) {
        return getCanonicalId(uint256(labelhash(label)));
    }

    /// @dev Get the canonical id of a token id or canonical id.
    ///
    /// @param id The token id or canonical id to convert to its canonical id version.
    ///
    /// @return The canonical id.
    function getCanonicalId(uint256 id) internal pure returns (uint256) {
        return id ^ uint32(id);
    }
}
