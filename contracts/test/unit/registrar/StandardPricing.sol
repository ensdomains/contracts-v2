// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {PaymentRatio, DiscountPoint} from "~src/registrar/StandardRentPriceOracle.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";

// *** Changes MUST be synced with `deploy/StandardRentPriceOracle.ts` ***
//
// https://discuss.ens.domains/t/temp-check-ens-v2-pricing-5-character-name-price-adjustment-multi-year-discounts/22038
//
// Term  | Discount | 5-char $/yr | 5-char Total | 4-char $/yr | 4-char Total | 3-char $/yr | 3-char Total
// ------|----------|-------------|--------------|-------------|--------------|-------------|-------------
// 1 yr  | 0%       | $8.00       | $8.00        | $160        | $160         | $640        | $640
// 2 yr  | 12.5%    | $7.00       | $14.00       | $140        | $280         | $560        | $1,120
// 3 yr  | ~31%     | $5.50       | $16.50       | $110        | $330         | $440        | $1,320
// 4 yr  | ~31%     | $5.50       | $22.00       | $110        | $440         | $440        | $1,760
// 5 yr  | ~31%     | $5.50       | $27.50       | $110        | $550         | $440        | $2,200
// 6 yr  | ~44%     | $4.50       | $27.00       | $90         | $540         | $360        | $2,160
// 7 yr  | ~44%     | $4.50       | $31.50       | $90         | $630         | $360        | $2,520
// 8 yr  | ~44%     | $4.50       | $36.00       | $90         | $720         | $360        | $2,880
// 9 yr  | ~44%     | $4.50       | $40.50       | $90         | $810         | $360        | $3,240
// 10 yr | ~44%     | $4.50       | $45.00       | $90         | $900         | $360        | $3,600
//
// devnet output:
// ┌───┬────┬───────────┬────────┐
// │   │ cp │ rate      │ yearly │
// ├───┼────┼───────────┼────────┤
// │ 0 │ 3  │ 20280377n │ 640.00 │
// │ 1 │ 4  │ 5070095n  │ 160.00 │
// │ 2 │ 5  │ 253505n   │ 8.00   │
// └───┴────┴───────────┴────────┘
// ┌────┬───────┬──────────┐
// │    │ years │ discount │
// ├────┼───────┼──────────┤
// │  0 │ 1.00  │ 0.00%    │
// │  1 │ 2.00  │ 12.50%   │
// │  2 │ 3.00  │ 31.25%   │
// │  3 │ 4.00  │ 37.50%   │
// │  4 │ 5.00  │ 41.25%   │
// │  5 │ 6.00  │ 43.75%   │
// │  6 │ 7.00  │ 43.75%   │
// │  7 │ 8.00  │ 43.75%   │
// │  8 │ 9.00  │ 43.75%   │
// │  9 │ 10.00 │ 43.75%   │
// │ 10 │ max   │ 43.75%   │
// └────┴───────┴──────────┘
//
library StandardPricing {
    uint64 constant SEC_PER_YEAR = 31_557_600; // 365.25
    uint64 constant SEC_PER_DAY = 86400; // 1 days

    uint64 constant MIN_COMMITMENT_AGE = 1 minutes;
    uint64 constant MAX_COMMITMENT_AGE = 1 days;
    uint64 constant MIN_REGISTER_DURATION = 28 days;

    uint8 constant PRICE_DECIMALS = 12;

    uint256 constant PRICE_SCALE = 10 ** PRICE_DECIMALS;

    uint256 constant RATE_1CP = 0;
    uint256 constant RATE_2CP = 0;
    uint256 constant RATE_3CP = (640 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;
    uint256 constant RATE_4CP = (160 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;
    uint256 constant RATE_5CP = (8 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;

    uint256 constant PREMIUM_PRICE_INITIAL = 100_000_000 * PRICE_SCALE;
    uint64 constant PREMIUM_HALVING_PERIOD = SEC_PER_DAY;
    uint64 constant PREMIUM_PERIOD = 21 * SEC_PER_DAY;

    function getBaseRates() internal pure returns (uint256[] memory rates) {
        rates = new uint256[](5);
        rates[0] = RATE_1CP;
        rates[1] = RATE_2CP;
        rates[2] = RATE_3CP;
        rates[3] = RATE_4CP;
        rates[4] = RATE_5CP;
    }

    function discountRatio(uint256 numer, uint256 denom) internal pure returns (uint128) {
        require(numer < denom, "discountRatio");
        uint256 scale = uint256(type(uint128).max);
        return uint128((scale * numer + denom - 1) / denom);
    }

    function getDiscountPoints() internal pure returns (DiscountPoint[] memory points) {
        // see: src/registrar/StandardRentPriceOracle.updateDiscountFunction()
        //
        // breakpoints derived from discount table:
        // * 2yr @ 12.50% ==  1yr @  0.00% +  1yr @ x =>  +1yr @ x = 25.00%
        // * 3yr @ 31.25% ==  2yr @ 12.50% +  1yr @ x =>  +1yr @ x = 68.75%
        // * 6yr @ 43.75% ==  3yr @ 31.25% +  3yr @ x =>  +2yr @ x = 56.25%
        //
        points = new DiscountPoint[](4);
        points[0] = DiscountPoint(SEC_PER_YEAR, 0);
        points[1] = DiscountPoint(SEC_PER_YEAR, discountRatio(1, 4)); //      25.00%
        points[2] = DiscountPoint(SEC_PER_YEAR, discountRatio(11, 16)); //    68.75%
        points[3] = DiscountPoint(SEC_PER_YEAR * 3, discountRatio(9, 16)); // 56.25%
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
