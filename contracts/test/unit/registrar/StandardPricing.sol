// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {PaymentRatio, DiscountPoint} from "~src/registrar/StandardRentPriceOracle.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";

library StandardPricing {
    uint64 constant SEC_PER_YEAR = 31_557_600; // 365.25
    uint64 constant SEC_PER_DAY = 86400; // 1 days

    uint64 constant MIN_COMMITMENT_AGE = 1 minutes;
    uint64 constant MAX_COMMITMENT_AGE = 1 days;
    uint64 constant MIN_REGISTER_DURATION = 28 days;
    uint64 constant MIN_RENEW_DURATION = 1;
    uint64 constant GRACE_PERIOD = 30 days;

    uint8 constant PRICE_DECIMALS = 12;

    uint256 constant PRICE_SCALE = 10 ** PRICE_DECIMALS;

    uint256 constant RATE_1CP = 0;
    uint256 constant RATE_2CP = 0;
    uint256 constant RATE_3CP = (640 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;
    uint256 constant RATE_4CP = (160 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;
    uint256 constant RATE_5CP = (5 * PRICE_SCALE + SEC_PER_YEAR - 1) / SEC_PER_YEAR;

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
        // see: StandardRentPriceOracle.updateDiscountFunction()
        // *  2yr @  5.00% ==  1yr @  0.00% +  1yr @ x =>  +1yr @ x = 10.00%
        // *  3yr @ 10.00% ==  2yr @  5.00% +  1yr @ x =>  +1yr @ x = 20.00%
        // *  5yr @ 17.50% ==  3yr @ 10.00% +  2yr @ x =>  +2yr @ x = 28.75%
        // * 10yr @ 25.00% ==  5yr @ 17.50% +  5yr @ x =>  +5yr @ x = 32.50%
        // * 25yr @ 30.00% == 10yr @ 25.00% + 15yr @ x => +15yr @ x = 33.33%
        points = new DiscountPoint[](6);
        points[0] = DiscountPoint(SEC_PER_YEAR, 0);
        points[1] = DiscountPoint(SEC_PER_YEAR, discountRatio(1, 10)); // 10%
        points[2] = DiscountPoint(SEC_PER_YEAR, discountRatio(2, 10));
        points[3] = DiscountPoint(SEC_PER_YEAR * 2, discountRatio(2875, 10000));
        points[4] = DiscountPoint(SEC_PER_YEAR * 5, discountRatio(325, 1000));
        points[5] = DiscountPoint(SEC_PER_YEAR * 15, discountRatio(1, 3)); // 33.3%
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
