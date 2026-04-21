// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StandardPricing} from "./StandardPricing.sol";

import {LibHalving} from "~src/registrar/libraries/LibHalving.sol";
import {
    StandardRentPriceOracle,
    PaymentRatio,
    IRentPriceOracle,
    IPaymentTokenOracle,
    DiscountPoint
} from "~src/registrar/StandardRentPriceOracle.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract StandardRentPriceOracleTest is Test, ERC1155Holder {
    MockHCAFactoryBasic hcaFactory;

    StandardRentPriceOracle rentPriceOracle;

    MockERC20 tokenUSDC;
    MockERC20 tokenIdentity;

    address user = makeAddr("user");

    function setUp() external {
        hcaFactory = new MockHCAFactoryBasic();

        tokenUSDC = new MockERC20("USDC", 6);
        tokenIdentity = new MockERC20("ID", StandardPricing.PRICE_DECIMALS);

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](2);
        paymentRatios[0] = StandardPricing.ratioFromStable(tokenUSDC);
        paymentRatios[1] = StandardPricing.ratioFromStable(tokenIdentity);

        rentPriceOracle = new StandardRentPriceOracle(
            address(this),
            StandardPricing.getBaseRates(),
            StandardPricing.getDiscountPoints(),
            StandardPricing.PREMIUM_PRICE_INITIAL,
            StandardPricing.PREMIUM_HALVING_PERIOD,
            StandardPricing.PREMIUM_PERIOD,
            paymentRatios
        );

        vm.warp(rentPriceOracle.premiumPeriod()); // avoid timestamp issues
    }

    function test_constructor_invalidRatio() external {
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio(tokenUSDC, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidRatio.selector));
        new StandardRentPriceOracle(
            address(this),
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
            ),
            "IRentPriceOracle"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(rentPriceOracle),
                type(IPaymentTokenOracle).interfaceId
            ),
            "IPaymentTokenOracle"
        );
    }

    function test_isPaymentToken() external view {
        assertTrue(rentPriceOracle.isPaymentToken(tokenUSDC), "USDC");
        assertTrue(rentPriceOracle.isPaymentToken(tokenIdentity), "ID");
        assertFalse(rentPriceOracle.isPaymentToken(IERC20(address(0))));
    }

    function test_updatePaymentToken_remove() external {
        IERC20 paymentToken = tokenUSDC;
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken), "before");
        vm.expectEmit(true, false, false, false);
        emit IPaymentTokenOracle.PaymentTokenRemoved(paymentToken);
        rentPriceOracle.updatePaymentToken(paymentToken, 0, 0);
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken), "after");
    }

    function test_updatePaymentToken_add() external {
        IERC20 paymentToken = IERC20(address(1));
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken), "before");
        vm.expectEmit(true, false, false, false);
        emit IPaymentTokenOracle.PaymentTokenAdded(paymentToken);
        rentPriceOracle.updatePaymentToken(paymentToken, 1, 1);
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken), "after");
    }

    function test_updatePaymentToken_invalidRatio() external {
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidRatio.selector));
        rentPriceOracle.updatePaymentToken(tokenUSDC, 0, 1);
    }

    function test_updatePaymentToken_notOwner() external {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        rentPriceOracle.updatePaymentToken(tokenUSDC, 0, 0); // remove
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        rentPriceOracle.updatePaymentToken(tokenUSDC, 1, 1); // add
        vm.stopPrank();
    }

    // function test_isValid() external view {
    //     assertFalse(rentPriceOracle.isValid(""));
    //     assertEq(rentPriceOracle.isValid("a"), StandardPricing.RATE_1CP > 0);
    //     assertEq(rentPriceOracle.isValid("ab"), StandardPricing.RATE_2CP > 0);
    //     assertEq(rentPriceOracle.isValid("abc"), StandardPricing.RATE_3CP > 0);
    //     assertEq(rentPriceOracle.isValid("abce"), StandardPricing.RATE_4CP > 0);
    //     assertEq(rentPriceOracle.isValid("abcde"), StandardPricing.RATE_5CP > 0);
    //     assertEq(
    //         rentPriceOracle.isValid("abcdefghijklmnopqrstuvwxyz"),
    //         StandardPricing.RATE_5CP > 0
    //     );
    // }

    function _testRegisterPrice(uint256 n, uint256 rate) internal view {
        string memory label = new string(n);
        uint256 base = rentPriceOracle.baseRate(label);
        assertEq(base, rate, "rate");
        _testRegisterPrice(label, rate, tokenUSDC);
        _testRegisterPrice(label, rate, tokenIdentity);
    }

    function _testRegisterPrice(string memory label, uint256 rate, MockERC20 token) internal view {
        uint64 dur = StandardPricing.SEC_PER_YEAR; // must be before initial discount or price will be reduced
        while (dur > 0) {
            (uint256 base, ) = rentPriceOracle.registerPrice(label, type(uint64).max, dur, token);
            PaymentRatio memory r = StandardPricing.ratioFromStable(token);
            assertEq(base, Math.mulDiv(rate * dur, r.numer, r.denom, Math.Rounding.Ceil));
            dur >>= 1;
        }
    }

    function test_registerPrice0() external view {
        _testRegisterPrice(0, 0);
    }
    function test_registerPrice1() external view {
        _testRegisterPrice(1, StandardPricing.RATE_1CP);
    }
    function test_registerPrice2() external view {
        _testRegisterPrice(2, StandardPricing.RATE_2CP);
    }
    function test_registerPrice3() external view {
        _testRegisterPrice(3, StandardPricing.RATE_3CP);
    }
    function test_registerPrice4() external view {
        _testRegisterPrice(4, StandardPricing.RATE_4CP);
    }
    function test_registerPrice5() external view {
        _testRegisterPrice(5, StandardPricing.RATE_5CP);
    }
    function test_registerPrice255() external view {
        _testRegisterPrice(255, StandardPricing.RATE_5CP);
    }
    function test_registerPrice256() external view {
        _testRegisterPrice(256, 0);
    }

    function test_registerPrice_unitToken() external view {
        (uint256 base, ) = rentPriceOracle.registerPrice("abcde", 0, 1, IERC20(address(0)));
        assertEq(base, StandardPricing.RATE_5CP);
    }

    function test_registerPrice_unknownToken() external {
        (uint256 base, ) = rentPriceOracle.registerPrice("abcde", 0, 1, IERC20(makeAddr("dne")));
        assertEq(base, 0);
    }

    function test_premiumPriceInitial() external view {
        assertEq(rentPriceOracle.premiumPriceInitial(), StandardPricing.PREMIUM_PRICE_INITIAL);
    }

    function test_premiumPriceAfter_start() external view {
        assertEq(
            rentPriceOracle.premiumPriceAfter(0),
            StandardPricing.PREMIUM_PRICE_INITIAL -
                LibHalving.halving(
                    StandardPricing.PREMIUM_PRICE_INITIAL,
                    StandardPricing.PREMIUM_HALVING_PERIOD,
                    StandardPricing.PREMIUM_PERIOD
                )
        );
    }

    function test_premiumPriceAfter_end() external view {
        uint64 dur = rentPriceOracle.premiumPeriod();
        uint64 dt = 1;
        assertGt(rentPriceOracle.premiumPriceAfter(dur - dt), 0, "before");
        assertEq(rentPriceOracle.premiumPriceAfter(dur), 0, "at");
        assertEq(rentPriceOracle.premiumPriceAfter(dur + dt), 0, "after");
    }

    function test_updateBaseRates() external {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 1;
        rates[1] = 0;
        vm.expectEmit(false, false, false, true);
        emit StandardRentPriceOracle.BaseRatesChanged(rates);
        rentPriceOracle.updateBaseRates(rates);
        assertEq(abi.encode(rentPriceOracle.getBaseRates()), abi.encode(rates));
    }

    function test_updateBaseRates_disable() external {
        rentPriceOracle.updateBaseRates(new uint256[](0));
        for (uint256 i; i < 256; ++i) {
            assertEq(rentPriceOracle.baseRate(new string(i)), 0);
        }
    }

    function test_updateBaseRates_notOwner() external {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        rentPriceOracle.updateBaseRates(new uint256[](1));
        vm.stopPrank();
    }

    function test_getBaseRates() external view {
        assertEq(
            abi.encode(rentPriceOracle.getBaseRates()),
            abi.encode(StandardPricing.getBaseRates())
        );
    }

    function test_updatePremiumPricing() external {
        vm.expectEmit(false, false, false, false);
        emit StandardRentPriceOracle.PremiumPricingChanged(256000, 1, 8);
        rentPriceOracle.updatePremiumPricing(256000, 1, 8);
        assertEq(rentPriceOracle.premiumPriceAfter(0), 255000, "0");
        assertEq(rentPriceOracle.premiumPriceAfter(1), 127000, "1");
        assertEq(rentPriceOracle.premiumPriceAfter(2), 63000, "2");
        assertEq(rentPriceOracle.premiumPriceAfter(3), 31000, "3");
        assertEq(rentPriceOracle.premiumPriceAfter(4), 15000, "4");
        assertEq(rentPriceOracle.premiumPriceAfter(5), 7000, "5");
        assertEq(rentPriceOracle.premiumPriceAfter(6), 3000, "6");
        assertEq(rentPriceOracle.premiumPriceAfter(7), 1000, "7");
        assertEq(rentPriceOracle.premiumPriceAfter(8), 0, "8");
    }

    function test_updatePremiumPricing_disable() external {
        rentPriceOracle.updatePremiumPricing(0, 0, 0);
        assertEq(rentPriceOracle.premiumPriceAfter(0), 0, "after");
        assertEq(rentPriceOracle.premiumPriceInitial(), 0, "initial");
    }

    function test_updatePremiumPricing_notOwner() external {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        rentPriceOracle.updatePremiumPricing(0, 0, 0);
        vm.stopPrank();
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
        _testAverageDiscount(type(uint64).max, StandardPricing.discountRatio(30, 100));
    }

    function _testDiscountedRentPrice(string memory label, uint64 dur0, uint64 dur1) internal view {
        uint256 base0 = rentPriceOracle.baseRate(label) * dur1;
        uint256 base1 = rentPriceOracle.renewPrice(
            label,
            dur0, // current expiry
            0, // base extension
            dur1, // extension
            tokenIdentity
        );
        assertEq(
            base1,
            base0 -
                Math.mulDiv(
                    base0,
                    rentPriceOracle.integratedDiscount(dur0 + dur1) -
                        rentPriceOracle.integratedDiscount(dur0),
                    uint256(type(uint128).max) * dur1
                )
        );
    }

    function _testDiscountedPermutations(uint256 n) internal view {
        string memory label = new string(n);
        for (uint64 i = 1; i < 3; ++i) {
            for (uint64 j = 1; j < 10; ++j) {
                _testDiscountedRentPrice(
                    label,
                    StandardPricing.SEC_PER_YEAR * i,
                    StandardPricing.SEC_PER_YEAR * j
                );
            }
        }
    }

    function test_discountedRentPrice_3() external view {
        _testDiscountedPermutations(3);
    }
    function test_discountedRentPrice_4() external view {
        _testDiscountedPermutations(4);
    }
    function test_discountedRentPrice_5() external view {
        _testDiscountedPermutations(5);
    }

    function test_updateDiscountPoints() external {
        DiscountPoint[] memory points = new DiscountPoint[](2);
        points[0] = DiscountPoint(100, 4);
        points[1] = DiscountPoint(200, 1);
        vm.expectEmit(false, false, false, true);
        emit StandardRentPriceOracle.DiscountPointsChanged(points);
        rentPriceOracle.updateDiscountPoints(points);
        assertEq(abi.encode(rentPriceOracle.getDiscountPoints()), abi.encode(points));
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
            abi.encodeWithSelector(StandardRentPriceOracle.InvalidDiscountPoint.selector)
        );
        rentPriceOracle.updateDiscountPoints(points);
    }

    function test_updateDiscountPoints_notOwner() external {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        rentPriceOracle.updateDiscountPoints(new DiscountPoint[](0));
        vm.stopPrank();
    }

    function test_getDiscountPoints() external view {
        assertEq(
            abi.encode(rentPriceOracle.getDiscountPoints()),
            abi.encode(StandardPricing.getDiscountPoints())
        );
    }
}
