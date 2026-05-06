// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

import {IETHRenewer} from "./IETHRenewer.sol";

/// @notice Interface for registering ".eth" names.
/// @dev Interface selector: `0xc1401b80`
interface IETHRegistrar is IETHRenewer {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `commitment` was recorded onchain at `block.timestamp`.
    /// @param commitment The commitment hash from `makeCommitment()`.
    event CommitmentMade(bytes32 commitment);

    /// @notice A name was registered.
    /// @param tokenId The registry token id.
    /// @param label The name of the registration.
    /// @param owner The owner address.
    /// @param subregistry The initial registry address.
    /// @param resolver The initial resolver address.
    /// @param duration The registration duration, in seconds.
    /// @param paymentToken The payment token.
    /// @param referrer The referrer hash.
    /// @param base The amount of `paymentToken` for the registration.
    /// @param premium The amount of `paymentToken` due to premium.
    event NameRegistered(
        uint256 indexed tokenId,
        string label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 indexed referrer,
        uint256 base,
        uint256 premium
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `commitment` is still usable for registration.
    /// @dev Error selector: `0x0a059d71`
    error UnexpiredCommitmentExists(bytes32 commitment);

    /// @notice `commitment` cannot be consumed yet.
    /// @dev Error selector: `0x6be614e3`
    error CommitmentTooNew(bytes32 commitment, uint64 validFrom, uint64 blockTimestamp);

    /// @notice `commitment` has expired.
    /// @dev Error selector: `0x0cb9df3f`
    error CommitmentTooOld(bytes32 commitment, uint64 validTo, uint64 blockTimestamp);

    /// @notice `label` cannot be registered.
    /// @dev Error selector: `0x477707e8`
    error NameNotAvailable(string label);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Registration step #1: record intent to register without revealing any information.
    /// @dev Emits `CommitmentMade` or reverts with `UnexpiredCommitmentExists`.
    /// @param commitment The commitment hash.
    function commit(bytes32 commitment) external;

    /// @notice Register a name.
    /// @param label The name from commitment.
    /// @param owner The owner from commitment.
    /// @param secret The secret from commitment.
    /// @param subregistry The registry from commitment.
    /// @param resolver The resolver from commitment.
    /// @param duration The registration from commitment.
    /// @param paymentToken The payment token.
    /// @param referrer The referrer hash.
    /// @return The registered token ID.
    function register(
        string memory label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external returns (uint256);

    /// @notice Get timestamp of a prior commitment.
    /// @param commitment The commitment hash.
    /// @return The commitment time, in seconds, or 0 if unknown.
    function commitmentAt(bytes32 commitment) external view returns (uint64);

    /// @notice Determine register price for a name.
    /// @param label The name to register.
    /// @param duration The registration duration, in seconds.
    /// @param paymentToken The payment token.
    /// @return base The amount of `paymentToken` for registration.
    /// @return premium The amount of `paymentToken` due to premium.
    function getRegisterPrice(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 base, uint256 premium);

    /// @notice Check if name is available.
    /// @param label The name to check.
    /// @return `true` if registerable.
    function isAvailable(string memory label) external view returns (bool);

    /// @notice Compute hash of registration parameters.
    /// @param label The name to register.
    /// @param owner The owner address.
    /// @param secret The secret for the registration.
    /// @param subregistry The initial registry address.
    /// @param resolver The initial resolver address.
    /// @param duration The registration duration, in seconds.
    /// @param referrer The referrer hash.
    /// @return The commitment hash.
    function makeCommitment(
        string calldata label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) external pure returns (bytes32);
}
