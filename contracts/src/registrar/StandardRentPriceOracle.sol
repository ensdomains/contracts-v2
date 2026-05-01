// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {StringUtils} from "@ens/contracts/utils/StringUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {
    IPermissionedRegistry
} from "../registry/interfaces/IPermissionedRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";

import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";
import {LibHalving} from "./libraries/LibHalving.sol";

/// @dev Roles for payment processors.
uint256 constant PAYMENT_ROLE_BITMAP = RegistryRolesLib.ROLE_RENEW |
    RegistryRolesLib.ROLE_REGISTRAR;

/// @dev Defines one segment of the piecewise-linear discount function.
/// @param t Incremental time interval for discount, in seconds.
/// @param value Discount percentage, relative to `type(uint128).max`.
struct DiscountPoint {
    uint64 t;
    uint128 value;
}

/// @dev Initialization-time structure pairing a payment token with its exchange rate (numerator/denominator).
struct PaymentRatio {
    address token;
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
contract StandardRentPriceOracle is ERC165, Ownable, IRentPriceOracle {
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

    /// @notice ENSv2 .eth `PermissionedRegistry`.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @notice Address that receives payments.
    address public beneficiary;

    /// @notice Minimum register duration, in seconds.
    uint64 public minRegisterDuration;

    /// @notice Starting value of the exponential decay premium for recently expired names, in base pricing units.
    uint256 public premiumPriceInitial;

    /// @notice Number of seconds for the premium to halve in value.
    uint64 public premiumHalvingPeriod;

    /// @notice Total duration of the premium window; the premium reaches zero at this offset from expiry.
    uint64 public premiumPeriod;

    /// @dev Per-second base rates indexed by codepoint count; `_baseRatePerCp[i]` prices labels with `i+1` codepoints.
    uint256[] internal _baseRatePerCp;

    /// @dev Ordered segments of the piecewise-linear duration discount function.
    DiscountPoint[] internal _discountPoints;

    /// @dev Exchange rates for each accepted payment token, mapping token address to its numerator/denominator ratio.
    mapping(address paymentToken => Ratio ratio) internal _paymentRatios;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `paymentToken` is now supported.
    /// @param paymentToken The payment token added.
    event PaymentTokenAdded(address indexed paymentToken);

    /// @notice `paymentToken` is no longer supported.
    /// @param paymentToken The payment token removed.
    event PaymentTokenRemoved(address indexed paymentToken);

    /// @notice `minRegisterDuration` was changed.
    /// @param duration The new duration.
    event MinimumRegisterDurationUpdated(uint64 duration);

    /// @notice `beneficiary` was changed.
    /// @param beneficiary The new beneficiary address.
    event BeneficiaryUpdated(address indexed beneficiary);

    /// @notice Discount points were changed.
    /// @param points The new discount points.
    event DiscountPointsUpdated(DiscountPoint[] points);

    /// @notice Base rates were changed.
    /// @param ratePerCp The new base rates.
    event BaseRatesUpdated(uint256[] ratePerCp);

    /// @notice Premium pricing was changed.
    /// @param initialPrice The new initial price.
    /// @param halvingPeriod The new halving period.
    /// @param period The new period.
    event PremiumPricingUpdated(
        uint256 indexed initialPrice,
        uint64 indexed halvingPeriod,
        uint64 indexed period
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Invalid payment token exchange rate.
    /// @dev Error selector: `0x648564d3`
    error InvalidRatio();

    /// @notice Invalid discount point.
    /// @dev Error selector: `0xd1be8bbe`
    error InvalidDiscountPoint();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes StandardRentPriceOracle.
    /// @param owner_ Owner of the contract.
    /// @param ethRegistry ENSv2 .eth `PermissionedRegistry`.
    /// @param beneficiary_ Address that receives payments.
    /// @param minRegisterDuration_ Minimum register duration, in seconds.
    /// @param baseRatePerCp Base rates, in base units per second.
    /// @param discountPoints Discount points.
    /// @param premiumPriceInitial_ Premium pnitial price, in base units.
    /// @param premiumHalvingPeriod_ Premium halving period, in seconds.
    /// @param premiumPeriod_ Premium period, in seconds.
    /// @param paymentRatios List of payment tokens with conversion ratios.
    constructor(
        address owner_,
        IPermissionedRegistry ethRegistry,
        address beneficiary_,
        uint64 minRegisterDuration_,
        uint256[] memory baseRatePerCp,
        DiscountPoint[] memory discountPoints,
        uint256 premiumPriceInitial_,
        uint64 premiumHalvingPeriod_,
        uint64 premiumPeriod_,
        PaymentRatio[] memory paymentRatios
    ) Ownable(owner_) {
        ETH_REGISTRY = ethRegistry;
        beneficiary = beneficiary_;
        emit BeneficiaryUpdated(beneficiary_);

        minRegisterDuration = minRegisterDuration_;
        emit MinimumRegisterDurationUpdated(minRegisterDuration_);

        _baseRatePerCp = baseRatePerCp;
        emit BaseRatesUpdated(baseRatePerCp);

        _setDiscountPoints(discountPoints);

        premiumPriceInitial = premiumPriceInitial_;
        premiumHalvingPeriod = premiumHalvingPeriod_;
        premiumPeriod = premiumPeriod_;
        emit PremiumPricingUpdated(
            premiumPriceInitial_,
            premiumHalvingPeriod_,
            premiumPeriod_
        );

        for (uint256 i; i < paymentRatios.length; ++i) {
            PaymentRatio memory x = paymentRatios[i];
            if (x.numer == 0 || x.denom == 0) {
                revert InvalidRatio();
            }
            _paymentRatios[x.token] = Ratio(x.numer, x.denom);
            emit PaymentTokenAdded(x.token);
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

    /// @notice Update the beneficiary address.
    /// @param beneficiary_ The new beneficiary address.
    function updateBeneficiary(address beneficiary_) external onlyOwner {
        beneficiary = beneficiary_;
        emit BeneficiaryUpdated(beneficiary_);
    }

    /// @notice Update the minimum register duration.
    /// @param duration The new duration.
    function updateMinimumRegisterDuration(uint64 duration) external onlyOwner {
        minRegisterDuration = duration;
        emit MinimumRegisterDurationUpdated(duration);
    }

    /// @notice Update base rates per codepoint.
    /// @dev - `ratePerCp[i]` corresponds to `i+1` codepoints.
    /// - Larger lengths are priced by `ratePerCp[-1]`.
    /// - Use rate of `0` to disable a specific length.
    /// - Use empty array to disable all registrations.
    /// - Emits `BaseRatesUpdated`.
    ///
    /// @param ratePerCp The base rates, in base units per second.
    function updateBaseRates(uint256[] calldata ratePerCp) external onlyOwner {
        _baseRatePerCp = ratePerCp;
        emit BaseRatesUpdated(ratePerCp);
    }

    /// @notice Update the discount function.
    /// @dev Notes:
    /// - Each point is (∆t, intervalDiscount).
    /// - Discounts are relative to `type(uint128).max`.
    /// - Given an average discount, solve for the corresponding interval:
    ///   * Assume: 1yr at 0% discount
    ///   * Solve: 2yr * 5% == 1yr * 0% + 1yr * x => x = 10.00%
    ///   * Point: (1yr, 10%) == (1 years, type(uint128).max / 10)
    /// - Final discount is derived from the weighted average over the intervals.
    /// - Use empty array to disable.
    /// - Emits `DiscountPointsUpdated`.
    ///
    /// @param points The new discount points.
    function updateDiscountPoints(
        DiscountPoint[] calldata points
    ) external onlyOwner {
        _setDiscountPoints(points);
    }

    /// @notice Update premium pricing function.
    /// @dev Notes:
    /// - Use `initialPrice = 0` to disable.
    /// - Use `getPremiumPriceAfter(0)` to get exact starting price.
    /// - `getPremiumPriceAfter(halvingPeriod) ~= getPremiumPriceAfter(0) / 2`.
    /// - `getPremiumPriceAfter(halvingPeriod * x) ~= getPremiumPriceAfter(0) / 2^x`.
    /// - `getPremiumPriceAfter(period) = 0`.
    /// - Emits `PremiumPricingUpdated`.
    ///
    /// @param initialPrice The initial price, in base units.
    /// @param halvingPeriod Duration until the price is reduced in half.
    /// @param period Number of seconds until the price is reduced to 0.
    function updatePremiumPricing(
        uint256 initialPrice,
        uint64 halvingPeriod,
        uint64 period
    ) external onlyOwner {
        premiumPriceInitial = initialPrice;
        premiumHalvingPeriod = halvingPeriod;
        premiumPeriod = period;
        emit PremiumPricingUpdated(initialPrice, halvingPeriod, period);
    }

    /// @notice Update `paymentToken` support and/or exchange rate.
    /// @dev Notes:
    /// - Use `denom = 0` to remove.
    /// - Emits `PaymentTokenAdded` if now supported.
    /// - Emits `PaymentTokenRemoved` if no longer supported.
    /// - Reverts if invalid exchange rate.
    ///
    /// @param paymentToken The payment token.
    /// @param numer The numerator of the exchange rate.
    /// @param denom The denominator of the exchange rate.
    function updatePaymentToken(
        address paymentToken,
        uint128 numer,
        uint128 denom
    ) external onlyOwner {
        Ratio memory ratio = _paymentRatios[paymentToken];
        if (denom > 0) {
            if (numer == 0) {
                revert InvalidRatio();
            }
            if (ratio.denom == 0) {
                emit PaymentTokenAdded(paymentToken);
            }
            _paymentRatios[paymentToken] = Ratio(numer, denom);
        } else if (ratio.denom > 0) {
            delete _paymentRatios[paymentToken];
            emit PaymentTokenRemoved(paymentToken);
        }
    }

    /// @inheritdoc IRentPriceOracle
    function processPayment(
        address from,
        address paymentToken,
        uint256 amount
    ) external payable {
        if ((ETH_REGISTRY.roles(0, msg.sender) & PAYMENT_ROLE_BITMAP) == 0) {
            revert UnauthorizedCaller(msg.sender);
        }
        SafeERC20.safeTransferFrom(
            IERC20(paymentToken),
            from,
            beneficiary,
            amount
        ); // reverts if payment failed
    }

    /// @notice Returns all base rates, in base units per second.
    function getBaseRates() external view returns (uint256[] memory) {
        return _baseRatePerCp;
    }

    /// @notice Returns all discount function points.
    function getDiscountPoints()
        external
        view
        returns (DiscountPoint[] memory)
    {
        return _discountPoints;
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
        address paymentToken
    ) external view returns (uint128 numer, uint128 denom) {
        Ratio storage ratio = _paymentRatios[paymentToken];
        return (ratio.numer, ratio.denom);
    }

    /// @notice Check if `paymentToken` is supported for payment.
    /// @param paymentToken The payment token.
    /// @return `true` if `paymentToken` is supported.
    function isPaymentToken(address paymentToken) external view returns (bool) {
        return _paymentRatios[paymentToken].denom > 0;
    }

    /// @inheritdoc IRentPriceOracle
    function getRegisterPrice(
        string calldata label,
        uint64 available,
        uint64 duration,
        address paymentToken
    ) external view returns (uint256 base, uint256 premium) {
        _requireMinimumDuration(duration, minRegisterDuration);
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
        address paymentToken
    ) external view returns (uint256) {
        _requireMinimumDuration(duration, 1);
        return
            _toAmount(
                _requireBasePrice(label, duration),
                _requirePaymentToken(paymentToken)
            );
    }

    /// @notice Get base price to register or renew `label` for `duration` seconds.
    /// @param label The name to price.
    /// @param duration The duration, in seconds.
    /// @return The base price or 0 if not valid, in base units.
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

    /// @notice Compute integral of discount function for `duration`.
    /// @dev Use `integratedDiscount(t) / t` to compute average discount.
    /// @param duration The time since now, in seconds.
    /// @return Integral of discount function over `[0, duration)`.
    function integratedDiscount(uint64 duration) public view returns (uint256) {
        uint256 n = _discountPoints.length;
        if (n == 0) return 0;
        uint256 acc;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            DiscountPoint memory p = _discountPoints[i];
            if (duration <= p.t) {
                return acc + duration * uint256(p.value);
            }
            duration -= p.t;
            acc += p.t * uint256(p.value);
            sum += p.t;
        }
        return acc + (duration * acc + sum - 1) / sum;
    }

    /// @notice Get premium price for a duration after expiry.
    /// @dev Defined over `[0, premiumPeriod)`.
    /// @param duration The time after expiration, in seconds.
    /// @return The premium price, in base units.
    function getPremiumPriceAfter(
        uint64 duration
    ) public view returns (uint256) {
        if (duration >= premiumPeriod) return 0;
        return
            LibHalving.halving(
                premiumPriceInitial,
                premiumHalvingPeriod,
                duration
            ) -
            LibHalving.halving(
                premiumPriceInitial,
                premiumHalvingPeriod,
                premiumPeriod
            );
    }

    /// @notice Apply duration-based discount percentage.
    /// @param value An arbitrary value.
    /// @param duration The duration, in seconds.
    /// @return `value` reduced by discount percentage.
    function applyDiscount(
        uint256 value,
        uint64 duration
    ) public view returns (uint256) {
        return
            value -
            Math.mulDiv(
                value,
                integratedDiscount(duration),
                uint256(type(uint128).max) * duration
            );
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

    /// @dev Replace the discount function points.
    function _setDiscountPoints(DiscountPoint[] memory points) internal {
        delete _discountPoints;
        for (uint256 i; i < points.length; ++i) {
            if (points[i].t == 0) {
                revert InvalidDiscountPoint();
            }
            _discountPoints.push(points[i]);
        }
        emit DiscountPointsUpdated(points);
    }

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
        address paymentToken
    ) internal view returns (Ratio memory ratio) {
        ratio = _paymentRatios[paymentToken];
        if (ratio.denom == 0) {
            revert PaymentTokenNotSupported(paymentToken);
        }
    }

    /// @dev Ensure `dur >= max`.
    function _requireMinimumDuration(uint64 dur, uint64 min) internal pure {
        if (dur < min) {
            revert DurationTooShort(dur, min);
        }
    }

    /// @dev Convert units to price.
    function _toAmount(
        uint256 units,
        Ratio memory ratio
    ) internal pure returns (uint256) {
        return
            ratio.numer == ratio.denom
                ? units
                : Math.mulDiv(
                    units,
                    ratio.numer,
                    ratio.denom,
                    Math.Rounding.Ceil
                );
    }
}
