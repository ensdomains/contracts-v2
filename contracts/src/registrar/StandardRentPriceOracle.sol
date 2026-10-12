// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {StringUtils} from "@ens/contracts/utils/StringUtils.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";

import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";
import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";
import {LibHalving} from "./libraries/LibHalving.sol";

/// @dev Nybble 0: authorizes updating tokens. Root only.
uint256 constant ROLE_UPDATE_TOKEN = 1 << 0;

/// @dev Nybble 32: authorizes setting `ROLE_UPDATE_TOKEN`.
uint256 constant ROLE_UPDATE_TOKEN_ADMIN = ROLE_UPDATE_TOKEN << 128;

/// @dev Nybble 1: authorizes disabling tokens. Root only.
uint256 constant ROLE_DISABLE_TOKEN = 1 << 4;

/// @dev Nybble 33: authorizes setting `ROLE_DISABLE_TOKEN`.
uint256 constant ROLE_DISABLE_TOKEN_ADMIN = ROLE_DISABLE_TOKEN << 128;

/// @dev Nybble 2: authorizes contract naming. Root only.
uint256 constant ROLE_CAN_NAME = 1 << 8;

/// @dev Nybble 34: authorizes setting `ROLE_CAN_NAME`.
uint256 constant ROLE_CAN_NAME_ADMIN = ROLE_CAN_NAME << 128;

/// @dev Default root roles assigned at construction.
uint256 constant DEFAULT_ROLE_BITMAP =
    ROLE_UPDATE_TOKEN |
    ROLE_UPDATE_TOKEN_ADMIN |
    ROLE_DISABLE_TOKEN |
    ROLE_DISABLE_TOKEN_ADMIN |
    ROLE_CAN_NAME |
    ROLE_CAN_NAME_ADMIN;

/// @dev Initialization-time structure for a discount point.
/// @param duration Duration threshold, in seconds.
/// @param numer Discount numerator, relative to `DISCOUNT_DENOMINATOR`.
struct DiscountPoint {
    uint64 duration;
    uint128 numer;
}

/// @dev Initialization-time structure for `PaymentConfig` with `paymentToken`
struct PaymentConfigWithToken {
    address paymentToken;
    uint128 numer;
    uint128 denom;
    IChainlinkAggregator oracle;
    bool flip;
    uint64 maxAge;
}

/// @notice Rent pricing oracle with (4) components:
///
/// 1. Base rates: per-second cost indexed by label codepoint count. Shorter names cost more.
///    Rates are stored in an array where index `i` corresponds to `i+1` codepoints; labels
///    longer than the array use the last entry.
/// 2. Duration discounts: increasing expiry reduce costs. Each dicount point specifies a
///    duration and a numerator. `1 - numerator / DISCOUNT_DENOMINATOR` determines the
///    discount percentage. Rewards longer registrations.
/// 3. Expiry premium: exponential decay from an initial premium with a configurable halving
///    period, reaching zero at the end of the premium period. Only charged to new owners of
///    recently expired names; renewals are exempt.
/// 4. Configurable payment tokens: payment tokens and their exchange rates can be managed
///    with `ROLE_UPDATE_TOKEN`. The exchange rate converts the token to standard units.
///    Since no external oracle is consulted, only stablecoins.
///    Accounts with `ROLE_DISABLE_TOKEN` can only disable payment tokens.
///
/// If `msg.value > 0`, uses ether for payment.
///
contract StandardRentPriceOracle is EnhancedAccessControl, IRentPriceOracle, IContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Storage structure for payment configuration.
    /// @param paymentToken The payment token.
    /// @param numer Exchange rate numerator, relative to base units.
    /// @param denom Exchange rate denominator, relative to base units.
    /// @param oracle USD-based Chainlink oracle (optional).
    /// @param flip `true` if the oracle response should be flipped (X/USD => USD/X).
    /// @param maxAge Maximum accepted age of the oracle response, in seconds.
    struct PaymentConfig {
        uint128 numer;
        uint128 denom;
        IChainlinkAggregator oracle;
        bool flip;
        uint64 maxAge;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Denominator for discounts.
    uint128 public immutable DISCOUNT_DENOMINATOR;

    /// @notice Starting value of the exponential decay premium for recently expired names, in base pricing units.
    uint256 public immutable PREMIUM_PRICE_INITIAL;

    /// @notice Number of seconds for the premium to halve in value.
    uint64 public immutable PREMIUM_HALVING_PERIOD;

    /// @notice Total duration of the premium window; the premium reaches zero at this offset from expiry.
    uint64 public immutable PREMIUM_PERIOD;

    /// @notice Precomputed premium halving at end of period.
    uint256 public immutable PREMIUM_PRICE_OFFSET;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Per-second base rates indexed by codepoint count; `_baseRatePerCp[i]` prices labels with `i+1` codepoints.
    uint256[] internal _baseRatePerCp;

    /// @dev Ordered discount points, relative to `DISCOUNT_DENOMINATOR`.
    DiscountPoint[] internal _discountPoints;

    /// @dev Exchange rates for each accepted payment token, mapping token address to its payment configuration.
    mapping(address paymentToken => PaymentConfig pc) internal _paymentConfigs;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `paymentToken` has changed.
    /// @param paymentToken The payment token.
    /// @param numer Exchange rate numerator, relative to base units.
    /// @param denom Exchange rate denominator, relative to base units, or 0 if disabled.
    /// @param oracle USD-based Chainlink oracle (optional).
    /// @param flip `true` if the oracle response should be flipped (X/USD => USD/X).
    /// @param maxAge Maximum accepted age of the oracle response, in seconds.
    event PaymentTokenUpdated(
        address indexed paymentToken,
        uint128 numer,
        uint128 denom,
        IChainlinkAggregator oracle,
        bool flip,
        uint64 maxAge
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Invalid base rates.
    /// @dev Error selector: `0xde276447`
    error InvalidBaseRates();

    /// @notice Invalid payment token exchange rate.
    /// @dev Error selector: `0x648564d3`
    error InvalidRatio();

    /// @notice Invalid discount configuration.
    /// @dev Error selector: `0x997ea360`
    error InvalidDiscount();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootAccount Account granted root roles.
    /// @param baseRatePerCp Base rates, in standard units per second.
    /// @param discountPoints List of discount points.
    /// @param discountDenominator Denominator for discounts.
    /// @param premiumPriceInitial Premium initial price, in standard units.
    /// @param premiumHalvingPeriod Premium halving period, in seconds.
    /// @param premiumPeriod Premium period, in seconds.
    /// @param paymentConfigs List of payment token configurations.
    constructor(
        address rootAccount,
        uint256[] memory baseRatePerCp,
        DiscountPoint[] memory discountPoints,
        uint128 discountDenominator,
        uint256 premiumPriceInitial,
        uint64 premiumHalvingPeriod,
        uint64 premiumPeriod,
        PaymentConfigWithToken[] memory paymentConfigs
    )
    {
        _grantRoles(ROOT_RESOURCE, DEFAULT_ROLE_BITMAP, rootAccount, false);

        if (baseRatePerCp.length == 0) {
            revert InvalidBaseRates();
        }
        _baseRatePerCp = baseRatePerCp;

        uint256 n = discountPoints.length;
        if (n > 0) {
            uint64 duration; // must increase
            uint128 numer = discountDenominator; // must decrease
            for (uint256 i; i < n; ++i) {
                DiscountPoint memory p = discountPoints[i];
                if (p.duration <= duration || p.numer >= numer) {
                    revert InvalidDiscount(); // not strictly monotonic
                }
                duration = p.duration;
                numer = p.numer;
                _discountPoints.push(p);
            }
            if (numer == 0) {
                revert InvalidDiscount(); // free
            }
            DISCOUNT_DENOMINATOR = discountDenominator;
        }

        PREMIUM_PRICE_INITIAL = premiumPriceInitial;
        PREMIUM_HALVING_PERIOD = premiumHalvingPeriod;
        PREMIUM_PERIOD = premiumPeriod;
        PREMIUM_PRICE_OFFSET = LibHalving.halving(
            premiumPriceInitial,
            premiumHalvingPeriod,
            premiumPeriod
        );

        for (uint256 i; i < paymentConfigs.length; ++i) {
            PaymentConfigWithToken memory pc = paymentConfigs[i];
            if (pc.numer == 0 || pc.denom == 0) {
                revert InvalidRatio();
            }
            _paymentConfigs[pc.paymentToken] = PaymentConfig(
                pc.numer,
                pc.denom,
                pc.oracle,
                pc.flip,
                pc.maxAge
            );
            emit PaymentTokenUpdated(
                pc.paymentToken,
                pc.numer,
                pc.denom,
                pc.oracle,
                pc.flip,
                pc.maxAge
            );
        }
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IRentPriceOracle).interfaceId ||
            interfaceId == type(IContractNamer).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Update `paymentToken` support and/or exchange rate.
    /// @param paymentToken The payment token.
    /// @param pc The new payment configuration.
    function updatePaymentToken(address paymentToken, PaymentConfig calldata pc)
        external
        onlyRootRoles(ROLE_UPDATE_TOKEN)
    {
        if (pc.denom > 0) {
            if (pc.numer == 0) {
                revert InvalidRatio();
            }
            _paymentConfigs[paymentToken] = pc;
            emit PaymentTokenUpdated(paymentToken, pc.numer, pc.denom, pc.oracle, pc.flip, pc.maxAge);
        } else if (_paymentConfigs[paymentToken].denom > 0) {
            delete _paymentConfigs[paymentToken];
            emit PaymentTokenUpdated(paymentToken, 0, 0, IChainlinkAggregator(address(0)), false, 0);
        }
    }

    /// @notice Disable `paymentToken` support.
    /// @param paymentToken The payment token.
    function disablePaymentToken(address paymentToken) external onlyRootRoles(ROLE_DISABLE_TOKEN) {
        if (_paymentConfigs[paymentToken].denom > 0) {
            delete _paymentConfigs[paymentToken];
            emit PaymentTokenUpdated(paymentToken, 0, 0, IChainlinkAggregator(address(0)), false, 0);
        }
    }

    /// @inheritdoc IContractNamer
    function isContractNamer(address namer) external view returns (bool) {
        return hasRootRoles(ROLE_CAN_NAME, namer);
    }

    /// @notice Get all base rates, in standard units per second.
    function getBaseRates() external view returns (uint256[] memory) {
        return _baseRatePerCp;
    }

    /// @notice Get all discount durations, in seconds.
    function getDiscountPoints() external view returns (DiscountPoint[] memory v) {
        return _discountPoints;
    }

    /// @notice Check if a `label` is valid. Does not check if normalized.
    /// @param label The name to check.
    /// @return `true` if the `label` is valid.
    function isValid(string calldata label) external view returns (bool) {
        return getBasePrice(label, 1) > 0;
    }

    /// @notice Get effective numerator/denominator for `paymentToken` including oracle.
    /// @param paymentToken The payment token.
    /// @return numer The numerator of the exchange rate.
    /// @return denom The denominator of the exchange rate.
    function getPaymentTokenRatio(address paymentToken)
        external
        view
        returns (uint256 numer, uint256 denom)
    {
        (numer, denom) = _computePaymentRatio(paymentToken);
    }

    /// @notice Get underlying `paymentToken` configuration.
    /// @param paymentToken The payment token.
    /// @return The payment configuration.
    function getPaymentTokenConfiguration(address paymentToken)
        external
        view
        returns (PaymentConfig memory)
    {
        return _paymentConfigs[paymentToken];
    }

    /// @inheritdoc IRentPriceOracle
    function isPaymentToken(address paymentToken) external view returns (bool) {
        return _paymentConfigs[paymentToken].denom > 0;
    }

    /// @inheritdoc IRentPriceOracle
    function getRegisterPrice(
        string calldata label,
        uint64 available,
        uint64 duration,
        address paymentToken
    )
        external
        view
        returns (uint256 base, uint256 premium)
    {
        base = _requireBasePrice(label, duration);
        (uint256 numer, uint256 denom) = _computePaymentRatio(paymentToken);
        premium = getPremiumPriceAfter(available);
        if (premium > 0) {
            base += premium; // total
            premium = _toAmount(premium, numer, denom);
        }
        base = _toAmount(base, numer, denom) - premium; // ensure: f(a+b) - f(a) == f(b)
    }

    /// @inheritdoc IRentPriceOracle
    function getRenewPrice(
        string calldata label,
        uint64 /*expiry*/,
        uint64 duration,
        address paymentToken
    )
        external
        view
        returns (uint256)
    {
        (uint256 numer, uint256 denom) = _computePaymentRatio(paymentToken);
        return _toAmount(_requireBasePrice(label, duration), numer, denom);
    }

    /// @notice Convert arbitrary standard units to payment token amount.
    /// @param value An arbitrary value, in standard units.
    /// @param paymentToken The payment token.
    /// @return The amount of payment token.
    function convertUnits(uint256 value, address paymentToken) external view returns (uint256) {
        (uint256 numer, uint256 denom) = _computePaymentRatio(paymentToken);
        return _toAmount(value, numer, denom);
    }

    /// @notice Apply discount function to an arbitrary value.
    /// @param value An arbitrary value.
    /// @param duration The duration, in seconds.
    /// @return `value` reduced by discount.
    function applyDiscount(uint256 value, uint64 duration) public view returns (uint256) {
        uint256 n = _discountPoints.length;
        uint128 numer;
        for (uint256 i; i < n; ++i) {
            DiscountPoint storage p = _discountPoints[i];
            if (duration < p.duration) {
                break;
            }
            numer = p.numer;
        }
        return
            numer == 0
                ? value
                : Math.mulDiv(value, numer, DISCOUNT_DENOMINATOR);
    }

    /// @notice Get base price to register or renew `label` for `duration` seconds.
    /// @param label The name to price.
    /// @param duration The duration, in seconds.
    /// @return The base price, in standard units, or 0 if not valid.
    function getBasePrice(string calldata label, uint64 duration) public view returns (uint256) {
        uint256 n = bytes(label).length;
        if (n == 0 || n > 255) {
            return 0; // too long or too short
        }
        uint256 i = getLength(label);
        if (i > _baseRatePerCp.length) {
            i = _baseRatePerCp.length;
        }
        return applyDiscount(_baseRatePerCp[i - 1] * duration, duration);
    }

    /// @notice Get premium price for a duration after expiry.
    /// @dev Defined over `[0, premiumPeriod)`.
    /// @param duration The time after expiration, in seconds.
    /// @return The premium price, in standard units.
    function getPremiumPriceAfter(uint64 duration) public view returns (uint256) {
        return
            duration < PREMIUM_PERIOD
                ? LibHalving.halving(PREMIUM_PRICE_INITIAL, PREMIUM_HALVING_PERIOD, duration) -
                PREMIUM_PRICE_OFFSET
                : 0;
    }

    /// @notice Check length of a name.
    /// @param label The name to check.
    /// @return The number of Unicode codepoints.
    function getLength(string calldata label) public pure returns (uint256) {
        return StringUtils.strlen(label);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Compute `rate * duration` and apply discount.
    function _requireBasePrice(string calldata label, uint64 duration)
        internal
        view
        returns (uint256 rate)
    {
        rate = getBasePrice(label, duration);
        if (rate == 0) {
            revert NotValid(label);
        }
    }

    /// @dev Determine ratio for `paymentToken` including oracle.
    function _computePaymentRatio(address paymentToken)
        internal
        view
        returns (uint256 numer, uint256 denom)
    {
        PaymentConfig memory pc = _paymentConfigs[paymentToken];
        numer = pc.numer;
        denom = pc.denom;
        if (denom == 0) {
            revert PaymentTokenNotSupported(paymentToken);
        }
        if (address(pc.oracle) != address(0)) {
            (, int256 answer, , uint256 updatedAt, ) = pc.oracle.latestRoundData();
            if (answer < 1) {
                revert InvalidOracleResponse(paymentToken, answer);
            }
            if (
                updatedAt == 0 ||
                updatedAt > block.timestamp ||
                (block.timestamp - updatedAt) > pc.maxAge
            ) {
                revert StaleOracleResponse(paymentToken, updatedAt, block.timestamp);
            }
            uint256 scale = 10 ** pc.oracle.decimals();
            if (pc.flip) {
                numer *= scale;
                denom *= uint256(answer);
            } else {
                numer *= uint256(answer);
                denom *= scale;
            }
        }
    }

    /// @dev Convert standard units to token amount.
    function _toAmount(uint256 value, uint256 numer, uint256 denom) internal pure returns (uint256) {
        return
            numer == denom
                ? value
                : Math.mulDiv(value, numer, denom, Math.Rounding.Ceil);
    }
}
