// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {PaymentRatio, DiscountPoint} from "~src/registrar/StandardRentPriceOracle.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";

library StandardRegistrar {
    uint64 internal constant SEC_PER_YEAR = 31_557_600; // 365.25

    uint64 internal constant MIN_COMMITMENT_AGE = 60; // 1 minute
    uint64 internal constant MAX_COMMITMENT_AGE = 1 days;

    uint64 internal constant MIN_REGISTER_DURATION = 28 days;

    uint64 internal constant GRACE_PERIOD_V1 = 90 days;
    uint64 internal constant GRACE_PERIOD_V2 = 28 days;
    uint64 internal constant BONUS_PERIOD =
        1 + GRACE_PERIOD_V1 - GRACE_PERIOD_V2;

    uint8 internal constant PRICE_DECIMALS = 12;
    uint256 internal constant PRICE_SCALE = 10 ** PRICE_DECIMALS;

    uint256 internal constant PREMIUM_PRICE_INITIAL = 100_000_000 * PRICE_SCALE;
    uint64 internal constant PREMIUM_HALVING_PERIOD = 1 days;
    uint64 internal constant PREMIUM_PERIOD = 21 days;

    // ┌───┬────┬───────────┬────────┐
    // │   │ cp │ rate      │ yearly │
    // ├───┼────┼───────────┼────────┤
    // │ 0 │ 5  │ 253505n   │ 8.00   │
    // │ 1 │ 4  │ 5070095n  │ 160.00 │
    // │ 2 │ 3  │ 20280377n │ 640.00 │
    // └───┴────┴───────────┴────────┘

    uint256 internal constant RATE_1CP = 0;
    uint256 internal constant RATE_2CP = 0;
    uint256 internal constant RATE_3CP =
        (640 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR; // round up
    uint256 internal constant RATE_4CP =
        (160 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;
    uint256 internal constant RATE_5CP =
        (8 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;

    function getBaseRates() internal pure returns (uint256[] memory rates) {
        rates = new uint256[](5);
        rates[0] = RATE_1CP;
        rates[1] = RATE_2CP;
        rates[2] = RATE_3CP;
        rates[3] = RATE_4CP;
        rates[4] = RATE_5CP;
    }

    // ┌────┬─────────┬──────────┬────────┬────────┬────────┬─────────┬────────┬──────────┐
    // │    │ years   │ discount │ 5cp/yr │ 5cp    │ 4cp/yr │ 4cp     │ 3cp/yr │ 3cp      │
    // ├────┼─────────┼──────────┼────────┼────────┼────────┼─────────┼────────┼──────────┤
    // │  0 │ <1.00   │ 0.00%    │ 8.00   │ 8.00   │ 160.00 │ 160.00  │ 640.00 │ 640.00   │
    // │  1 │ <2.00   │ 0.00%    │ 8.00   │ 16.00  │ 160.00 │ 320.00  │ 640.00 │ 1280.00  │
    // │  2 │ <3.00   │ 12.50%   │ 7.00   │ 21.00  │ 140.00 │ 420.00  │ 560.00 │ 1680.00  │
    // │  3 │ <4.00   │ 31.25%   │ 5.50   │ 22.00  │ 110.00 │ 440.00  │ 440.00 │ 1760.00  │
    // │  4 │ <5.00   │ 31.25%   │ 5.50   │ 27.50  │ 110.00 │ 550.00  │ 440.00 │ 2200.00  │
    // │  5 │ <6.00   │ 31.25%   │ 5.50   │ 33.00  │ 110.00 │ 660.00  │ 440.00 │ 2640.00  │
    // │  6 │ <7.00   │ 43.75%   │ 4.50   │ 31.50  │ 90.00  │ 630.00  │ 360.00 │ 2520.00  │
    // │  7 │ <8.00   │ 43.75%   │ 4.50   │ 36.00  │ 90.00  │ 720.00  │ 360.00 │ 2880.00  │
    // │  8 │ <9.00   │ 43.75%   │ 4.50   │ 40.50  │ 90.00  │ 810.00  │ 360.00 │ 3240.00  │
    // │  9 │ <10.00  │ 43.75%   │ 4.50   │ 45.00  │ 90.00  │ 900.00  │ 360.00 │ 3600.00  │
    // │ 10 │ <25.00  │ 43.75%   │ 4.50   │ 112.50 │ 90.00  │ 2250.00 │ 360.00 │ 9000.00  │
    // │ 11 │ <100.00 │ 43.75%   │ 4.50   │ 450.00 │ 90.00  │ 9000.00 │ 360.00 │ 36000.00 │
    // └────┴─────────┴──────────┴────────┴────────┴────────┴─────────┴────────┴──────────┘

    function getDiscountPoints() internal pure returns (DiscountPoint[] memory v) {
        v = new DiscountPoint[](3);
        v[0] = DiscountPoint(SEC_PER_YEAR * 2, _discountNumer(7, 8)); //////// 1 - 14/16 = 12.50%
        v[1] = DiscountPoint(SEC_PER_YEAR * 3, _discountNumer(11, 16)); // 1 - 11/16 = 31.25%
        v[2] = DiscountPoint(SEC_PER_YEAR * 6, _discountNumer(9, 16)); /// 1 -  9/16 = 43.75%
    }

    uint128 internal constant DISCOUNT_DENOMINATOR = 1e38; // Floor[Log10[2^128-1] == 38

    function _discountNumer(uint256 numer, uint256 denom) private pure returns (uint128) {
        require(numer < denom, "discountNumer");
        return uint128((DISCOUNT_DENOMINATOR * numer + denom - 1) / denom); // round up
    }

    function ratioFromStable(MockERC20 token) internal view returns (PaymentRatio memory) {
        uint8 d = token.decimals();
        if (d > PRICE_DECIMALS) {
            return PaymentRatio(token, uint128(10) ** (d - PRICE_DECIMALS), 1);
        } else {
            return PaymentRatio(token, 1, uint128(10) ** (PRICE_DECIMALS - d));
        }
    }
}
