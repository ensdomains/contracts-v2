// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IExecutor} from "nexus/interfaces/modules/IExecutor.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";
import {EncodedModuleTypes} from "nexus/lib/ModuleTypeLib.sol";

import {
    HCAOwnerAndSessionValidator,
    IHCARegistrationResolver
} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

/// @title Mock Standalone HCA
/// @notice Test-only HCA stand-in that exposes an owner and forwards validation.
contract MockStandaloneHCA {
    /// @notice The owner reported to the validator.
    address public owner;

    /// @notice The session nonce reported to the validator.
    uint96 public sessionNonce;

    /// @param owner_ The owner reported to the validator.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Sets the reported session nonce.
    /// @param sessionNonce_ The nonce to report.
    function setSessionNonce(uint96 sessionNonce_) external {
        sessionNonce = sessionNonce_;
    }

    /// @notice Returns the owner and session nonce as one call.
    /// @return owner_ The reported owner.
    /// @return sessionNonce_ The reported session nonce.
    function ownerAndSessionNonce() external view returns (address owner_, uint96 sessionNonce_) {
        return (owner, sessionNonce);
    }

    /// @notice Forwards an ERC-1271 validation to the validator as this account.
    /// @param validator The validator under test.
    /// @param operationHash The digest supplied by the intent executor.
    /// @param signature The owner signature.
    /// @return The ERC-1271 return value.
    function validate(
        HCAOwnerAndSessionValidator validator,
        bytes32 operationHash,
        bytes calldata signature
    )
        external
        view
        returns (bytes4)
    {
        return
            validator.isValidSignatureWithSender(
                validator.INTENT_EXECUTOR(),
                operationHash,
                signature
            );
    }
}


/// @title Mock Address Set
/// @notice Test-only administrator-controlled address set for HCA upgrade authorization.
contract MockAddressSet is IAddressSet {
    /// @notice The only account allowed to update the set.
    address public immutable ADMIN;

    mapping(address member => bool approved) private _approved;

    /// @notice Thrown when an account other than the administrator updates the set.
    /// @param caller The unauthorized caller.
    error UnauthorizedAddressSetAdmin(address caller);

    /// @param admin The account allowed to update the set.
    constructor(address admin) {
        ADMIN = admin;
    }

    /// @notice Adds or removes an address from the set.
    /// @param member The address whose membership changes.
    /// @param approved Whether the address is included.
    function approve(address member, bool approved) external {
        if (msg.sender != ADMIN) {
            revert UnauthorizedAddressSetAdmin(msg.sender);
        }
        _approved[member] = approved;
    }

    /// @inheritdoc IAddressSet
    function includes(address member) external view returns (bool) {
        return _approved[member];
    }
}


/// @title Mock HCA Registration Resolver
/// @notice Test-only upgradeable resolver target implementing the HCA policy call surface.
contract MockHCARegistrationResolver is
    IHCARegistrationResolver,
    IProxyAuthorization,
    UUPSUpgradeable
{
    /// @notice Accepts the production resolver's constructor shape.
    /// @dev The constructor argument is unused by this test implementation.
    constructor(
        address /* contractNamer */
    )
    {}

    /// @inheritdoc IHCARegistrationResolver
    function initialize(address, uint256, bytes[] calldata) external initializer {
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IHCARegistrationResolver
    function authorizeNameRoles(bytes calldata, uint256, address, bool)
        external
        pure
        returns (bool success)
    {
        return true;
    }

    /// @inheritdoc IProxyAuthorization
    function canUpgradeFrom(address) external pure returns (bool allowed) {
        return true;
    }

    /// @dev Allows every upgrade because authorization behavior is outside this mock's scope.
    function _authorizeUpgrade(address) internal override {}
}


/// @title Mock Validator Module
/// @notice Test-only ERC-7579 validator that rejects user operations.
contract MockValidatorModule is IValidator {
    /// @notice Always fails ERC-4337 validation.
    function validateUserOp(PackedUserOperation calldata, bytes32) external pure returns (uint256) {
        return 1;
    }

    /// @notice Always fails ERC-1271 validation.
    function isValidSignatureWithSender(address, bytes32, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(0);
    }

    /// @notice No-op install hook.
    function onInstall(bytes calldata) external pure {}

    /// @notice No-op uninstall hook.
    function onUninstall(bytes calldata) external pure {}

    /// @notice Reports the validator module type.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 1;
    }

    /// @notice Always reports initialized.
    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}


/// @title Mock Executor Module
/// @notice Test-only ERC-7579 executor with no behavior.
contract MockExecutorModule is IExecutor {
    /// @notice No-op install hook.
    function onInstall(bytes calldata) external pure {}

    /// @notice No-op uninstall hook.
    function onUninstall(bytes calldata) external pure {}

    /// @notice Reports the executor module type.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 2;
    }

    /// @notice Unused module-type encoding.
    function getModuleTypes() external pure returns (EncodedModuleTypes) {}

    /// @notice Always reports initialized.
    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}
