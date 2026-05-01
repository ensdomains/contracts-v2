// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StandardPricing} from "~test/StandardPricing.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {
    StandardRentPriceOracle,
    PaymentRatio,
    IRentPriceOracle,
    DiscountPoint
} from "~src/registrar/StandardRentPriceOracle.sol";
import {
    MockERC20,
    MockERC20Blacklist,
    MockERC20VoidReturn,
    MockERC20FalseReturn
} from "~test/mocks/MockERC20.sol";

/// @dev Reusable testing fixture for StandardRentPriceOracle.
contract StandardRentPriceOracleFixture is Test {
    StandardRentPriceOracle rentPriceOracle;

    MockERC20 tokenUSDC;
    MockERC20 tokenDAI;
    MockERC20 tokenIdentity;
    MockERC20Blacklist tokenBlack;
    MockERC20VoidReturn tokenVoid;
    MockERC20FalseReturn tokenFalse;

    MockERC20[] paymentTokens;

    address beneficiary = makeAddr("beneficiary");
    address invalidPaymentToken = makeAddr("invalidPaymentToken");
    uint64 minRenewDuration = 1;

    function deployStandardRentPriceOracleFixture(IPermissionedRegistry ethRegistry) public {
        tokenUSDC = new MockERC20("USDC", 6);
        tokenDAI = new MockERC20("DAI", 18);
        tokenIdentity = new MockERC20("ID", StandardPricing.PRICE_DECIMALS);
        tokenBlack = new MockERC20Blacklist();
        tokenVoid = new MockERC20VoidReturn();
        tokenFalse = new MockERC20FalseReturn();

        paymentTokens = new MockERC20[](6);
        paymentTokens[0] = tokenUSDC;
        paymentTokens[1] = tokenDAI;
        paymentTokens[2] = tokenIdentity;
        paymentTokens[3] = tokenBlack;
        paymentTokens[4] = tokenVoid;
        paymentTokens[5] = tokenFalse;

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](paymentTokens.length);
        for (uint256 i; i < paymentTokens.length; ++i) {
            paymentRatios[i] = StandardPricing.ratioFromStable(paymentTokens[i]);
        }

        vm.expectEmit();
        emit StandardRentPriceOracle.BeneficiaryUpdated(beneficiary);
        vm.expectEmit();
        emit StandardRentPriceOracle.MinimumRegisterDurationUpdated(
            StandardPricing.MIN_REGISTER_DURATION
        );
        vm.expectEmit();
        emit StandardRentPriceOracle.BaseRatesUpdated(StandardPricing.getBaseRates());
        vm.expectEmit();
        emit StandardRentPriceOracle.DiscountPointsUpdated(StandardPricing.getDiscountPoints());
        vm.expectEmit();
        emit StandardRentPriceOracle.PremiumPricingUpdated(
            StandardPricing.PREMIUM_PRICE_INITIAL,
            StandardPricing.PREMIUM_HALVING_PERIOD,
            StandardPricing.PREMIUM_PERIOD
        );
        for (uint256 i; i < paymentRatios.length; ++i) {
            vm.expectEmit();
            emit StandardRentPriceOracle.PaymentTokenAdded(paymentRatios[i].token);
        }
        rentPriceOracle = new StandardRentPriceOracle(
            address(this),
            ethRegistry,
            beneficiary,
            StandardPricing.MIN_REGISTER_DURATION,
            StandardPricing.getBaseRates(),
            StandardPricing.getDiscountPoints(),
            StandardPricing.PREMIUM_PRICE_INITIAL,
            StandardPricing.PREMIUM_HALVING_PERIOD,
            StandardPricing.PREMIUM_PERIOD,
            paymentRatios
        );

        // give beneficiary non-zero balance
        for (uint256 i; i < paymentTokens.length; ++i) {
            paymentTokens[i].mint(beneficiary, 1);
        }

        if (block.timestamp < rentPriceOracle.premiumPeriod()) {
            vm.warp(rentPriceOracle.premiumPeriod()); // avoid timestamp issues
        }
    }

    function setupPaymentTokens(address owner) internal {
        for (uint256 i; i < paymentTokens.length; ++i) {
            MockERC20 token = paymentTokens[i];
            token.mint(owner, 1e9 * 10 ** token.decimals());
        }
        vm.startPrank(owner);
        for (uint256 i; i < paymentTokens.length; ++i) {
            paymentTokens[i].approve(address(rentPriceOracle), type(uint256).max);
        }
        vm.stopPrank();
    }
}
