// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0xe9fe30a0`
interface IL2ReverseRegistrar {
    struct NameClaim {
        string name;
        address addr;
        uint256[] chainIds;
        uint256 signedAt;
    }

    /// @notice Sets the `nameForAddr()` record for the calling account.
    ///
    /// @param name The name to set.
    function setName(string memory name) external;

    /// @notice Sets the `nameForAddr()` record for the addr provided account.
    ///
    /// @param addr The address to set the name for.
    /// @param name The name to set.
    function setNameForAddr(address addr, string memory name) external;

    /// @notice Sets the `nameForAddr()` record for the addr provided account using a signature.
    ///
    /// @param claim The claim to set the name for.
    /// @param signature The signature from the addr.
    function setNameForAddrWithSignature(
        NameClaim calldata claim,
        bytes calldata signature
    ) external;

    /// @notice Sets the `nameForAddr()` record for the contract provided that is owned with `Ownable`.
    ///
    /// @param claim The claim to set the name for.
    /// @param owner The owner of the contract (via Ownable).
    /// @param signature The signature of an address that will return true on isValidSignature for the owner.
    function setNameForOwnableWithSignature(
        NameClaim calldata claim,
        address owner,
        bytes calldata signature
    ) external;

    /// @notice Set the `nameForAddr()` record for the contract provided using `IContractName`.
    ///         Callable by anyone.
    ///         Reverts if not implemented.
    ///         Does not require `ERC165` support.
    ///
    /// @param addr The address to set the name for.
    function syncName(address addr) external;

    /// @notice Returns the inception timestamp for a given address.
    /// @dev Only signatures with a signedAt timestamp greater than the inception can be used.
    ///
    /// @param addr The address to query.
    /// @return The inception timestamp for the address.
    function inceptionOf(address addr) external view returns (uint256);
}
