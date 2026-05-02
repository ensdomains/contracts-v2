// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {StringUtils} from "@ens/contracts/utils/StringUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    EnhancedAccessControl
} from "../access-control/EnhancedAccessControl.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";
import {LibHalving} from "./libraries/LibHalving.sol";

uint256 constant ROLE_UPDATE_TOKEN = 1 << 0;
uint256 constant ROLE_UPDATE_TOKEN_ADMIN = ROLE_UPDATE_TOKEN << 128;

uint256 constant ROLE_DISABLE_TOKEN = 1 << 4;
uint256 constant ROLE_DISABLE_TOKEN_ADMIN = ROLE_DISABLE_TOKEN << 128;

/// @dev Default roles for the oracle.
uint256 constant DEFAULT_ROLE_BITMAP = ROLE_UPDATE_TOKEN |
    ROLE_UPDATE_TOKEN_ADMIN |
    ROLE_DISABLE_TOKEN_ADMIN;

/// @dev Initialization-time structure for discounts.
/// @param duration Duration threshold, in seconds.
/// @param numerator Discount numerator, relative to `DISCOUNT_DENOMINATOR`.
struct DiscountPoint {
    uint64 duration;
    uint128 numerator;
}

/// @dev Initialization-time structure for payment tokens.
struct PaymentRatio {
    IERC20 token;
    uint128 numer;
    uint128 denom;
}

/// @notice Configurable rent pricing oracle with three components:
///
/// 1. Base rate: per-second cost indexed by label codepoint count. Shorter names cost more.
///    Rates are stored in an array where index `i` corresponds to `i+1` codepoints; labels
///    longer than the array use the last entry.
/// 2. Duration discount: piecewise-linear function defined by discount points. Each point
///    specifies an interval duration and its discount rate. The integral over the registration
///    period determines the effective discount. Rewards longer registrations.
/// 3. Expiry premium: exponential decay from an initial premium with a configurable halving
///    period, reaching zero at the end of the premium period. Only charged to new owners of
///    recently expired names; prior owners and renewals are exempt.
///
/// Payment tokens have configurable exchange rates (numerator/denominator ratios). Final
/// prices are converted via `Math.mulDiv` with ceiling rounding to prevent underpayment.
///
contract StandardRentPriceOracle is EnhancedAccessControl, IRentPriceOracle {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Internal numerator/denominator pair representing a payment token's exchange rate relative to base pricing units.
    struct Ratio {
        uint128 numer;
        uint128 denom;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
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

    /// @dev Per-second base rates indexed by codepoint count; `_baseRatePerCp[i]` prices labels with `i+1` codepoints.
    uint256[] internal _baseRatePerCp;

    /// @dev Strictly increasing discount durations.
    uint64[] internal _discountDurations;

    /// @dev Strictly decreasing discount numerators, relative to `DISCOUNT_DENOMINATOR`.
    uint128[] internal _discountNumerators;

    /// @dev Exchange rates for each accepted payment token, mapping token address to its numerator/denominator ratio.
    mapping(IERC20 paymentToken => Ratio ratio) internal _paymentRatios;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `paymentToken` has changed.
    /// @param paymentToken The payment token.
    /// @param numer The numerator of the exchange rate.
    /// @param denom The denominator of the exchange rate, or 0 if disabled.
    event PaymentTokenUpdated(
        IERC20 indexed paymentToken,
        uint128 numer,
        uint128 denom
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Invalid payment token exchange rate.
    /// @dev Error selector: `0x648564d3`
    error InvalidRatio();

    /// @notice Invalid discount configuration.
    /// @dev Error selector: `0x997ea360`
    error InvalidDiscount();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes StandardRentPriceOracle.
    /// @param rootAccount Account granted root roles.
    /// @param baseRatePerCp Base rates, in standard units per second.
    /// @param discountPoints List of discount points.
    /// @param discountDenominator Denominator for discounts.
    /// @param premiumPriceInitial Premium initial price, in standard units.
    /// @param premiumHalvingPeriod Premium halving period, in seconds.
    /// @param premiumPeriod Premium period, in seconds.
    /// @param paymentRatios List of payment tokens with exchange rates.
    constructor(
        address rootAccount,
        uint256[] memory baseRatePerCp,
        DiscountPoint[] memory discountPoints,
        uint128 discountDenominator,
        uint256 premiumPriceInitial,
        uint64 premiumHalvingPeriod,
        uint64 premiumPeriod,
        PaymentRatio[] memory paymentRatios
    ) HCAEquivalence(IHCAFactoryBasic(address(0))) {
        _grantRoles(ROOT_RESOURCE, DEFAULT_ROLE_BITMAP, rootAccount, false);

        _baseRatePerCp = baseRatePerCp;

        uint256 n = discountPoints.length;
        if (n > 0) {
            uint64 duration;
            uint128 numerator = discountDenominator;
            uint64[] memory durations = new uint64[](n);
            uint128[] memory numerators = new uint128[](n);
            for (uint256 i; i < n; ++i) {
                DiscountPoint memory pt = discountPoints[i];
                if (pt.duration <= duration || pt.numerator >= numerator) {
                    revert InvalidDiscount(); // not strictly monotonic
                }
                durations[i] = duration = pt.duration;
                numerators[i] = numerator = pt.numerator;
            }
            _discountDurations = durations;
            _discountNumerators = numerators;
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

        for (uint256 i; i < paymentRatios.length; ++i) {
            PaymentRatio memory pr = paymentRatios[i];
            if (pr.numer == 0 || pr.denom == 0) {
                revert InvalidRatio();
            }
            _paymentRatios[pr.token] = Ratio(pr.numer, pr.denom);
            emit PaymentTokenUpdated(pr.token, pr.numer, pr.denom);
        }
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IRentPriceOracle).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Update `paymentToken` support and/or exchange rate.
    /// @dev Reverts if invalid exchange rate or no change occured.
    /// @param paymentToken The payment token.
    /// @param numer The numerator of the exchange rate.
    /// @param denom The denominator of the exchange rate, or 0 to disable.
    function updatePaymentToken(
        IERC20 paymentToken,
        uint128 numer,
        uint128 denom
    ) external onlyRootRoles(ROLE_UPDATE_TOKEN) {
        Ratio memory ratio = _paymentRatios[paymentToken];
        if (denom > 0) {
            if (numer == 0) {
                revert InvalidRatio();
            }
            require(ratio.numer != numer && ratio.denom != denom);
            _paymentRatios[paymentToken] = Ratio(numer, denom);
            emit PaymentTokenUpdated(paymentToken, numer, denom);
        } else {
            require(ratio.denom > 0);
            delete _paymentRatios[paymentToken];
            emit PaymentTokenUpdated(paymentToken, 0, 0);
        }
    }

    /// @notice Disable `paymentToken` support.
    /// @dev Reverts if already disabled.
    /// @param paymentToken The payment token.
    function disablePaymentToken(
        IERC20 paymentToken
    ) external onlyRootRoles(ROLE_DISABLE_TOKEN) {
        require(_paymentRatios[paymentToken].denom > 0);
        emit PaymentTokenUpdated(paymentToken, 0, 0);
    }

    /// @notice Get all base rates, in standard units per second.
    function getBaseRates() external view returns (uint256[] memory) {
        return _baseRatePerCp;
    }

    /// @notice Get all discount durations, in seconds.
    function getDiscountPoints()
        external
        view
        returns (DiscountPoint[] memory v)
    {
        uint64[] memory durations = _discountDurations;
        uint128[] memory numerators = _discountNumerators;
        v = new DiscountPoint[](durations.length);
        for (uint256 i; i < durations.length; ++i) {
            v[i] = DiscountPoint(durations[i], numerators[i]);
        }
    }

    /// @notice Check if a `label` is valid. Does not check if normalized.
    /// @param label The name to check.
    /// @return `true` if the `label` is valid.
    function isValid(string calldata label) external view returns (bool) {
        return getBasePrice(label, 1) > 0;
    }

    /// @notice Get numerator/denominator for `paymentToken`.
    /// @param paymentToken The payment token.
    /// @return numer The numerator of the exchange rate.
    /// @return denom The denominator of the exchange rate.
    function getPaymentTokenRatio(
        IERC20 paymentToken
    ) external view returns (uint128 numer, uint128 denom) {
        Ratio storage ratio = _paymentRatios[paymentToken];
        return (ratio.numer, ratio.denom);
    }

    /// @notice Check if `paymentToken` is supported for payment.
    /// @param paymentToken The payment token.
    /// @return `true` if `paymentToken` is supported.
    function isPaymentToken(IERC20 paymentToken) external view returns (bool) {
        return _paymentRatios[paymentToken].denom > 0;
    }

    /// @inheritdoc IRentPriceOracle
    function getRegisterPrice(
        string calldata label,
        uint64 available,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 base, uint256 premium) {
        base = _requireBasePrice(label, duration);
        Ratio memory ratio = _requirePaymentToken(paymentToken);
        premium = getPremiumPriceAfter(available);
        if (premium > 0) {
            base += premium; // total
            premium = _toAmount(premium, ratio);
        }
        base = _toAmount(base, ratio) - premium; // ensure: f(a+b) - f(a) == f(b)
    }

    /// @inheritdoc IRentPriceOracle
    function getRenewPrice(
        string calldata label,
        uint64 /*expiry*/,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256) {
        return
            _toAmount(
                _requireBasePrice(label, duration),
                _requirePaymentToken(paymentToken)
            );
    }

    /// @notice Convert arbitrary standard units to payment token amount.
    /// @param value An arbitrary value, in standard units.
    /// @param paymentToken The payment token.
    /// @return The amount of payment token.
    function convertUnits(
        uint256 value,
        IERC20 paymentToken
    ) external view returns (uint256) {
        return _toAmount(value, _requirePaymentToken(paymentToken));
    }

    /// @notice Apply discount function to an arbitrary value.
    /// @param value An arbitrary value.
    /// @param duration The duration, in seconds.
    /// @return `value` reduced by discount.
    function applyDiscount(
        uint256 value,
        uint64 duration
    ) public view returns (uint256) {
        uint64[] memory v = _discountDurations;
        uint256 i;
        while (i < v.length && duration >= v[i]) ++i;
        return
            i == 0
                ? value
                : Math.mulDiv(
                    value,
                    _discountNumerators[i - 1],
                    DISCOUNT_DENOMINATOR
                );
    }

    /// @notice Get base price to register or renew `label` for `duration` seconds.
    /// @param label The name to price.
    /// @param duration The duration, in seconds.
    /// @return The base price, in standard units, or 0 if not valid.
    function getBasePrice(
        string calldata label,
        uint64 duration
    ) public view returns (uint256) {
        uint256 len = bytes(label).length;
        if (len == 0 || len > 255) return 0; // too long or too short
        uint256 nbr = _baseRatePerCp.length;
        if (nbr == 0) return 0; // no base rates
        uint256 ncp = getLength(label);
        uint256 rate = _baseRatePerCp[(ncp > nbr ? nbr : ncp) - 1];
        return applyDiscount(rate * duration, duration);
    }

    /// @notice Get premium price for a duration after expiry.
    /// @dev Defined over `[0, premiumPeriod)`.
    /// @param duration The time after expiration, in seconds.
    /// @return The premium price, in standard units.
    function getPremiumPriceAfter(
        uint64 duration
    ) public view returns (uint256) {
        return
            duration < PREMIUM_PERIOD
                ? LibHalving.halving(
                    PREMIUM_PRICE_INITIAL,
                    PREMIUM_HALVING_PERIOD,
                    duration
                ) - PREMIUM_PRICE_OFFSET
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
    function _requireBasePrice(
        string calldata label,
        uint64 duration
    ) internal view returns (uint256 rate) {
        rate = getBasePrice(label, duration);
        if (rate == 0) {
            revert NotValid(label);
        }
    }

    /// @dev Ensure `paymentToken` is supported.
    function _requirePaymentToken(
        IERC20 paymentToken
    ) internal view returns (Ratio memory ratio) {
        ratio = _paymentRatios[paymentToken];
        if (ratio.denom == 0) {
            revert PaymentTokenNotSupported(paymentToken);
        }
    }

    /// @dev Convert standard units to token amount.
    function _toAmount(
        uint256 value,
        Ratio memory ratio
    ) internal pure returns (uint256) {
        return
            ratio.numer == ratio.denom
                ? value
                : Math.mulDiv(
                    value,
                    ratio.numer,
                    ratio.denom,
                    Math.Rounding.Ceil
                );
    }
}
