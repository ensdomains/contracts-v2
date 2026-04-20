// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// ──────────────────────────────────────────────────────────────────────────────
//     _   __    _  __
//    / | / /__ | |/ /_  _______
//   /  |/ / _ \|   / / / / ___/
//  / /|  /  __/   / /_/ (__  )
// /_/ |_/\___/_/|_\__,_/____/
//
// ──────────────────────────────────────────────────────────────────────────────
// Nexus: A suite of contracts for Modular Smart Accounts compliant with ERC-7579 and ERC-4337, developed by Biconomy.
// Learn more at https://biconomy.io. To report security issues, please contact us at: security@biconomy.io

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {ERC7739Validator} from "erc7739Validator/ERC7739Validator.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";
import {EnumerableSet} from "nexus/lib/EnumerableSet4337.sol";
import {
    MODULE_TYPE_VALIDATOR,
    VALIDATION_SUCCESS,
    VALIDATION_FAILED
} from "nexus/types/Constants.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

import {IK1Validator} from "./IK1Validator.sol";

/// @title Nexus - K1Validator (ECDSA)
/// @notice Validator module for smart accounts, verifying user operation signatures
///         based on the K1 curve (secp256k1), a widely used ECDSA algorithm.
/// @dev Implements secure ownership validation by checking signatures against registered
///      owners. This module supports ERC-7579 and ERC-4337 standards, ensuring only the
///      legitimate owner of a smart account can authorize transactions.
///      Implements ERC-7739
/// @author @livingrockrises | Biconomy | chirag@biconomy.io
/// @author @aboudjem | Biconomy | adam.boudjemaa@biconomy.io
/// @author @filmakarov | Biconomy | filipp.makarov@biconomy.io
/// @author @zeroknots | Rhinestone.wtf | zeroknots.eth
///         Special thanks to the Solady team for foundational contributions: https://github.com/Vectorized/solady
contract StaticK1Validator is IValidator, IK1Validator, ERC7739Validator {
    using ECDSA for bytes32;

    using EnumerableSet for EnumerableSet.AddressSet;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Mapping of smart account addresses to their respective owner addresses.
    mapping(address smartAccount => address owner) internal _smartAccountOwners;

    /// @dev Account-specific safe senders that bypass nested EIP-712 validation.
    EnumerableSet.AddressSet private _safeSenders;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when the owner of a smart account is set.
    /// @param smartAccount The smart account whose owner changed.
    /// @param owner The new owner for the smart account.
    event OwnerSet(address indexed smartAccount, address indexed owner);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Error to indicate that no owner was provided during installation
    /// @dev Error selector: `0x1f2a381c`
    error NoOwnerProvided();

    /// @notice Error to indicate that the new owner cannot be the zero address
    /// @dev Error selector: `0x8579befe`
    error ZeroAddressNotAllowed();

    /// @notice Error to indicate the module is already initialized
    /// @dev Error selector: `0xe72ce85e`
    error ModuleAlreadyInitialized();

    /// @notice Error to indicate that the owner cannot be the zero address
    /// @dev Error selector: `0xc81abf60`
    error OwnerCannotBeZeroAddress();

    /// @notice Error to indicate that the data length is invalid
    /// @dev Error selector: `0xdfe93090`
    error InvalidDataLength();

    /// @notice Error to indicate that the safe senders data length is invalid
    /// @dev Error selector: `0x7c148cd9`
    error InvalidSafeSendersLength();

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the module with owner and optional safe sender data.
    /// @param data The data to initialize the module with
    function onInstall(bytes calldata data) external override {
        require(data.length != 0, NoOwnerProvided());
        require(!_isInitialized(msg.sender), ModuleAlreadyInitialized());
        address newOwner = address(bytes20(data[:20]));
        require(newOwner != address(0), OwnerCannotBeZeroAddress());
        _smartAccountOwners[msg.sender] = newOwner;
        emit OwnerSet(msg.sender, newOwner);
        if (data.length > 20) {
            _fillSafeSenders(data[20:]);
        }
    }

    /// @notice Removes the module state for the calling smart account.
    /// @param data Ignored module uninstallation data.
    function onUninstall(bytes calldata data) external override {
        data;
        delete _smartAccountOwners[msg.sender];
        _safeSenders.removeAll(msg.sender);
        emit OwnerSet(msg.sender, address(0));
    }

    /// @notice Adds a safe sender for the calling smart account.
    /// @param sender The sender to mark as safe.
    function addSafeSender(address sender) external {
        _safeSenders.add(msg.sender, sender);
    }

    /// @notice Removes a safe sender for the calling smart account.
    /// @param sender The sender to remove.
    function removeSafeSender(address sender) external {
        _safeSenders.remove(msg.sender, sender);
    }

    /// @notice Checks whether a sender is safe for a smart account.
    /// @param sender The sender to check.
    /// @param smartAccount The smart account whose safe sender set is checked.
    /// @return True if the sender is marked safe for the smart account.
    function isSafeSender(address sender, address smartAccount) external view returns (bool) {
        return _safeSenders.contains(smartAccount, sender);
    }

    /// @notice Checks whether the module is initialized for a smart account.
    /// @param smartAccount The smart account to check
    /// @return true if the module is initialized, false otherwise
    function isInitialized(address smartAccount) external view returns (bool) {
        return _isInitialized(smartAccount);
    }

    /// @notice Validates a packed user operation signature.
    /// @param userOp UserOperation to be validated
    /// @param userOpHash Hash of the UserOperation to be validated
    /// @return uint256 the result of the signature validation, which can be:
    ///  - 0 if the signature is valid
    ///  - 1 if the signature is invalid
    ///  - <20-byte> aggregatorOrSigFail, <6-byte> validUntil and <6-byte> validAfter (see ERC-4337
    /// for more details)
    ///
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        override
        returns (uint256)
    {
        return
            _validateSignatureForOwner(getOwner(userOp.sender), userOpHash, userOp.signature)
                ? VALIDATION_SUCCESS
                : VALIDATION_FAILED;
    }

    /// @notice Validates an ERC-1271 signature for a sender.
    /// @dev implements signature malleability prevention
    ///      see: https://eips.ethereum.org/EIPS/eip-1271#reference-implementation
    ///      Please note, that this prevention does not protect against replay attacks in general
    ///      So the protocol using ERC-1271 should make sure hash is replay-safe.
    /// @param sender The sender of the ERC-1271 call to the account
    /// @param hash The hash of the message
    /// @param signature The signature of the message
    /// @return sigValidationResult the result of the signature validation, which can be:
    ///  - EIP1271_SUCCESS if the signature is valid
    ///  - EIP1271_FAILED if the signature is invalid
    ///  - 0x7739000X if this is the ERC-7739 support detection request.
    ///  Where X is the version of the ERC-7739 support.
    ///
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata signature)
        external
        view
        virtual
        override
        returns (bytes4)
    {
        return _erc1271IsValidSignatureWithSender(sender, hash, _erc1271UnwrapSignature(signature));
    }

    /// @notice ISessionValidator interface for smart session
    /// @param hash The hash of the data to validate
    /// @param sig The signature data
    /// @param data The data to validate against (owner address in this case)
    /// @return validSig True if the signature is valid for the owner encoded in `data`.
    function validateSignatureWithData(bytes32 hash, bytes calldata sig, bytes calldata data)
        external
        view
        returns (bool validSig)
    {
        require(data.length == 20, InvalidDataLength());
        address owner = address(bytes20(data[0:20]));
        return _validateSignatureForOwner(owner, hash, sig);
    }

    /// @notice Returns the name of the module
    function name() external pure returns (string memory) {
        return "StaticK1Validator";
    }

    /// @notice Returns the version of the module
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /// @notice Checks if the module is of the specified type
    /// @param typeId The type ID to check
    /// @return True if the module is of the specified type, false otherwise
    function isModuleType(uint256 typeId) external pure returns (bool) {
        return typeId == MODULE_TYPE_VALIDATOR;
    }

    /// @notice Returns the owner of the smart account.
    /// @param smartAccount The address of the smart account
    /// @return The owner of the smart account
    function getOwner(address smartAccount) public view returns (address) {
        address owner = _smartAccountOwners[smartAccount];
        return owner == address(0) ? smartAccount : owner;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Recovers the signer from a signature.
    /// @param hash The hash of the data to validate
    /// @param signature The signature data
    /// @return The recovered signer address
    function _recoverSigner(bytes32 hash, bytes calldata signature) internal view returns (address) {
        return hash.tryRecoverCalldata(signature);
    }

    /// @dev Returns whether the `hash` and `signature` are valid.
    ///      Obtains the authorized signer's credentials and calls some
    ///      module's specific internal function to validate the signature
    ///      against credentials.
    function _erc1271IsValidSignatureNowCalldata(bytes32 hash, bytes calldata signature)
        internal
        view
        override
        returns (bool)
    {
        // call custom internal function to validate the signature against credentials
        return _validateSignatureForOwner(getOwner(msg.sender), hash, signature);
    }

    /// @dev Returns whether the `sender` is considered safe, so nested EIP-712 validation can be
    ///      skipped for trusted callers. The canonical `MulticallerWithSigner` at
    ///      `0x000000000000D9ECebf3C23529de49815Dac1c4c` is known to include the account in the
    ///      hash to be signed.
    function _erc1271CallerIsSafe(address sender) internal view virtual override returns (bool) {
        return
            (sender == 0x000000000000D9ECebf3C23529de49815Dac1c4c ||
                sender == msg.sender ||
                _safeSenders.contains(msg.sender, sender)); // check if sender is in _safeSenders for the Smart Account
    }

    /// @dev Validates a signature against an owner using ECDSA.
    /// @param owner The address of the owner
    /// @param hash The hash of the data to validate
    /// @param signature The signature data
    function _validateSignatureForOwner(address owner, bytes32 hash, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        // verify signer
        // owner can not be zero address in this contract
        if (_recoverSigner(hash, signature) == owner)
            return true;
        if (_recoverSigner(hash.toEthSignedMessageHash(), signature) == owner) {
            return true;
        }
        return false;
    }

    ////////////////////////////////////////////////////////////////////////
    // Private Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Fills the safe sender set from packed address data.
    /// @param data Packed safe sender addresses.
    function _fillSafeSenders(bytes calldata data) private {
        require(data.length % 20 == 0, InvalidSafeSendersLength());
        for (uint256 i; i < data.length / 20; i++) {
            _safeSenders.add(msg.sender, address(bytes20(data[20 * i:20 * (i + 1)])));
        }
    }

    /// @dev Checks if the smart account is initialized with an owner.
    /// @param smartAccount The address of the smart account
    /// @return True if the smart account has an owner, false otherwise
    function _isInitialized(address smartAccount) private view returns (bool) {
        return _smartAccountOwners[smartAccount] != address(0);
    }
}
