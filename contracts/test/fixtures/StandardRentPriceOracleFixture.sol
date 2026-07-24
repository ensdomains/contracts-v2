// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StandardRentPriceOracle, PaymentRatio} from "~src/registrar/StandardRentPriceOracle.sol";
import {NATIVE_ETH} from "~src/registrar/interfaces/IETHRenewer.sol";
import {MockChainlinkAggregator} from "~test/mocks/MockChainlinkAggregator.sol";
import {
    MockERC20,
    MockERC20Blacklist,
    MockERC20VoidReturn,
    MockERC20FalseReturn
} from "~test/mocks/MockERC20.sol";
import {StandardRegistrar} from "~test/StandardRegistrar.sol";

/// @dev Reusable testing fixture for StandardRentPriceOracle.
contract StandardRentPriceOracleFixture is Test {
    StandardRentPriceOracle rentPriceOracle;
    MockChainlinkAggregator ethOracle;

    MockERC20 tokenETH = MockERC20(NATIVE_ETH);
    MockERC20 tokenWETH;
    MockERC20 tokenUSDC;
    MockERC20 tokenDAI;
    MockERC20 tokenIdentity;
    MockERC20Blacklist tokenBlack;
    MockERC20VoidReturn tokenVoid;
    MockERC20FalseReturn tokenFalse;

    MockERC20[] paymentTokens;

    address beneficiary = makeAddr("beneficiary");
    address refundTo = makeAddr("refundTo");
    IERC20 invalidPaymentToken = IERC20(makeAddr("invalidPaymentToken"));

    function deployStandardRentPriceOracleFixture() public {
        tokenWETH = new MockERC20("WETH", 18);
        tokenUSDC = new MockERC20("USDC", 6);
        tokenDAI = new MockERC20("DAI", 18);
        tokenIdentity = new MockERC20("Identity", StandardRegistrar.PRICE_DECIMALS);
        tokenBlack = new MockERC20Blacklist();
        tokenVoid = new MockERC20VoidReturn();
        tokenFalse = new MockERC20FalseReturn();

        ethOracle = new MockChainlinkAggregator(2000 * 10 ** 8, 8); // $2000

        paymentTokens = new MockERC20[](7);
        paymentTokens[0] = tokenUSDC;
        paymentTokens[1] = tokenDAI;
        paymentTokens[2] = tokenIdentity;
        paymentTokens[3] = tokenBlack;
        paymentTokens[4] = tokenVoid;
        paymentTokens[5] = tokenFalse;
        paymentTokens[6] = tokenWETH;

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](paymentTokens.length + 1); // room for eth
        for (uint256 i; i < paymentTokens.length; ++i) {
            paymentRatios[i] = StandardRegistrar.ratioFromStable(paymentTokens[i]);
        }
        paymentRatios[paymentTokens.length] = StandardRegistrar.ratioFromStable(tokenWETH); // use weth
        paymentRatios[paymentTokens.length].paymentToken = tokenETH; // replace with eth

        rentPriceOracle = new StandardRentPriceOracle(
            address(this),
            StandardRegistrar.getBaseRates(),
            StandardRegistrar.getDiscountPoints(),
            StandardRegistrar.DISCOUNT_DENOMINATOR,
            StandardRegistrar.PREMIUM_PRICE_INITIAL,
            StandardRegistrar.PREMIUM_HALVING_PERIOD,
            StandardRegistrar.PREMIUM_PERIOD,
            paymentRatios,
            tokenWETH,
            ethOracle
        );

        // give beneficiary non-zero balance
        for (uint256 i; i < paymentTokens.length; ++i) {
            paymentTokens[i].mint(beneficiary, 1);
        }
    }

    function setupPaymentTokens(address owner, address approved) internal {
        vm.deal(owner, 1e6 ether);
        for (uint256 i; i < paymentTokens.length; ++i) {
            MockERC20 token = paymentTokens[i];
            token.mint(owner, 1e9 * 10 ** token.decimals());
        }
        vm.startPrank(owner);
        for (uint256 i; i < paymentTokens.length; ++i) {
            paymentTokens[i].approve(approved, type(uint256).max);
        }
        vm.stopPrank();
    }

    function randomPaymentToken() internal view returns (MockERC20) {
        return vm.randomBool() ? tokenUSDC : tokenDAI;
    }
}
