// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IETHRegistrar} from "./interfaces/IETHRegistrar.sol";
import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";

uint256 constant REGISTRATION_ROLE_BITMAP = 0 |
    RegistryRolesLib.ROLE_SET_SUBREGISTRY |
    RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN |
    RegistryRolesLib.ROLE_SET_RESOLVER |
    RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
    RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;

uint256 constant ROLE_SET_ORACLE = 1 << 0;

contract ETHRegistrar is IETHRegistrar, EnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    IPermissionedRegistry public immutable REGISTRY;

    address public immutable BENEFICIARY;

    uint64 public immutable MIN_COMMITMENT_AGE;

    uint64 public immutable MAX_COMMITMENT_AGE;

    uint64 public immutable MIN_REGISTER_DURATION;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    IRentPriceOracle public rentPriceOracle;

    /// @inheritdoc IETHRegistrar
    mapping(bytes32 commitment => uint64 commitTime) public commitmentAt;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event RentPriceOracleChanged(IRentPriceOracle oracle);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IPermissionedRegistry registry,
        IHCAFactoryBasic hcaFactory,
        address beneficiary,
        uint64 minCommitmentAge,
        uint64 maxCommitmentAge,
        uint64 minRegisterDuration,
        IRentPriceOracle rentPriceOracle_
    ) HCAEquivalence(hcaFactory) {
        if (maxCommitmentAge <= minCommitmentAge) {
            revert MaxCommitmentAgeTooLow();
        }
        _grantRoles(ROOT_RESOURCE, EACBaseRolesLib.ALL_ROLES, _msgSender(), true);

        REGISTRY = registry;
        BENEFICIARY = beneficiary;
        MIN_COMMITMENT_AGE = minCommitmentAge;
        MAX_COMMITMENT_AGE = maxCommitmentAge;
        MIN_REGISTER_DURATION = minRegisterDuration;

        rentPriceOracle = rentPriceOracle_;
        emit RentPriceOracleChanged(rentPriceOracle_);
    }

    /// @inheritdoc EnhancedAccessControl
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(EnhancedAccessControl) returns (bool) {
        return
            interfaceId == type(IETHRegistrar).interfaceId ||
            interfaceId == type(IRentPriceOracle).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Change the rent price oracle.
    function setRentPriceOracle(IRentPriceOracle oracle) external onlyRootRoles(ROLE_SET_ORACLE) {
        rentPriceOracle = oracle;
        emit RentPriceOracleChanged(oracle);
    }

    /// @inheritdoc IETHRegistrar
    function commit(bytes32 commitment) external {
        if (commitmentAt[commitment] + MAX_COMMITMENT_AGE > block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitmentAt[commitment] = uint64(block.timestamp);
        emit CommitmentMade(commitment);
    }

    /// @inheritdoc IETHRegistrar
    function register(
        string calldata label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external returns (uint256 tokenId) {
        if (duration < MIN_REGISTER_DURATION) {
            revert DurationTooShort(duration, MIN_REGISTER_DURATION);
        }
        if (owner == address(0)) {
            revert InvalidOwner();
        }
        if (!isAvailable(label)) {
            revert NameNotAvailable(label); // otherwise register() reverts EACUnauthorizedAccountRoles
        }
        _consumeCommitment(
            makeCommitment(label, owner, secret, subregistry, resolver, duration, referrer)
        ); // reverts if no commitment
        (uint256 base, uint256 premium) = rentPrice(label, owner, duration, paymentToken); // reverts if !isValid or !isPaymentToken
        SafeERC20.safeTransferFrom(paymentToken, _msgSender(), BENEFICIARY, base + premium); // reverts if payment failed
        tokenId = REGISTRY.register(
            label,
            owner,
            subregistry,
            resolver,
            REGISTRATION_ROLE_BITMAP,
            uint64(block.timestamp) + duration
        ); // reverts if not available
        emit NameRegistered(
            tokenId,
            label,
            owner,
            subregistry,
            resolver,
            duration,
            paymentToken,
            referrer,
            base,
            premium
        );
    }

    /// @inheritdoc IETHRegistrar
    function renew(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external {
        IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
        if (state.status == IPermissionedRegistry.Status.AVAILABLE) {
            revert NameIsAvailable(label);
        }
        uint64 expiry = state.expiry + duration;
        (uint256 base, ) = rentPrice(label, state.latestOwner, duration, paymentToken); // reverts if !isValid or !isPaymentToken or duration is 0
        SafeERC20.safeTransferFrom(paymentToken, _msgSender(), BENEFICIARY, base); // reverts if payment failed
        REGISTRY.renew(state.tokenId, expiry);
        emit NameRenewed(state.tokenId, label, duration, expiry, paymentToken, referrer, base);
    }

    /// @inheritdoc IRentPriceOracle
    function isPaymentToken(IERC20 paymentToken) external view returns (bool) {
        return rentPriceOracle.isPaymentToken(paymentToken);
    }

    /// @inheritdoc IRentPriceOracle
    function isValid(string calldata label) external view returns (bool) {
        return rentPriceOracle.isValid(label);
    }

    /// @inheritdoc IETHRegistrar
    /// @dev Does not check if normalized or valid.
    function isAvailable(string memory label) public view returns (bool) {
        return REGISTRY.getStatus(LibLabel.id(label)) == IPermissionedRegistry.Status.AVAILABLE;
    }

    /// @inheritdoc IRentPriceOracle
    function rentPrice(
        string memory label,
        address owner,
        uint64 duration,
        IERC20 paymentToken
    ) public view returns (uint256 base, uint256 premium) {
        return rentPriceOracle.rentPrice(label, owner, duration, paymentToken);
    }

    /// @inheritdoc IETHRegistrar
    function makeCommitment(
        string calldata label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) public pure override returns (bytes32) {
        return
            keccak256(abi.encode(label, owner, secret, subregistry, resolver, duration, referrer));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Assert `commitment` is timely, then delete it.
    function _consumeCommitment(bytes32 commitment) internal {
        uint64 t = uint64(block.timestamp);
        uint64 t0 = commitmentAt[commitment];
        uint64 tMin = t0 + MIN_COMMITMENT_AGE;
        if (t < tMin) {
            revert CommitmentTooNew(commitment, tMin, t);
        }
        uint64 tMax = t0 + MAX_COMMITMENT_AGE;
        if (t >= tMax) {
            revert CommitmentTooOld(commitment, tMax, t);
        }
        delete commitmentAt[commitment];
    }
}
