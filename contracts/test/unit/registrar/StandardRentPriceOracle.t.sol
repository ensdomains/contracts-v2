// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test, console} from "forge-std/Test.sol";

import {
    ERC1155Holder
} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {
    ERC165Checker
} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {
    IEnhancedAccessControl
} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {LibHalving} from "~src/registrar/libraries/LibHalving.sol";
import {
    StandardRentPriceOracle,
    IRentPriceOracle,
    IERC20,
    Math,
    PaymentRatio,
    DiscountPoint,
    DEFAULT_ROLE_BITMAP,
    ROLE_UPDATE_TOKEN,
    ROLE_DISABLE_TOKEN
} from "~src/registrar/StandardRentPriceOracle.sol";
import {
    StandardRentPriceOracleFixture,
    StandardRegistrar,
    MockERC20,
    MockERC20Blacklist
} from "~test/fixtures/StandardRentPriceOracleFixture.sol";

/// @dev The expiry parameter of `getRenewPrice()` is currently unused.
uint64 constant UNUSED_EXPIRY = 0;

contract StandardRentPriceOracleTest is
    StandardRentPriceOracleFixture,
    ERC1155Holder
{
    address actor = makeAddr("actor");

    function setUp() external {
        deployStandardRentPriceOracleFixture();
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(rentPriceOracle),
                type(IRentPriceOracle).interfaceId
            )
        );
    }

    function test_constructor() external view {
        assertTrue(
            rentPriceOracle.hasRootRoles(DEFAULT_ROLE_BITMAP, address(this)),
            "roles"
        );
        assertEq(
            abi.encode(rentPriceOracle.getBaseRates()),
            abi.encode(StandardRegistrar.getBaseRates())
        );
        assertEq(
            abi.encode(rentPriceOracle.getDiscountPoints()),
            abi.encode(StandardRegistrar.getDiscountPoints())
        );
        assertEq(
            rentPriceOracle.DISCOUNT_DENOMINATOR(),
            StandardRegistrar.DISCOUNT_DENOMINATOR,
            "DISCOUNT_DENOMINATOR"
        );
        assertEq(
            rentPriceOracle.PREMIUM_PRICE_INITIAL(),
            StandardRegistrar.PREMIUM_PRICE_INITIAL,
            "PREMIUM_PRICE_INITIAL"
        );
        assertEq(
            rentPriceOracle.PREMIUM_HALVING_PERIOD(),
            StandardRegistrar.PREMIUM_HALVING_PERIOD,
            "PREMIUM_HALVING_PERIOD"
        );
        assertEq(
            rentPriceOracle.PREMIUM_PERIOD(),
            StandardRegistrar.PREMIUM_PERIOD,
            "PREMIUM_PERIOD"
        );
        for (uint256 i; i < paymentTokens.length; ++i) {
            assertTrue(
                rentPriceOracle.isPaymentToken(paymentTokens[i]),
                paymentTokens[i].name()
            );
        }
    }

    function test_constructor_emitPaymentTokenUpdated() external {
        PaymentRatio[] memory v = new PaymentRatio[](1);
        v[0] = PaymentRatio(tokenUSDC, 1, 1);
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(tokenUSDC, 1, 1);
        new StandardRentPriceOracle(
            address(this),
            new uint256[](0),
            new DiscountPoint[](0),
            0,
            0,
            0,
            0,
            v
        );
    }

    function test_constructor_invalidDiscount_notIncreasingDurations()
        external
    {
        DiscountPoint[] memory v = new DiscountPoint[](2);
        v[0] = DiscountPoint(1, 2);
        v[1] = DiscountPoint(v[0].duration, 1); // wrong
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidDiscount.selector
            )
        );
        new StandardRentPriceOracle(
            address(this),
            new uint256[](0),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentRatio[](0)
        );
    }

    function test_constructor_invalidDiscount_notDecreasingNumerators()
        external
    {
        DiscountPoint[] memory v = new DiscountPoint[](2);
        v[0] = DiscountPoint(1, 1);
        v[1] = DiscountPoint(2, v[0].numerator); // wrong
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidDiscount.selector
            )
        );
        new StandardRentPriceOracle(
            address(this),
            new uint256[](0),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentRatio[](0)
        );
    }

    function test_constructor_invalidDiscount_aboveDenominator() external {
        DiscountPoint[] memory v = new DiscountPoint[](1);
        v[0] = DiscountPoint(1, 3); // wrong
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidDiscount.selector
            )
        );
        new StandardRentPriceOracle(
            address(this),
            new uint256[](0),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentRatio[](0)
        );
    }

    function test_constructor_invalidRatio() external {
        PaymentRatio[] memory v = new PaymentRatio[](1);
        v[0] = PaymentRatio(tokenUSDC, 1, 0); // wrong
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidRatio.selector
            )
        );
        new StandardRentPriceOracle(
            address(this),
            new uint256[](0),
            new DiscountPoint[](0),
            0,
            0,
            0,
            0,
            v
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Payment Tokens
    ////////////////////////////////////////////////////////////////////////

    function test_isPaymentToken_unknown() external view {
        assertFalse(rentPriceOracle.isPaymentToken(invalidPaymentToken));
    }

    function test_getPaymentTokenRatio_exists() external view {
        (uint128 numer, uint128 denom) = rentPriceOracle.getPaymentTokenRatio(
            tokenUSDC
        );
        PaymentRatio memory pr = StandardRegistrar.ratioFromStable(tokenUSDC);
        assertEq(numer, pr.numer, "numer");
        assertEq(denom, pr.denom, "denom");
    }

    function test_getPaymentTokenRatio_unknown() external view {
        (uint128 numer, uint128 denom) = rentPriceOracle.getPaymentTokenRatio(
            invalidPaymentToken
        );
        assertEq(numer, 0, "numer");
        assertEq(denom, 0, "denom");
    }

    function test_updatePaymentToken_add() external {
        assertFalse(rentPriceOracle.isPaymentToken(invalidPaymentToken));
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(
            invalidPaymentToken,
            1,
            1
        );
        rentPriceOracle.updatePaymentToken(invalidPaymentToken, 1, 1);
        assertTrue(rentPriceOracle.isPaymentToken(invalidPaymentToken));
    }

    function test_updatePaymentToken_remove() external {
        IERC20 paymentToken = randomPaymentToken();
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken));
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(paymentToken, 0, 0);
        rentPriceOracle.updatePaymentToken(paymentToken, 0, 0);
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken));
    }

    function test_updatePaymentToken_noChange() external {
        rentPriceOracle.updatePaymentToken(invalidPaymentToken, 1, 1);
        vm.expectRevert();
        rentPriceOracle.updatePaymentToken(invalidPaymentToken, 1, 1); // wrong
    }

    function test_updatePaymentToken_invalidRatio() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                StandardRentPriceOracle.InvalidRatio.selector
            )
        );
        rentPriceOracle.updatePaymentToken(randomPaymentToken(), 0, 1);
    }

    function test_updatePaymentToken_remove_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                rentPriceOracle.ROOT_RESOURCE(),
                ROLE_UPDATE_TOKEN,
                actor
            )
        );
        vm.prank(actor);
        rentPriceOracle.updatePaymentToken(randomPaymentToken(), 0, 0); // remove
    }

    function test_updatePaymentToken_edit_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                rentPriceOracle.ROOT_RESOURCE(),
                ROLE_UPDATE_TOKEN,
                actor
            )
        );
        vm.prank(actor);
        rentPriceOracle.updatePaymentToken(randomPaymentToken(), 1, 1); // edit
    }

    function test_disablePaymentToken_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                rentPriceOracle.ROOT_RESOURCE(),
                ROLE_DISABLE_TOKEN,
                actor
            )
        );
        vm.prank(actor);
        rentPriceOracle.disablePaymentToken(randomPaymentToken());
    }

    function test_getBasePrice_1sec() external view {
        assertEq(rentPriceOracle.getBasePrice(new string(0), 1), 0);
        assertEq(
            rentPriceOracle.getBasePrice(new string(1), 1),
            StandardRegistrar.RATE_1CP
        );
        assertEq(
            rentPriceOracle.getBasePrice(new string(2), 1),
            StandardRegistrar.RATE_2CP
        );
        assertEq(
            rentPriceOracle.getBasePrice(new string(3), 1),
            StandardRegistrar.RATE_3CP
        );
        assertEq(
            rentPriceOracle.getBasePrice(new string(4), 1),
            StandardRegistrar.RATE_4CP
        );
        for (uint256 i = 5; i <= 255; ++i) {
            assertEq(
                rentPriceOracle.getBasePrice(new string(i), 1),
                StandardRegistrar.RATE_5CP
            );
        }
        assertEq(rentPriceOracle.getBasePrice(new string(256), 1), 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Discount
    ////////////////////////////////////////////////////////////////////////

    function _applyDiscount(
        uint256[3] memory v0,
        uint64 t0,
        uint64 t1,
        uint256[3] memory v
    ) internal view {
        for (uint256 i; i < v0.length; ++i) {
            if (t0 > 0) {
                assertGt(
                    rentPriceOracle.applyDiscount(v0[i], t0 - 1),
                    v[i],
                    "prev"
                );
            }
            assertEq(rentPriceOracle.applyDiscount(v0[i], t0), v[i], "t0");
            assertEq(rentPriceOracle.applyDiscount(v0[i], t1), v[i], "t1");
            if (t1 < type(uint64).max) {
                assertLt(
                    rentPriceOracle.applyDiscount(v0[i], t1 + 1),
                    v[i],
                    "next"
                );
            }
        }
    }

    // these tests are fragile and specific to the chosen discount points
    function test_applyDiscount_fragile() external view {
        uint64 y = StandardRegistrar.SEC_PER_YEAR;
        uint256[3] memory v0 = [uint256(800), 16000, 64000];
        _applyDiscount(v0, 0, y - 1, v0);
        _applyDiscount(v0, y, 2 * y - 1, [uint256(700), 14000, 56000]);
        _applyDiscount(v0, 2 * y, 5 * y - 1, [uint256(550), 11000, 44000]);
        _applyDiscount(
            v0,
            5 * y,
            type(uint64).max,
            [uint256(450), 9000, 36000]
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Premium
    ////////////////////////////////////////////////////////////////////////

    function test_getPremiumPriceAfter_start() external view {
        assertEq(
            rentPriceOracle.getPremiumPriceAfter(0),
            rentPriceOracle.PREMIUM_PRICE_INITIAL() -
                rentPriceOracle.PREMIUM_PRICE_OFFSET()
        );
    }

    function test_getPremiumPriceAfter_end() external view {
        uint64 dur = rentPriceOracle.PREMIUM_PERIOD();
        assertEq(rentPriceOracle.getPremiumPriceAfter(dur), 0, "at");
        assertEq(rentPriceOracle.getPremiumPriceAfter(dur + 1), 0, "after");
    }

    function test_getPremiumPriceAfter_calc() external {
        StandardRentPriceOracle oracle = new StandardRentPriceOracle(
            address(this),
            new uint256[](0),
            new DiscountPoint[](0),
            0,
            256000,
            1,
            8,
            new PaymentRatio[](0)
        );
        assertEq(oracle.getPremiumPriceAfter(0), 255000, "0");
        assertEq(oracle.getPremiumPriceAfter(1), 127000, "1");
        assertEq(oracle.getPremiumPriceAfter(2), 63000, "2");
        assertEq(oracle.getPremiumPriceAfter(3), 31000, "3");
        assertEq(oracle.getPremiumPriceAfter(4), 15000, "4");
        assertEq(oracle.getPremiumPriceAfter(5), 7000, "5");
        assertEq(oracle.getPremiumPriceAfter(6), 3000, "6");
        assertEq(oracle.getPremiumPriceAfter(7), 1000, "7");
        assertEq(oracle.getPremiumPriceAfter(8), 0, "8");
    }

    ////////////////////////////////////////////////////////////////////////
    // getRegisterPrice()
    ////////////////////////////////////////////////////////////////////////

    function test_getRegisterPrice_calc(uint256) external {
        string memory label = new string(vm.randomUint(3, 255));
        uint64 duration = uint64(vm.randomUint(0, 10000 days));
        uint64 available = uint64(
            vm.randomUint(0, rentPriceOracle.PREMIUM_PERIOD() * 2)
        );
        IERC20 paymentToken = randomPaymentToken();
        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            label,
            available,
            duration,
            paymentToken
        );
        uint256 baseUnits = rentPriceOracle.getBasePrice(label, duration);
        uint256 premiumUnits = rentPriceOracle.getPremiumPriceAfter(available);
        assertEq(
            base + premium,
            rentPriceOracle.convertUnits(
                baseUnits + premiumUnits,
                paymentToken
            ),
            "total"
        );
        assertEq(
            premium,
            rentPriceOracle.convertUnits(premiumUnits, paymentToken),
            "premium"
        );
    }

    function test_getRegisterPrice_notValid() external {
        uint256[5] memory v = [uint256(0), 1, 2, 256, 1000];
        for (uint256 i; i < v.length; ++i) {
            string memory label = new string(v[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRentPriceOracle.NotValid.selector,
                    label
                )
            );
            rentPriceOracle.getRegisterPrice(label, 0, 1, tokenUSDC);
        }
    }

    function test_getRegisterPrice_paymentTokenNotSupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.getRegisterPrice(
            new string(5),
            0,
            StandardRegistrar.MIN_REGISTER_DURATION,
            invalidPaymentToken
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // getRenewPrice()
    ////////////////////////////////////////////////////////////////////////

    function test_getRenewPrice_calc(uint256) external {
        string memory label = new string(vm.randomUint(3, 255));
        uint64 duration = uint64(vm.randomUint(1, 10000 days));
        IERC20 paymentToken = randomPaymentToken();
        assertEq(
            rentPriceOracle.getRenewPrice(
                label,
                UNUSED_EXPIRY,
                duration,
                paymentToken
            ),
            rentPriceOracle.convertUnits(
                rentPriceOracle.getBasePrice(label, duration),
                paymentToken
            )
        );
    }

    function test_getRenewPrice_notValid() external {
        uint256[5] memory v = [uint256(0), 1, 2, 256, 1000];
        for (uint256 i; i < v.length; ++i) {
            string memory label = new string(v[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRentPriceOracle.NotValid.selector,
                    label
                )
            );
            rentPriceOracle.getRenewPrice(
                label,
                UNUSED_EXPIRY,
                0,
                randomPaymentToken()
            );
        }
    }

    function test_getRenewPrice_paymentTokenNotSupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.getRenewPrice(
            new string(5),
            UNUSED_EXPIRY,
            StandardRegistrar.MIN_REGISTER_DURATION,
            invalidPaymentToken
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Utilities
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
        assertEq(rentPriceOracle.isValid("a"), StandardRegistrar.RATE_1CP > 0);
        assertEq(rentPriceOracle.isValid("ab"), StandardRegistrar.RATE_2CP > 0);
        assertEq(
            rentPriceOracle.isValid("abc"),
            StandardRegistrar.RATE_3CP > 0
        );
        assertEq(
            rentPriceOracle.isValid("abce"),
            StandardRegistrar.RATE_4CP > 0
        );
        assertEq(
            rentPriceOracle.isValid("abcde"),
            StandardRegistrar.RATE_5CP > 0
        );
        assertEq(
            rentPriceOracle.isValid(new string(255)),
            StandardRegistrar.RATE_5CP > 0
        );
    }

    function test_convertUnits_calc(uint192 x) external view {
        MockERC20 paymentToken = randomPaymentToken();
        (uint128 numer, uint128 denom) = rentPriceOracle.getPaymentTokenRatio(
            paymentToken
        );
        assertEq(
            rentPriceOracle.convertUnits(x, paymentToken),
            Math.mulDiv(x, numer, denom, Math.Rounding.Ceil)
        );
    }

    function test_convertUnits_Identity(uint256 x) external view {
        assertEq(rentPriceOracle.convertUnits(x, tokenIdentity), x);
    }

    function test_convertUnits_paymentTokenNotSupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.convertUnits(0, invalidPaymentToken);
    }
}
