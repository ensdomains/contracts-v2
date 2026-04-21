// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

import {IPaymentTokenOracle} from "./IPaymentTokenOracle.sol";

/// @notice Interface for the ".eth" registrar which manages the ".eth" registry.
/// @dev Interface selector: `0xd790e8f5`
interface IETHRegistrar is IPaymentTokenOracle {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `commitment` was recorded onchain at `block.timestamp`.
    /// @param commitment The commitment hash from `makeCommitment()`.
    event CommitmentMade(bytes32 commitment);

    /// @notice `{label}.eth` was registered for `duration`.
    /// @param tokenId The registry token id.
    /// @param label The name of the registration.
    /// @param owner The owner address.
    /// @param subregistry The initial registry address.
    /// @param resolver The initial resolver address.
    /// @param duration The registration duration, in seconds.
    /// @param paymentToken The ERC-20 used for payment.
    /// @param referrer The referrer hash.
    /// @param base The base price, relative to `paymentToken`.
    /// @param premium The premium price, relative to `paymentToken`.
    event NameRegistered(
        uint256 indexed tokenId,
        string label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer,
        uint256 base,
        uint256 premium
    );

    /// @notice `{label}.eth` was extended by `duration`.
    /// @param tokenId The registry token id.
    /// @param label The name of the renewal.
    /// @param duration The duration extension, in seconds.
    /// @param newExpiry The new expiry, in seconds.
    /// @param paymentToken The ERC-20 used for payment.
    /// @param referrer The referrer hash.
    /// @param base The base price, relative to `paymentToken`.
    event NameRenewed(
        uint256 indexed tokenId,
        string label,
        uint64 duration,
        uint64 newExpiry,
        IERC20 paymentToken,
        bytes32 referrer,
        uint256 base
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `paymentToken` is not supported for payment.
    /// @dev Error selector: `0x02e2ae9e`
    error PaymentTokenNotSupported(IERC20 paymentToken);

    /// @notice `label` is not available
    /// @dev Error selector: `0xeb160ce0`
    error CannotRegister();

    /// @notice `label` is not available for.
    /// @dev Error selector: `0xd1fe65f8`
    error CannotRenew();

    /// @notice `duration` less than `minDuration`.
    /// @dev Error selector: `0xa096b844`
    error DurationTooShort(uint64 duration, uint64 minDuration);

    /// @notice `maxCommitmentAge` was not greater than `minCommitmentAge`.
    /// @dev Error selector: `0x3e5aa838`
    error MaxCommitmentAgeTooLow();

    /// @notice `commitment` is still usable for registration.
    /// @dev Error selector: `0x0a059d71`
    error UnexpiredCommitmentExists(bytes32 commitment);

    /// @notice `commitment` cannot be consumed yet.
    /// @dev Error selector: `0x6be614e3`
    error CommitmentTooNew(bytes32 commitment, uint64 validFrom, uint64 blockTimestamp);

    /// @notice `commitment` has expired.
    /// @dev Error selector: `0x0cb9df3f`
    error CommitmentTooOld(bytes32 commitment, uint64 validTo, uint64 blockTimestamp);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Registration step #1: record intent to register without revealing any information.
    /// @dev Emits `CommitmentMade` or reverts with `UnexpiredCommitmentExists`.
    /// @param commitment The commitment hash.
    function commit(bytes32 commitment) external;

    /// @notice Registration step #2: reveal committed registration parameters, then register `{label}.eth`.
    /// @dev Emits `NameRegistered` or reverts with a variety of errors.
    /// @param label The name from commitment.
    /// @param owner The owner from commitment.
    /// @param secret The secret from commitment.
    /// @param subregistry The registry from commitment.
    /// @param resolver The resolver from commitment.
    /// @param duration The registration from commitment.
    /// @param paymentToken The ERC-20 to use for payment.
    /// @param referrer The referrer hash.
    /// @return tokenId The registered token ID.
    function register(
        string memory label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external returns (uint256 tokenId);

    /// @notice Renew an existing registration.
    /// @dev Emits `NameRenewed` or reverts with a variety of errors.
    /// @param label The name to renew.
    /// @param duration The registration extension, in seconds.
    /// @param paymentToken The ERC-20 to use for payment.
    /// @param referrer The referrer hash.
    function renew(
        string memory label,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external;

    /// @notice Check if a `label` is valid for registration.
    /// @param label The name to check.
    /// @return `true` if the `label` is valid.
    function isValid(string memory label) external view returns (bool);

    /// @notice Check if `label` is available for registration.
    /// @param label The name to check.
    /// @return available `true` if `label` is available.
    function isAvailable(string memory label) external view returns (bool);

    /// @notice Price of registering or renewing `label`.
    /// @param label The name to price.
    /// @param duration The duration to register or renew, in seconds.
    /// @param paymentToken The ERC-20 to use for payment.
    /// @return tokenId The token ID or 0 if available.
    /// @return expiry The new expiry, in seconds.
    /// @return base The base price, relative to `paymentToken`.
    /// @return premium The premium price, relative to `paymentToken`.
    function rentPrice(
        string memory label,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 tokenId, uint64 expiry, uint256 base, uint256 premium);

    /// @notice Get timestamp of `commitment`.
    /// @param commitment The commitment hash.
    /// @return The commitment time, in seconds.
    function commitmentAt(bytes32 commitment) external view returns (uint64);

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
        string memory label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) external pure returns (bytes32);
}
