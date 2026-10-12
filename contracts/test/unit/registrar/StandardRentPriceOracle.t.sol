// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {IRentPriceOracle} from "~src/registrar/interfaces/IRentPriceOracle.sol";
import {
    StandardRentPriceOracle,
    PaymentConfigWithToken,
    DiscountPoint,
    DEFAULT_ROLE_BITMAP,
    ROLE_UPDATE_TOKEN,
    ROLE_UPDATE_TOKEN_ADMIN,
    ROLE_DISABLE_TOKEN,
    ROLE_DISABLE_TOKEN_ADMIN,
    ROLE_CAN_NAME,
    ROLE_CAN_NAME_ADMIN
} from "~src/registrar/StandardRentPriceOracle.sol";
import {IChainlinkAggregator} from "~src/registrar/interfaces/IChainlinkAggregator.sol";
import {NATIVE_ETH} from "~src/utils/ERC7528.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {StandardRegistrar} from "~test/StandardRegistrar.sol";

/// @dev The expiry parameter of `getRenewPrice()` is currently unused.
uint64 constant UNUSED_EXPIRY = 0;

contract StandardRentPriceOracleTest is StandardRentPriceOracleFixture {
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
        assertTrue(
            ERC165Checker.supportsInterface(
                address(rentPriceOracle),
                type(IContractNamer).interfaceId
            )
        );
    }

    function test_DEFAULT_ROLE_BITMAP() external pure {
        assertEq(
            DEFAULT_ROLE_BITMAP,
            ROLE_UPDATE_TOKEN |
            ROLE_UPDATE_TOKEN_ADMIN |
            ROLE_DISABLE_TOKEN |
            ROLE_DISABLE_TOKEN_ADMIN |
            ROLE_CAN_NAME |
            ROLE_CAN_NAME_ADMIN
        );
    }

    function test_constructor() external view {
        assertTrue(rentPriceOracle.hasRootRoles(DEFAULT_ROLE_BITMAP, address(this)), "roles");
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
                rentPriceOracle.isPaymentToken(address(paymentTokens[i])),
                paymentTokens[i].name()
            );
        }
    }

    function test_constructor_emitPaymentTokenUpdated() external {
        PaymentConfigWithToken[] memory v = new PaymentConfigWithToken[](1);
        PaymentConfigWithToken memory pc =
            PaymentConfigWithToken(
                address(tokenUSDC),
                1,
                1,
                IChainlinkAggregator(address(0)),
                false,
                0
            );
        v[0] = pc;
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(
            pc.paymentToken,
            pc.numer,
            pc.denom,
            pc.oracle,
            pc.flip,
            pc.maxAge
        );
        new StandardRentPriceOracle(
            address(this),
            new uint256[](1),
            new DiscountPoint[](0),
            0,
            0,
            0,
            0,
            v
        );
    }

    function test_constructor_invalidBaseRates() external {
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidBaseRates.selector));
        new StandardRentPriceOracle(
            address(this),
            new uint256[](0), // wrong
            new DiscountPoint[](0),
            0,
            0,
            0,
            0,
            new PaymentConfigWithToken[](0)
        );
    }

    function test_constructor_invalidDiscount_notIncreasingDurations() external {
        DiscountPoint[] memory v = new DiscountPoint[](2);
        v[0] = DiscountPoint(100, 2);
        v[1] = DiscountPoint(100, 1); // wrong: 100 -> 100 => no increase
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidDiscount.selector));
        new StandardRentPriceOracle(
            address(this),
            new uint256[](1),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentConfigWithToken[](0)
        );
    }

    function test_constructor_invalidDiscount_notDecreasingNumerators() external {
        DiscountPoint[] memory v = new DiscountPoint[](2);
        v[0] = DiscountPoint(100, 1);
        v[1] = DiscountPoint(200, 1); // wrong: 1 -> 1 => no decrease
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidDiscount.selector));
        new StandardRentPriceOracle(
            address(this),
            new uint256[](1),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentConfigWithToken[](0)
        );
    }

    function test_constructor_invalidDiscount_aboveDenominator() external {
        DiscountPoint[] memory v = new DiscountPoint[](1);
        v[0] = DiscountPoint(1, 3); // wrong: 3/3 => 0% discount
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidDiscount.selector));
        new StandardRentPriceOracle(
            address(this),
            new uint256[](1),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentConfigWithToken[](0)
        );
    }

    function test_constructor_invalidDiscount_free() external {
        DiscountPoint[] memory v = new DiscountPoint[](1);
        v[0] = DiscountPoint(1, 0); // wrong: 0/3 => 100% discount
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidDiscount.selector));
        new StandardRentPriceOracle(
            address(this),
            new uint256[](1),
            v,
            3, // denominator
            0,
            0,
            0,
            new PaymentConfigWithToken[](0)
        );
    }

    function test_constructor_invalidRatio() external {
        PaymentConfigWithToken[] memory v = new PaymentConfigWithToken[](1);
        v[0] = PaymentConfigWithToken(
            address(tokenUSDC),
            1,
            0,
            IChainlinkAggregator(address(0)),
            false,
            0
        ); // wrong: denom = 0
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidRatio.selector));
        new StandardRentPriceOracle(
            address(this),
            new uint256[](1),
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
        assertFalse(rentPriceOracle.isPaymentToken(address(invalidPaymentToken)));
    }

    function test_getPaymentTokenRatio_exists() external view {
        (uint256 numer0, uint256 denom0) =
            StandardRegistrar.ratioFromDecimals(tokenUSDC.decimals());
        (uint256 numer1, uint256 denom1) = rentPriceOracle.getPaymentTokenRatio(address(tokenUSDC)); // no oracle
        assertEq(numer0, numer1, "numer");
        assertEq(denom0, denom1, "denom");
    }

    function test_getPaymentTokenRatio_unknown() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.getPaymentTokenRatio(address(invalidPaymentToken));
    }

    function test_getPaymentTokenRatio_eth() external view {
        (uint256 numer0, uint256 denom0) = rentPriceOracle.getPaymentTokenRatio(NATIVE_ETH);
        (uint256 numer1, uint256 denom1) = rentPriceOracle.getPaymentTokenRatio(address(tokenWETH));
        (, int256 answer, , , ) = ethOracle.latestRoundData();
        assertEq(numer0, numer1, "same numer");
        assertEq(denom0, denom1, "same denom");
        assertEq(
            numer1,
            10 ** (tokenWETH.decimals() + ethOracle.decimals() - StandardRegistrar.PRICE_DECIMALS),
            "numer"
        );
        assertEq(denom1, uint256(answer), "denom");
    }

    function test_updatePaymentToken_add(
        uint128 numer,
        uint128 denom,
        IChainlinkAggregator oracle,
        bool flip,
        uint64 maxAge
    )
        external
    {
        vm.assume(numer > 0 && denom > 0);
        address paymentToken = address(1);
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken));
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(
            paymentToken,
            numer,
            denom,
            oracle,
            flip,
            maxAge
        );
        StandardRentPriceOracle.PaymentConfig memory pc =
            StandardRentPriceOracle.PaymentConfig(numer, denom, oracle, flip, maxAge);
        rentPriceOracle.updatePaymentToken(paymentToken, pc);
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken));
        assertEq(
            abi.encode(pc),
            abi.encode(rentPriceOracle.getPaymentTokenConfiguration(paymentToken))
        );
    }

    function test_updatePaymentToken_edit(IChainlinkAggregator oracle, bool flip, uint64 maxAge)
        external
    {
        address paymentToken = address(1);
        StandardRentPriceOracle.PaymentConfig memory pc =
            StandardRentPriceOracle.PaymentConfig(1, 2, oracle, flip, maxAge);
        rentPriceOracle.updatePaymentToken(paymentToken, pc);
        pc.numer = 3;
        pc.denom = 4;
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(
            paymentToken,
            pc.numer,
            pc.denom,
            pc.oracle,
            pc.flip,
            pc.maxAge
        );
        rentPriceOracle.updatePaymentToken(paymentToken, pc);
        assertEq(
            abi.encode(pc),
            abi.encode(rentPriceOracle.getPaymentTokenConfiguration(paymentToken))
        );
    }

    function test_updatePaymentToken_remove() external {
        address paymentToken = address(randomPaymentToken());
        StandardRentPriceOracle.PaymentConfig memory pc;
        assertTrue(rentPriceOracle.isPaymentToken(paymentToken));
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(
            paymentToken,
            pc.numer,
            pc.denom,
            pc.oracle,
            pc.flip,
            pc.maxAge
        );
        rentPriceOracle.updatePaymentToken(paymentToken, pc);
        assertFalse(rentPriceOracle.isPaymentToken(paymentToken));
    }

    function test_updatePaymentToken_invalidRatio() external {
        StandardRentPriceOracle.PaymentConfig memory pc;
        pc.denom = 1;
        vm.expectRevert(abi.encodeWithSelector(StandardRentPriceOracle.InvalidRatio.selector));
        rentPriceOracle.updatePaymentToken(address(1), pc);
    }

    function test_updatePaymentToken_notAuthorized() external {
        StandardRentPriceOracle.PaymentConfig memory pc;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                rentPriceOracle.ROOT_RESOURCE(),
                ROLE_UPDATE_TOKEN,
                actor
            )
        );
        vm.prank(actor);
        rentPriceOracle.updatePaymentToken(address(1), pc);
    }

    function test_disablePaymentToken(uint8) external {
        address paymentToken = address(randomPaymentToken());
        StandardRentPriceOracle.PaymentConfig memory pc;
        vm.expectEmit();
        emit StandardRentPriceOracle.PaymentTokenUpdated(
            paymentToken,
            pc.numer,
            pc.denom,
            pc.oracle,
            pc.flip,
            pc.maxAge
        );
        rentPriceOracle.disablePaymentToken(paymentToken);
    }

    function test_disablePaymentToken_unchanged() external {
        vm.recordLogs();
        rentPriceOracle.disablePaymentToken(address(invalidPaymentToken)); // noop
        assertEq(vm.getRecordedLogs().length, 0);
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
        rentPriceOracle.disablePaymentToken(address(1));
    }

    ////////////////////////////////////////////////////////////////////////
    // Discount
    ////////////////////////////////////////////////////////////////////////

    function _applyDiscount(uint256[3] memory v0, uint64 t0, uint64 t1, uint256[3] memory v)
        internal
        view
    {
        for (uint256 i; i < v0.length; ++i) {
            if (t0 > 0) {
                assertGt(rentPriceOracle.applyDiscount(v0[i], t0 - 1), v[i], "prev");
            }
            assertEq(rentPriceOracle.applyDiscount(v0[i], t0), v[i], "t0");
            assertEq(rentPriceOracle.applyDiscount(v0[i], t1), v[i], "t1");
            if (t1 < type(uint64).max) {
                assertLt(rentPriceOracle.applyDiscount(v0[i], t1 + 1), v[i], "next");
            }
        }
    }

    // these tests are fragile and specific to the chosen discount points
    function test_applyDiscount_fragile() external view {
        uint64 y = StandardRegistrar.SEC_PER_YEAR;
        uint256[3] memory v0 = [uint256(800), 16000, 64000];
        _applyDiscount(v0, 0, 2 * y - 1, v0);
        _applyDiscount(v0, 2 * y, 3 * y - 1, [uint256(700), 14000, 56000]);
        _applyDiscount(v0, 3 * y, 6 * y - 1, [uint256(550), 11000, 44000]);
        _applyDiscount(v0, 6 * y, type(uint64).max, [uint256(450), 9000, 36000]);
    }

    ////////////////////////////////////////////////////////////////////////
    // Premium
    ////////////////////////////////////////////////////////////////////////

    function test_getPremiumPriceAfter_start() external view {
        assertEq(
            rentPriceOracle.getPremiumPriceAfter(0),
            rentPriceOracle.PREMIUM_PRICE_INITIAL() - rentPriceOracle.PREMIUM_PRICE_OFFSET()
        );
    }

    function test_getPremiumPriceAfter_end() external view {
        uint64 dur = rentPriceOracle.PREMIUM_PERIOD();
        assertEq(rentPriceOracle.getPremiumPriceAfter(dur), 0, "at");
        assertEq(rentPriceOracle.getPremiumPriceAfter(dur + 1), 0, "after");
    }

    function test_getPremiumPriceAfter_calc() external {
        StandardRentPriceOracle oracle =
            new StandardRentPriceOracle(
                address(this),
                new uint256[](1),
                new DiscountPoint[](0),
                0,
                256000,
                1,
                8,
                new PaymentConfigWithToken[](0)
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
        uint64 available = uint64(vm.randomUint(0, rentPriceOracle.PREMIUM_PERIOD() * 2));
        address paymentToken = address(randomPaymentToken());
        (uint256 base, uint256 premium) =
            rentPriceOracle.getRegisterPrice(label, available, duration, paymentToken);
        uint256 baseUnits = rentPriceOracle.getBasePrice(label, duration);
        uint256 premiumUnits = rentPriceOracle.getPremiumPriceAfter(available);
        assertEq(
            base + premium,
            rentPriceOracle.convertUnits(baseUnits + premiumUnits, paymentToken),
            "total"
        );
        assertEq(premium, rentPriceOracle.convertUnits(premiumUnits, paymentToken), "premium");
    }

    function test_getRegisterPrice_notValid() external {
        uint256[5] memory v = [uint256(0), 1, 2, 256, 1000];
        for (uint256 i; i < v.length; ++i) {
            string memory label = new string(v[i]);
            vm.expectRevert(abi.encodeWithSelector(IRentPriceOracle.NotValid.selector, label));
            rentPriceOracle.getRegisterPrice(label, 0, 1, address(tokenUSDC));
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
            address(invalidPaymentToken)
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // getRenewPrice()
    ////////////////////////////////////////////////////////////////////////

    function test_getRenewPrice_calc(uint256) external {
        string memory label = new string(vm.randomUint(3, 255));
        uint64 duration = uint64(vm.randomUint(1, 10000 days));
        address paymentToken = address(randomPaymentToken());
        uint256 price = rentPriceOracle.getRenewPrice(label, UNUSED_EXPIRY, duration, paymentToken);
        assertEq(
            price,
            rentPriceOracle.convertUnits(rentPriceOracle.getBasePrice(label, duration), paymentToken)
        );
    }

    function test_getRenewPrice_notValid() external {
        uint256[5] memory v = [uint256(0), 1, 2, 256, 1000];
        for (uint256 i; i < v.length; ++i) {
            string memory label = new string(v[i]);
            vm.expectRevert(abi.encodeWithSelector(IRentPriceOracle.NotValid.selector, label));
            rentPriceOracle.getRenewPrice(label, UNUSED_EXPIRY, 0, address(randomPaymentToken()));
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
            address(invalidPaymentToken)
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Chainlink Oracle
    ////////////////////////////////////////////////////////////////////////

    function test_ethOracle() external view {
        (, int256 answer, , uint256 updatedAt, ) = ethOracle.latestRoundData();
        assertEq(
            uint256(answer),
            StandardRegistrar.USD_PER_ETH * 10 ** ethOracle.decimals(),
            "answer"
        );
        assertEq(updatedAt, block.timestamp, "updatedAt");
    }

    function test_getPaymentTokenRatio_invalidOracle() external {
        PaymentConfigWithToken[] memory v = new PaymentConfigWithToken[](1);
        v[0] = PaymentConfigWithToken(NATIVE_ETH, 1, 1, invalidOracle, false, 0);
        StandardRentPriceOracle oracle =
            new StandardRentPriceOracle(
                address(this),
                StandardRegistrar.getBaseRates(),
                StandardRegistrar.getDiscountPoints(),
                StandardRegistrar.DISCOUNT_DENOMINATOR,
                StandardRegistrar.PREMIUM_PRICE_INITIAL,
                StandardRegistrar.PREMIUM_HALVING_PERIOD,
                StandardRegistrar.PREMIUM_PERIOD,
                v
            );
        (, int256 answer, , , ) = invalidOracle.latestRoundData();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.InvalidOracleResponse.selector,
                NATIVE_ETH,
                answer
            )
        );
        oracle.getPaymentTokenRatio(NATIVE_ETH);
    }

    function test_getPaymentTokenRatio_staleOracle() external {
        vm.warp(block.timestamp + staleOracle.MAX_AGE()); // prevent underflow
        PaymentConfigWithToken[] memory v = new PaymentConfigWithToken[](1);
        v[0] = PaymentConfigWithToken(NATIVE_ETH, 1, 1, staleOracle, false, 0);
        StandardRentPriceOracle oracle =
            new StandardRentPriceOracle(
                address(this),
                StandardRegistrar.getBaseRates(),
                StandardRegistrar.getDiscountPoints(),
                StandardRegistrar.DISCOUNT_DENOMINATOR,
                StandardRegistrar.PREMIUM_PRICE_INITIAL,
                StandardRegistrar.PREMIUM_HALVING_PERIOD,
                StandardRegistrar.PREMIUM_PERIOD,
                v
            );
        (, , , uint256 updatedAt, ) = staleOracle.latestRoundData();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.StaleOracleResponse.selector,
                NATIVE_ETH,
                updatedAt,
                block.timestamp
            )
        );
        oracle.getPaymentTokenRatio(NATIVE_ETH);
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
        assertEq(rentPriceOracle.isValid("abc"), StandardRegistrar.RATE_3CP > 0);
        assertEq(rentPriceOracle.isValid("abce"), StandardRegistrar.RATE_4CP > 0);
        assertEq(rentPriceOracle.isValid("abcde"), StandardRegistrar.RATE_5CP > 0);
        assertEq(rentPriceOracle.isValid(new string(255)), StandardRegistrar.RATE_5CP > 0);
    }

    function test_getBasePrice_1sec() external view {
        assertEq(rentPriceOracle.getBasePrice(new string(0), 1), 0);
        assertEq(rentPriceOracle.getBasePrice(new string(1), 1), StandardRegistrar.RATE_1CP);
        assertEq(rentPriceOracle.getBasePrice(new string(2), 1), StandardRegistrar.RATE_2CP);
        assertEq(rentPriceOracle.getBasePrice(new string(3), 1), StandardRegistrar.RATE_3CP);
        assertEq(rentPriceOracle.getBasePrice(new string(4), 1), StandardRegistrar.RATE_4CP);
        for (uint256 i = 5; i <= 255; ++i) {
            assertEq(rentPriceOracle.getBasePrice(new string(i), 1), StandardRegistrar.RATE_5CP);
        }
        assertEq(rentPriceOracle.getBasePrice(new string(256), 1), 0);
    }

    function test_convertUnits_calc(uint192 x) external view {
        address paymentToken = address(randomPaymentToken());
        (uint256 numer, uint256 denom) = rentPriceOracle.getPaymentTokenRatio(paymentToken);
        assertEq(
            rentPriceOracle.convertUnits(x, paymentToken),
            Math.mulDiv(x, numer, denom, Math.Rounding.Ceil)
        );
    }

    function test_convertUnits_identity(uint256 x) external view {
        assertEq(rentPriceOracle.convertUnits(x, address(tokenIdentity)), x);
    }

    function test_convertUnits_paymentTokenNotSupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.PaymentTokenNotSupported.selector,
                invalidPaymentToken
            )
        );
        rentPriceOracle.convertUnits(0, address(invalidPaymentToken));
    }

    function test_isContractNamer() external {
        assertTrue(rentPriceOracle.isContractNamer(address(this)));

        assertFalse(rentPriceOracle.isContractNamer(actor), "before");
        rentPriceOracle.grantRootRoles(ROLE_CAN_NAME, actor);
        assertTrue(rentPriceOracle.isContractNamer(actor), "granted");
        rentPriceOracle.revokeRootRoles(ROLE_CAN_NAME, actor);
        assertFalse(rentPriceOracle.isContractNamer(actor), "revoked");
    }
}
