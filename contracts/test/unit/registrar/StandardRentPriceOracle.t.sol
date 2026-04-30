// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {
    ERC1155Holder
} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {
    ERC165Checker
} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {StandardPricing} from "./StandardPricing.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {LibHalving} from "~src/registrar/libraries/LibHalving.sol";
import {
    StandardRentPriceOracle,
    PaymentRatio,
    IRentPriceOracle,
    DiscountPoint,
    Ownable,
    SafeERC20,
    IERC20,
    Math
} from "~src/registrar/StandardRentPriceOracle.sol";
import {
    StandardRentPriceOracleFixture,
    MockERC20,
    MockERC20Blacklist
} from "~test/fixtures/StandardRentPriceOracleFixture.sol";

contract StandardRentPriceOracleTest is
    StandardRentPriceOracleFixture,
    ERC1155Holder
{
    function setUp() external {
        deployStandardRentPriceOracleFixture();
    }

    function test_constructor_invalidRatio() external {
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio(address(tokenUSDC), 1, 0); // wrong
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidRatio.selector
            )
        );
        new StandardRentPriceOracle(
            address(this),
            address(0),
            0,
            new uint256[](0),
            new DiscountPoint[](0),
            0,
            0,
            0,
            paymentRatios
        );
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(rentPriceOracle),
                type(IRentPriceOracle).interfaceId
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Payment Tokens
    ////////////////////////////////////////////////////////////////////////

    function test_isPaymentToken() external view {
        for (uint256 i; i < paymentTokens.length; ++i) {
            assertTrue(
                rentPriceOracle.isPaymentToken(address(paymentTokens[i])),
                paymentTokens[i].name()
            );
        }
        assertFalse(rentPriceOracle.isPaymentToken(invalidPaymentToken));
    }

    function test_getPaymentTokenRatio() external view {
        (uint128 numer, uint128 denom) = rentPriceOracle.getPaymentTokenRatio(
            address(tokenUSDC)
        );
        PaymentRatio memory ratio = StandardPricing.ratioFromStable(tokenUSDC);
        assertEq(numer, ratio.numer, "numer");
        assertEq(denom, ratio.denom, "denom");
    }

    function test_getPaymentTokenRatio_unknown() external view {
        (uint128 numer, uint128 denom) = rentPriceOracle.getPaymentTokenRatio(
            invalidPaymentToken
        );
        assertEq(numer, 0, "numer");
        assertEq(denom, 0, "denom");
    }

    function test_updatePaymentToken_remove() external {
        address paymentToken = address(tokenUSDC);
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken));
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenRemoved(paymentToken);
        rentPriceOracle.updatePaymentToken(paymentToken, 0, 0);
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken));
    }

    function test_updatePaymentToken_add() external {
        address paymentToken = invalidPaymentToken;
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken));
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenAdded(paymentToken);
        rentPriceOracle.updatePaymentToken(paymentToken, 1, 1);
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken));
    }

    function test_updatePaymentToken_invalidRatio() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidRatio.selector
            )
        );
        rentPriceOracle.updatePaymentToken(address(tokenUSDC), 0, 1);
    }

    function test_updatePaymentToken_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                payer
            )
        );
        vm.prank(payer);
        rentPriceOracle.updatePaymentToken(address(tokenUSDC), 0, 0); // remove
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                payer
            )
        );
        vm.prank(payer);
        rentPriceOracle.updatePaymentToken(address(tokenUSDC), 1, 1); // add
    }

    ////////////////////////////////////////////////////////////////////////
    // Validity
    ////////////////////////////////////////////////////////////////////////

    function test_getLength() external view {
        for (uint256 i; i < 1000; i++) {
            assertEq(rentPriceOracle.getLength(new string(i)), i);
        }
        assertEq(rentPriceOracle.getLength(unicode"⌚"), 1);
        assertEq(rentPriceOracle.getLength(unicode"🇺🇸"), 2);
        assertEq(rentPriceOracle.getLength(unicode"🍄‍🟫"), 3);
        assertEq(rentPriceOracle.getLength(unicode"👨🏻‍🌾"), 4);
        assertEq(rentPriceOracle.getLength(unicode"🧑‍🤝‍🧑"), 5);
        assertEq(rentPriceOracle.getLength(unicode"👨🏻‍🦯‍➡"), 6);
        assertEq(rentPriceOracle.getLength(unicode"🏴󠁧󠁢󠁥󠁮󠁧󠁿"), 7);
        assertEq(rentPriceOracle.getLength(unicode"👨🏻‍💻👩🏻‍💻"), 8);
        assertEq(rentPriceOracle.getLength(unicode"👨🏻‍❤‍💋‍👨🏻"), 9);
    }

    function test_isValid() external view {
        assertFalse(rentPriceOracle.isValid(""));
        assertEq(rentPriceOracle.isValid("a"), StandardPricing.RATE_1CP > 0);
        assertEq(rentPriceOracle.isValid("ab"), StandardPricing.RATE_2CP > 0);
        assertEq(rentPriceOracle.isValid("abc"), StandardPricing.RATE_3CP > 0);
        assertEq(rentPriceOracle.isValid("abce"), StandardPricing.RATE_4CP > 0);
        assertEq(
            rentPriceOracle.isValid("abcde"),
            StandardPricing.RATE_5CP > 0
        );
        assertEq(
            rentPriceOracle.isValid(new string(255)),
            StandardPricing.RATE_5CP > 0
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Base Rate
    ////////////////////////////////////////////////////////////////////////

    function _getRegisterPrice(
        uint256 n,
        uint256 rate,
        uint64 available,
        uint64 duration
    ) internal {
        string memory label = new string(n);
        assertEq(rentPriceOracle.getBasePrice(label, 1), rate, "rate");
        for (uint256 i; i < paymentTokens.length; ++i) {
            bool ok;
            if (duration < rentPriceOracle.minRegisterDuration()) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IRentPriceOracle.DurationTooShort.selector,
                        duration,
                        rentPriceOracle.minRegisterDuration()
                    )
                );
            } else if (rate == 0) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IRentPriceOracle.NotValid.selector,
                        label
                    )
                );
            } else {
                ok = true;
            }
            address paymentToken = address(paymentTokens[i]);
            (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
                label,
                available,
                duration,
                paymentToken
            );
            if (ok) {
                (uint128 numer, uint128 denom) = rentPriceOracle
                    .getPaymentTokenRatio(paymentToken);
                assertEq(
                    base + premium,
                    Math.mulDiv(
                        rentPriceOracle.getBasePrice(label, duration) +
                            rentPriceOracle.getPremiumPriceAfter(available),
                        numer,
                        denom,
                        Math.Rounding.Ceil
                    )
                );
            }
        }
    }

    function test_getRegisterPrice_0(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(0, 0, available, duration);
    }
    function test_getRegisterPrice_1(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(1, StandardPricing.RATE_1CP, available, duration);
    }
    function test_getRegisterPrice_2(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(2, StandardPricing.RATE_2CP, available, duration);
    }
    function test_getRegisterPrice_3(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(3, StandardPricing.RATE_3CP, available, duration);
    }
    function test_getRegisterPrice_4(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(4, StandardPricing.RATE_4CP, available, duration);
    }
    function test_getRegisterPrice_5(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(5, StandardPricing.RATE_5CP, available, duration);
    }
    function test_getRegisterPrice_255(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(255, StandardPricing.RATE_5CP, available, duration);
    }
    function test_getRegisterPrice_256(
        uint32 available,
        uint32 duration
    ) external {
        _getRegisterPrice(256, 0, available, duration);
    }

    function test_getRegisterPrice_paymentTokenNotSupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.getRegisterPrice(
            "abcde",
            0,
            StandardPricing.MIN_REGISTER_DURATION,
            invalidPaymentToken
        );
    }

    function test_getRenewPrice_paymentTokenNotSupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.getRenewPrice(
            "abcde",
            0,
            StandardPricing.MIN_REGISTER_DURATION,
            invalidPaymentToken
        );
    }

    function test_updateBaseRates() external {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 1;
        rates[1] = 0;
        vm.expectEmit(false, false, false, true);
        emit StandardRentPriceOracle.BaseRatesUpdated(rates);
        rentPriceOracle.updateBaseRates(rates);
        assertEq(abi.encode(rentPriceOracle.getBaseRates()), abi.encode(rates));
    }

    function test_updateBaseRates_disable() external {
        rentPriceOracle.updateBaseRates(new uint256[](0));
        for (uint256 i; i < 256; i++) {
            assertEq(rentPriceOracle.getBasePrice(new string(i), 1), 0);
        }
    }

    function test_updateBaseRates_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                payer
            )
        );
        vm.prank(payer);
        rentPriceOracle.updateBaseRates(new uint256[](1));
    }

    function test_getBaseRates() external view {
        assertEq(
            abi.encode(rentPriceOracle.getBaseRates()),
            abi.encode(StandardPricing.getBaseRates())
        );
    }

    function _testAverageDiscount(uint64 t, uint256 average) internal view {
        uint256 value = (rentPriceOracle.integratedDiscount(t) + t - 1) / t;
        uint256 diff = value > average ? value - average : average - value;
        assert(diff <= 1);
    }

    // these tests are fragile and specific to the chosen discount points
    function test_discountAfter_start() external view {
        assertEq(rentPriceOracle.integratedDiscount(0), 0);
    }
    function test_discountAfter_1year() external view {
        _testAverageDiscount(StandardPricing.SEC_PER_YEAR, 0);
    }
    function test_discountAfter_1year_4mos_partial() external view {
        _testAverageDiscount(
            (StandardPricing.SEC_PER_YEAR * 4) / 3,
            StandardPricing.discountRatio(25, 1000)
        );
    }
    function test_discountAfter_2years() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 2,
            StandardPricing.discountRatio(5, 100)
        );
    }
    function test_discountAfter_2years_6mos_partial() external view {
        _testAverageDiscount(
            (StandardPricing.SEC_PER_YEAR * 5) / 2,
            StandardPricing.discountRatio(8, 100)
        );
    }
    function test_discountAfter_3years() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 3,
            StandardPricing.discountRatio(10, 100)
        );
    }
    function test_discountAfter_4years_partial() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 4,
            StandardPricing.discountRatio(146875, 1000000)
        );
    }
    function test_discountAfter_5years() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 5,
            StandardPricing.discountRatio(175, 1000)
        );
    }
    function test_discountAfter_8years_partial() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 8,
            StandardPricing.discountRatio(23125, 100000)
        );
    }
    function test_discountAfter_10years() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 10,
            StandardPricing.discountRatio(25, 100)
        );
    }
    function test_discountAfter_30years() external view {
        _testAverageDiscount(
            StandardPricing.SEC_PER_YEAR * 30,
            StandardPricing.discountRatio(30, 100)
        );
    }
    function test_discountAfter_end() external view {
        _testAverageDiscount(
            type(uint64).max,
            StandardPricing.discountRatio(30, 100)
        );
    }

    // function _testDiscountedRentPrice(string memory label, uint64 dur0, uint64 dur1) internal {
    //     ethRegistry.register(
    //         label,
    //         address(this),
    //         IRegistry(address(0)),
    //         address(0),
    //         0,
    //         uint64(block.timestamp) + dur0
    //     );
    //     uint256 base0 = rentPriceOracle.getBaseRate(label) * dur1;
    //     (uint256 base1, ) = rentPriceOracle.rentPrice(label, address(this), dur1, tokenIdentity);
    //     assertEq(
    //         base1,
    //         base0 -
    //             Math.mulDiv(
    //                 base0,
    //                 rentPriceOracle.integratedDiscount(dur0 + dur1) -
    //                     rentPriceOracle.integratedDiscount(dur0),
    //                 uint256(type(uint128).max) * dur1
    //             )
    //     );
    // }

    // function _testDiscountedPermutations(uint256 n) internal {
    //     bytes memory buf = new bytes(n);
    //     for (uint64 i = 1; i < 3; i++) {
    //         buf[0] = bytes1(uint8(i));
    //         for (uint64 j = 1; j < 10; j++) {
    //             buf[1] = bytes1(uint8(j));
    //             _testDiscountedRentPrice(
    //                 string(buf),
    //                 StandardPricing.SEC_PER_YEAR * i,
    //                 StandardPricing.SEC_PER_YEAR * j
    //             );
    //         }
    //     }
    // }

    // function test_discountedRentPrice_3() external {
    //     _testDiscountedPermutations(3);
    // }
    // function test_discountedRentPrice_4() external {
    //     _testDiscountedPermutations(4);
    // }
    // function test_discountedRentPrice_5() external {
    //     _testDiscountedPermutations(5);
    // }

    ////////////////////////////////////////////////////////////////////////
    // updateDiscountPoints()
    ////////////////////////////////////////////////////////////////////////

    function test_updateDiscountPoints() external {
        DiscountPoint[] memory points = new DiscountPoint[](2);
        points[0] = DiscountPoint(100, 4);
        points[1] = DiscountPoint(200, 1);
        vm.expectEmit(false, false, false, true);
        emit StandardRentPriceOracle.DiscountPointsUpdated(points);
        rentPriceOracle.updateDiscountPoints(points);
        assertEq(
            abi.encode(rentPriceOracle.getDiscountPoints()),
            abi.encode(points)
        );
        assertEq(rentPriceOracle.integratedDiscount(50), 200); // 50*4
        assertEq(rentPriceOracle.integratedDiscount(500), 1000); // 100*4 + 200*1 + (500-300)*(100*4+200*1)/300
    }

    function test_updateDiscountPoints_disable() external {
        rentPriceOracle.updateDiscountPoints(new DiscountPoint[](0));
        assertEq(rentPriceOracle.integratedDiscount(type(uint64).max), 0);
    }

    function test_updateDiscountPoints_invalidDiscountPoint() external {
        DiscountPoint[] memory points = new DiscountPoint[](1);
        points[0] = DiscountPoint(0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidDiscountPoint.selector
            )
        );
        rentPriceOracle.updateDiscountPoints(points);
    }

    function test_updateDiscountPoints_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                payer
            )
        );
        vm.prank(payer);
        rentPriceOracle.updateDiscountPoints(new DiscountPoint[](0));
    }

    function test_getDiscountPoints() external view {
        assertEq(
            abi.encode(rentPriceOracle.getDiscountPoints()),
            abi.encode(StandardPricing.getDiscountPoints())
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Premium
    ////////////////////////////////////////////////////////////////////////

    function test_constructor_premium() external view {
        assertEq(
            rentPriceOracle.premiumPriceInitial(),
            StandardPricing.PREMIUM_PRICE_INITIAL,
            "PREMIUM_PRICE_INITIAL"
        );
        assertEq(
            rentPriceOracle.premiumHalvingPeriod(),
            StandardPricing.PREMIUM_HALVING_PERIOD,
            "PREMIUM_HALVING_PERIOD"
        );
        assertEq(
            rentPriceOracle.premiumPeriod(),
            StandardPricing.PREMIUM_PERIOD,
            "PREMIUM_PERIOD"
        );
    }

    function test_getPremiumPriceAfter_start() external view {
        assertEq(
            rentPriceOracle.getPremiumPriceAfter(0),
            StandardPricing.PREMIUM_PRICE_INITIAL -
                LibHalving.halving(
                    StandardPricing.PREMIUM_PRICE_INITIAL,
                    StandardPricing.PREMIUM_HALVING_PERIOD,
                    StandardPricing.PREMIUM_PERIOD
                )
        );
    }

    function test_getPremiumPriceAfter_end() external view {
        uint64 dur = rentPriceOracle.premiumPeriod();
        uint64 dt = 1;
        assertGt(rentPriceOracle.getPremiumPriceAfter(dur - dt), 0, "before");
        assertEq(rentPriceOracle.getPremiumPriceAfter(dur), 0, "at");
        assertEq(rentPriceOracle.getPremiumPriceAfter(dur + dt), 0, "after");
    }

    function test_updatePremiumPricing() external {
        vm.expectEmit();
        emit StandardRentPriceOracle.PremiumPricingUpdated(256000, 1, 8);
        rentPriceOracle.updatePremiumPricing(256000, 1, 8);
        assertEq(rentPriceOracle.getPremiumPriceAfter(0), 255000, "0");
        assertEq(rentPriceOracle.getPremiumPriceAfter(1), 127000, "1");
        assertEq(rentPriceOracle.getPremiumPriceAfter(2), 63000, "2");
        assertEq(rentPriceOracle.getPremiumPriceAfter(3), 31000, "3");
        assertEq(rentPriceOracle.getPremiumPriceAfter(4), 15000, "4");
        assertEq(rentPriceOracle.getPremiumPriceAfter(5), 7000, "5");
        assertEq(rentPriceOracle.getPremiumPriceAfter(6), 3000, "6");
        assertEq(rentPriceOracle.getPremiumPriceAfter(7), 1000, "7");
        assertEq(rentPriceOracle.getPremiumPriceAfter(8), 0, "8");
    }

    function test_updatePremiumPricing_disable() external {
        rentPriceOracle.updatePremiumPricing(0, 0, 0);
        assertEq(rentPriceOracle.getPremiumPriceAfter(0), 0, "after");
        assertEq(rentPriceOracle.premiumPriceInitial(), 0, "initial");
    }

    function test_updatePremiumPricing_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                payer
            )
        );
        vm.prank(payer);
        rentPriceOracle.updatePremiumPricing(0, 0, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // SafeERC20
    ////////////////////////////////////////////////////////////////////////

    function test_voidReturn_acceptedBySafeERC20() public {
        rentPriceOracle.pay(payer, address(tokenVoid), 1);
    }

    function test_falseReturn_rejectedBySafeERC20() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeERC20.SafeERC20FailedOperation.selector,
                tokenFalse
            )
        );
        rentPriceOracle.pay(payer, address(tokenFalse), 1);
    }

    function test_blacklisted_payer() external {
        tokenBlack.setBlacklisted(payer, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC20Blacklist.Blacklisted.selector,
                payer
            )
        );
        rentPriceOracle.pay(payer, address(tokenBlack), 1);
    }

    function test_blacklisted_beneficiary() external {
        tokenBlack.setBlacklisted(beneficiary, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC20Blacklist.Blacklisted.selector,
                beneficiary
            )
        );
        rentPriceOracle.pay(payer, address(tokenBlack), 1);
    }
}
