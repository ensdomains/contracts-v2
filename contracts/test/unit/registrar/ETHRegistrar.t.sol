// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {StandardPricing} from "./StandardPricing.sol";

import {PermissionedRegistry, IEnhancedAccessControl} from "~src/registry/PermissionedRegistry.sol";
import {SimpleRegistryMetadata} from "~src/registry/SimpleRegistryMetadata.sol";
import {
    ETHRegistrar,
    IETHRegistrar,
    IRegistry,
    RegistryRolesLib,
    EACBaseRolesLib,
    LibLabel,
    InvalidOwner,
    REGISTRATION_ROLE_BITMAP,
    ROLE_SET_ORACLE
} from "~src/registrar/ETHRegistrar.sol";
import {
    StandardRentPriceOracle,
    IRentPriceOracle,
    PaymentRatio,
    DiscountPoint
} from "~src/registrar/StandardRentPriceOracle.sol";
import {
    MockERC20,
    MockERC20Blacklist,
    MockERC20VoidReturn,
    MockERC20FalseReturn
} from "~test/mocks/MockERC20.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract ETHRegistrarTest is Test {
    PermissionedRegistry ethRegistry;
    MockHCAFactoryBasic hcaFactory;

    StandardRentPriceOracle rentPriceOracle;
    ETHRegistrar ethRegistrar;

    MockERC20 tokenUSDC;
    MockERC20 tokenDAI;
    MockERC20Blacklist tokenBlack;
    MockERC20VoidReturn tokenVoid;
    MockERC20FalseReturn tokenFalse;

    address user = makeAddr("user");
    address beneficiary = makeAddr("beneficiary");

    string testLabel = "testname";
    address testSender = user;
    address testOwner = user;
    IRegistry testRegistry = IRegistry(makeAddr("registry"));
    address testResolver = makeAddr("resolver");
    IERC20 testPaymentToken; ///|
    bytes32 testSecret; ////////|
    bytes32 testReferrer; //////| set below
    uint64 testDuration; ///////|
    uint256 testCommitDelay; ///|

    function setUp() external {
        hcaFactory = new MockHCAFactoryBasic();
        ethRegistry = new PermissionedRegistry(
            hcaFactory,
            new SimpleRegistryMetadata(hcaFactory),
            address(this),
            EACBaseRolesLib.ALL_ROLES
        );

        tokenUSDC = new MockERC20("USDC", 6, hcaFactory);
        tokenDAI = new MockERC20("DAI", 18, hcaFactory);
        tokenBlack = new MockERC20Blacklist();
        tokenVoid = new MockERC20VoidReturn();
        tokenFalse = new MockERC20FalseReturn();

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](5);
        paymentRatios[0] = StandardPricing.ratioFromStable(tokenUSDC);
        paymentRatios[1] = StandardPricing.ratioFromStable(tokenDAI);
        paymentRatios[2] = StandardPricing.ratioFromStable(tokenBlack);
        paymentRatios[3] = StandardPricing.ratioFromStable(tokenVoid);
        paymentRatios[4] = StandardPricing.ratioFromStable(tokenFalse);

        rentPriceOracle = new StandardRentPriceOracle(
            address(this),
            ethRegistry,
            StandardPricing.getBaseRates(),
            new DiscountPoint[](0), // disabled discount
            StandardPricing.PREMIUM_PRICE_INITIAL,
            StandardPricing.PREMIUM_HALVING_PERIOD,
            StandardPricing.PREMIUM_PERIOD,
            paymentRatios
        );

        ethRegistrar = new ETHRegistrar(
            ethRegistry,
            hcaFactory,
            beneficiary,
            StandardPricing.MIN_COMMITMENT_AGE,
            StandardPricing.MAX_COMMITMENT_AGE,
            StandardPricing.MIN_REGISTER_DURATION,
            rentPriceOracle
        );

        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(ethRegistrar)
        );

        for (uint256 i; i < paymentRatios.length; i++) {
            MockERC20 token = MockERC20(address(paymentRatios[i].token));
            token.mint(user, 1e9 * 10 ** token.decimals());
            vm.prank(user);
            token.approve(address(ethRegistrar), type(uint256).max);
        }

        vm.warp(rentPriceOracle.premiumPeriod()); // avoid timestamp issues

        testPaymentToken = tokenUSDC;
        testSecret = bytes32(vm.randomUint());
        testReferrer = bytes32(vm.randomUint());
        testDuration = ethRegistrar.MIN_REGISTER_DURATION();
        testCommitDelay = ethRegistrar.MIN_COMMITMENT_AGE() + 1;
    }

    function test_constructor() external view {
        assertEq(address(ethRegistrar.REGISTRY()), address(ethRegistry), "REGISTRY");
        assertEq(ethRegistrar.BENEFICIARY(), address(beneficiary), "BENEFICIARY");
        assertEq(
            ethRegistrar.MIN_COMMITMENT_AGE(),
            StandardPricing.MIN_COMMITMENT_AGE,
            "MIN_COMMITMENT_AGE"
        );
        assertEq(
            ethRegistrar.MAX_COMMITMENT_AGE(),
            StandardPricing.MAX_COMMITMENT_AGE,
            "MAX_COMMITMENT_AGE"
        );
        assertEq(
            ethRegistrar.MIN_REGISTER_DURATION(),
            StandardPricing.MIN_REGISTER_DURATION,
            "MIN_REGISTER_DURATION"
        );
        assertEq(
            address(ethRegistrar.rentPriceOracle()),
            address(rentPriceOracle),
            "rentPriceOracle"
        );
    }

    function test_constructor_emptyRange() external {
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.MaxCommitmentAgeTooLow.selector));
        new ETHRegistrar(
            ethRegistry,
            hcaFactory,
            beneficiary,
            1, // minCommitmentAge
            1, // maxCommitmentAge
            0,
            rentPriceOracle
        );
    }

    function test_constructor_invalidRange() external {
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.MaxCommitmentAgeTooLow.selector));
        new ETHRegistrar(
            ethRegistry,
            hcaFactory,
            beneficiary,
            1, // minCommitmentAge
            0, // maxCommitmentAge
            0,
            rentPriceOracle
        );
    }

    function test_setRentPriceOracle() external {
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio(tokenUSDC, 1, 1);
        uint256[] memory baseRates = new uint256[](2);
        baseRates[0] = 1;
        baseRates[1] = 0;
        StandardRentPriceOracle oracle = new StandardRentPriceOracle(
            address(this),
            ethRegistry,
            baseRates,
            new DiscountPoint[](0), // disabled discount
            0, // \
            0, //  disabled premium
            0, // /
            paymentRatios
        );
        ethRegistrar.setRentPriceOracle(oracle);
        assertTrue(ethRegistrar.isValid("a"), "a");
        assertFalse(ethRegistrar.isValid("ab"), "ab");
        assertFalse(ethRegistrar.isValid("abcdef"), "abcdef");
        assertFalse(ethRegistrar.isPaymentToken(tokenDAI), "DAI");
        (uint256 base, ) = ethRegistrar.rentPrice("a", address(0), 1, tokenUSDC);
        assertEq(base, 1, "rent"); // 1 * 10^x / 10^x = 1
    }

    function test_setRentPriceOracle_notAuthorized() external {
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio(tokenUSDC, 1, 1);
        StandardRentPriceOracle oracle = new StandardRentPriceOracle(
            address(this),
            ethRegistry,
            new uint256[](0), // disabled rentals
            new DiscountPoint[](0), // disabled discount
            0,
            0,
            0,
            paymentRatios
        );
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                ethRegistry.ROOT_RESOURCE(),
                ROLE_SET_ORACLE,
                user
            )
        );
        ethRegistrar.setRentPriceOracle(oracle);
        vm.stopPrank();
    }

    function test_isPaymentToken() external view {
        assertTrue(rentPriceOracle.isPaymentToken(tokenUSDC), "USDC");
        assertTrue(rentPriceOracle.isPaymentToken(tokenDAI), "DAI");
        assertTrue(rentPriceOracle.isPaymentToken(tokenBlack), "Black");
        assertTrue(rentPriceOracle.isPaymentToken(tokenVoid), "Void");
        assertTrue(rentPriceOracle.isPaymentToken(tokenFalse), "False");
        assertFalse(rentPriceOracle.isPaymentToken(IERC20(address(0))));
    }

    // same as StandardRentPriceOracle.t.sol
    function test_isValid() external view {
        assertFalse(rentPriceOracle.isValid(""));
        assertEq(rentPriceOracle.isValid("a"), StandardPricing.RATE_1CP > 0);
        assertEq(rentPriceOracle.isValid("ab"), StandardPricing.RATE_2CP > 0);
        assertEq(rentPriceOracle.isValid("abc"), StandardPricing.RATE_3CP > 0);
        assertEq(rentPriceOracle.isValid("abce"), StandardPricing.RATE_4CP > 0);
        assertEq(rentPriceOracle.isValid("abcde"), StandardPricing.RATE_5CP > 0);
        assertEq(
            rentPriceOracle.isValid("abcdefghijklmnopqrstuvwxyz"),
            StandardPricing.RATE_5CP > 0
        );
    }

    function _makeCommitment() internal view returns (bytes32) {
        return
            ethRegistrar.makeCommitment(
                testLabel,
                testOwner,
                testSecret,
                testRegistry,
                testResolver,
                testDuration,
                testReferrer
            );
    }

    function _register() external returns (uint256 tokenId) {
        bytes32 commitment = _makeCommitment();
        vm.startPrank(testSender);
        ethRegistrar.commit(commitment);
        vm.warp(block.timestamp + testCommitDelay);
        tokenId = ethRegistrar.register(
            testLabel,
            testOwner,
            testSecret,
            testRegistry,
            testResolver,
            testDuration,
            testPaymentToken,
            testReferrer
        );
        vm.stopPrank();
    }

    function _renew() external {
        vm.prank(testSender);
        ethRegistrar.renew(testLabel, testDuration, testPaymentToken, testReferrer);
    }

    function _reserve() internal {
        ethRegistry.register(
            testLabel,
            address(0),
            IRegistry(address(0)),
            address(0),
            0,
            uint64(block.timestamp + testDuration)
        );
    }

    function test_commit() external {
        bytes32 commitment = _makeCommitment();
        assertEq(
            commitment,
            keccak256(
                abi.encode(
                    testLabel,
                    testOwner,
                    testSecret,
                    testRegistry,
                    testResolver,
                    testDuration,
                    testReferrer
                )
            ),
            "hash"
        );
        vm.expectEmit();
        emit IETHRegistrar.CommitmentMade(commitment);
        ethRegistrar.commit(commitment);
        assertEq(ethRegistrar.commitmentAt(commitment), block.timestamp, "time");
    }

    function test_commitmentAt() external {
        bytes32 commitment = bytes32(uint256(1));
        assertEq(ethRegistrar.commitmentAt(commitment), 0, "before");
        ethRegistrar.commit(commitment);
        assertEq(ethRegistrar.commitmentAt(commitment), block.timestamp, "after");
    }

    function test_commit_unexpiredCommitment() external {
        bytes32 commitment = bytes32(uint256(1));
        ethRegistrar.commit(commitment);
        vm.expectRevert(
            abi.encodeWithSelector(IETHRegistrar.UnexpiredCommitmentExists.selector, commitment)
        );
        ethRegistrar.commit(commitment);
    }

    function test_isAvailable() external {
        assertTrue(ethRegistrar.isAvailable(testLabel), "before");
        this._register();
        assertFalse(ethRegistrar.isAvailable(testLabel), "after");
    }

    function test_register() external {
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        vm.expectEmit();
        emit IETHRegistrar.NameRegistered(
            LibLabel.withVersion(LibLabel.id(testLabel), 0),
            testLabel,
            testOwner,
            testRegistry,
            testResolver,
            testDuration,
            testPaymentToken,
            testReferrer,
            base,
            premium
        );
        uint256 tokenId = this._register();
        assertEq(ethRegistry.ownerOf(tokenId), testOwner, "owner");
        assertEq(ethRegistry.getExpiry(tokenId), uint64(block.timestamp) + testDuration, "expiry");
    }

    function test_register_premium_start() external {
        uint256 tokenId = this._register();
        uint64 expiry = ethRegistry.getExpiry(tokenId);
        vm.warp(expiry);
        assertEq(rentPriceOracle.premiumPrice(expiry), rentPriceOracle.premiumPriceAfter(0));
    }

    function test_register_premium_end() external {
        uint256 tokenId = this._register();
        uint64 expiry = ethRegistry.getExpiry(tokenId);
        vm.warp(expiry + rentPriceOracle.premiumPeriod());
        assertEq(rentPriceOracle.premiumPrice(expiry), 0);
    }

    function test_register_premium_latestOwner() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId));
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        assertEq(premium, 0, "premium");
        uint256 balance0 = testPaymentToken.balanceOf(testOwner);
        this._register();
        assertEq(balance0 - base, testPaymentToken.balanceOf(testOwner), "balance");
    }

    function test_register_insufficientAllowance() external {
        vm.prank(testSender);
        tokenUSDC.approve(address(ethRegistrar), 0);
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(ethRegistrar), // spender
                0, // allowance
                base + premium // needed
            )
        );
        this._register();
    }

    function test_register_insufficientBalance() external {
        tokenUSDC.nuke(testSender);
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                testSender, // sender
                0, // allowance
                base + premium // needed
            )
        );
        this._register();
    }

    function test_register_commitmentTooNew() external {
        uint256 dt = 1;
        testCommitDelay = ethRegistrar.MIN_COMMITMENT_AGE() - dt;
        uint256 t = block.timestamp + testCommitDelay;
        vm.expectRevert(
            abi.encodeWithSelector(
                IETHRegistrar.CommitmentTooNew.selector,
                _makeCommitment(),
                t + dt,
                t
            )
        );
        this._register();
    }

    function test_register_commitmentTooOld() external {
        uint256 dt = 1;
        testCommitDelay = ethRegistrar.MAX_COMMITMENT_AGE() + dt;
        uint256 t = block.timestamp + testCommitDelay;
        vm.expectRevert(
            abi.encodeWithSelector(
                IETHRegistrar.CommitmentTooOld.selector,
                _makeCommitment(),
                t - dt,
                t
            )
        );
        this._register();
    }

    function test_register_durationTooShort() external {
        testDuration = ethRegistrar.MIN_REGISTER_DURATION() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IETHRegistrar.DurationTooShort.selector,
                testDuration,
                ethRegistrar.MIN_REGISTER_DURATION()
            )
        );
        this._register();
    }

    function test_register_nullOwner() external {
        testOwner = address(0); // aka reserve()
        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        this._register();
    }

    function test_register_registered() external {
        this._register();
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.NameNotAvailable.selector, testLabel));
        this._register();
    }

    function test_register_reserved() external {
        _reserve();
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.NameNotAvailable.selector, testLabel));
        this._register();
    }

    function test_renew() external {
        uint256 tokenId = this._register();
        uint64 expiry0 = ethRegistry.getExpiry(tokenId);
        (uint256 base, ) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        vm.expectEmit();
        emit IETHRegistrar.NameRenewed(
            LibLabel.withVersion(LibLabel.id(testLabel), 0),
            testLabel,
            testDuration,
            expiry0 + testDuration,
            testPaymentToken,
            testReferrer,
            base
        );
        this._renew();
        assertEq(ethRegistry.getExpiry(tokenId), expiry0 + testDuration);
    }

    function test_renew_reserved() external {
        _reserve();
        this._renew();
    }

    function test_renew_available() external {
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.NameIsAvailable.selector, testLabel));
        this._renew();
    }

    function test_renew_expired() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId));
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.NameIsAvailable.selector, testLabel));
        this._renew();
    }

    function test_renew_0duration() external {
        this._register();
        testDuration = 0;
        vm.expectRevert(abi.encodeWithSelector(IRentPriceOracle.NotValid.selector, testLabel));
        this._renew();
    }

    function test_renew_insufficientAllowance() external {
        this._register();
        vm.prank(testSender);
        tokenUSDC.approve(address(ethRegistrar), 0);
        (uint256 base, ) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(ethRegistrar),
                0,
                base
            )
        );
        this._renew();
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(address(ethRegistrar), type(IETHRegistrar).interfaceId),
            "IETHRegistrar"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(ethRegistrar),
                type(IRentPriceOracle).interfaceId
            ),
            "IRentPriceOracle"
        );
    }

    function test_beneficiary_register() external {
        (uint256 base, ) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        uint256 balance0 = testPaymentToken.balanceOf(beneficiary);
        this._register();
        assertEq(testPaymentToken.balanceOf(beneficiary), balance0 + base);
    }

    function test_beneficiary_renew() external {
        this._register();
        uint256 balance0 = testPaymentToken.balanceOf(beneficiary);
        (uint256 base, ) = ethRegistrar.rentPrice(
            testLabel,
            testOwner,
            testDuration,
            testPaymentToken
        );
        this._renew();
        assertEq(testPaymentToken.balanceOf(beneficiary), balance0 + base);
    }

    function test_registry_bitmap() external {
        uint256 tokenId = this._register();
        assertTrue(ethRegistry.hasRoles(tokenId, REGISTRATION_ROLE_BITMAP, testOwner));
    }

    function test_blacklist_user() external {
        tokenBlack.setBlacklisted(user, true);
        vm.expectRevert(abi.encodeWithSelector(MockERC20Blacklist.Blacklisted.selector, user));
        testPaymentToken = tokenBlack;
        this._register();
        testPaymentToken = tokenUSDC;
        this._register();
    }

    function test_blacklist_beneficiary() external {
        tokenBlack.setBlacklisted(ethRegistrar.BENEFICIARY(), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC20Blacklist.Blacklisted.selector,
                ethRegistrar.BENEFICIARY()
            )
        );
        testPaymentToken = tokenBlack;
        this._register();
        testPaymentToken = tokenUSDC;
        this._register();
    }

    function test_registered_name_has_transfer_role() external {
        uint256 tokenId = this._register();

        assertTrue(
            ethRegistry.hasRoles(tokenId, RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN, testOwner),
            "Registered name owner should have ROLE_CAN_TRANSFER"
        );
    }

    function test_registered_name_can_be_transferred() external {
        uint256 tokenId = this._register();
        address newOwner = makeAddr("newOwner");

        vm.prank(testOwner);
        ethRegistry.safeTransferFrom(testOwner, newOwner, tokenId, 1, "");

        assertEq(
            ethRegistry.ownerOf(tokenId),
            newOwner,
            "Token should be transferred to new owner"
        );
    }

    function test_voidReturn_acceptedBySafeERC20() public {
        testPaymentToken = tokenVoid;
        this._register();
    }

    function test_falseReturn_rejectedBySafeERC20() public {
        testPaymentToken = tokenFalse;
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, tokenFalse)
        );
        this._register();
    }
}
