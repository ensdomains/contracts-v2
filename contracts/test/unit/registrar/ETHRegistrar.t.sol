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
    IPaymentTokenOracle,
    IPermissionedRegistry,
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
    MockERC20 tokenIdentity;
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

        tokenUSDC = new MockERC20("USDC", 6);
        tokenDAI = new MockERC20("DAI", 18);
        tokenIdentity = new MockERC20("ID", StandardPricing.PRICE_DECIMALS);
        tokenBlack = new MockERC20Blacklist();
        tokenVoid = new MockERC20VoidReturn();
        tokenFalse = new MockERC20FalseReturn();

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](6);
        paymentRatios[0] = StandardPricing.ratioFromStable(tokenUSDC);
        paymentRatios[1] = StandardPricing.ratioFromStable(tokenDAI);
        paymentRatios[2] = StandardPricing.ratioFromStable(tokenIdentity);
        paymentRatios[3] = StandardPricing.ratioFromStable(tokenBlack);
        paymentRatios[4] = StandardPricing.ratioFromStable(tokenVoid);
        paymentRatios[5] = StandardPricing.ratioFromStable(tokenFalse);

        rentPriceOracle = new StandardRentPriceOracle(
            address(this),
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
            StandardPricing.MIN_RENEW_DURATION,
            StandardPricing.GRACE_PERIOD,
            rentPriceOracle
        );

        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(ethRegistrar)
        );

        for (uint256 i; i < paymentRatios.length; ++i) {
            MockERC20 token = MockERC20(address(paymentRatios[i].token));
            token.mint(user, 1e9 * 10 ** token.decimals());
            vm.prank(user);
            token.approve(address(ethRegistrar), type(uint256).max);
        }

        vm.warp(rentPriceOracle.premiumPeriod() + ethRegistrar.GRACE_PERIOD()); // avoid timestamp issues

        testPaymentToken = tokenUSDC;
        testSecret = bytes32(vm.randomUint());
        testReferrer = bytes32(vm.randomUint());
        testDuration = StandardPricing.SEC_PER_YEAR;
        testCommitDelay = ethRegistrar.MIN_COMMITMENT_AGE();
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
        assertEq(ethRegistrar.GRACE_PERIOD(), StandardPricing.GRACE_PERIOD, "GRACE_PERIOD");
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
            0,
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
            0,
            0,
            rentPriceOracle
        );
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(address(ethRegistrar), type(IETHRegistrar).interfaceId),
            "IETHRegistrar"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(ethRegistrar),
                type(IPaymentTokenOracle).interfaceId
            ),
            "IPaymentTokenOracle"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // setRentPriceOracle()
    ////////////////////////////////////////////////////////////////////////

    function test_setRentPriceOracle() external {
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio(tokenUSDC, 1, 1);
        uint256[] memory baseRates = new uint256[](2);
        baseRates[0] = 1;
        baseRates[1] = 0;
        StandardRentPriceOracle oracle = new StandardRentPriceOracle(
            address(this),
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
        uint64 dur = ethRegistrar.MIN_REGISTER_DURATION();
        (, , uint256 base, uint256 premium) = ethRegistrar.rentPrice("a", dur, tokenUSDC);
        assertEq(base, dur, "rent"); // dur * 10^x / 10^x = dur
        assertEq(premium, 0, "premium"); // disabled
    }

    function test_setRentPriceOracle_notAuthorized() external {
        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio(tokenUSDC, 1, 1);
        StandardRentPriceOracle oracle = new StandardRentPriceOracle(
            address(this),
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

    ////////////////////////////////////////////////////////////////////////
    // Commitments
    ////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////
    // Getters
    ////////////////////////////////////////////////////////////////////////

    function test_isPaymentToken() external view {
        assertTrue(rentPriceOracle.isPaymentToken(tokenUSDC), "USDC");
        assertTrue(rentPriceOracle.isPaymentToken(tokenDAI), "DAI");
        assertTrue(rentPriceOracle.isPaymentToken(tokenBlack), "Black");
        assertTrue(rentPriceOracle.isPaymentToken(tokenVoid), "Void");
        assertTrue(rentPriceOracle.isPaymentToken(tokenFalse), "False");
        assertFalse(rentPriceOracle.isPaymentToken(IERC20(address(0))));
    }

    function test_isValid() external view {
        assertFalse(ethRegistrar.isValid(""));
        assertEq(ethRegistrar.isValid("a"), StandardPricing.RATE_1CP > 0);
        assertEq(ethRegistrar.isValid("ab"), StandardPricing.RATE_2CP > 0);
        assertEq(ethRegistrar.isValid("abc"), StandardPricing.RATE_3CP > 0);
        assertEq(ethRegistrar.isValid("abce"), StandardPricing.RATE_4CP > 0);
        assertEq(ethRegistrar.isValid("abcde"), StandardPricing.RATE_5CP > 0);
        assertEq(ethRegistrar.isValid("abcdefghijklmnopqrstuvwxyz"), StandardPricing.RATE_5CP > 0);
    }

    function test_isAvailable() external {
        assertTrue(ethRegistrar.isAvailable(testLabel), "before");
        this._register();
        assertFalse(ethRegistrar.isAvailable(testLabel), "after");
    }

    ////////////////////////////////////////////////////////////////////////
    // register()
    ////////////////////////////////////////////////////////////////////////

    function test_register() external {
        uint256 total = testPaymentToken.balanceOf(testOwner);
        (, , uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
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
        total -= testPaymentToken.balanceOf(testOwner);
        assertEq(ethRegistry.ownerOf(tokenId), testOwner, "owner");
        assertTrue(ethRegistry.hasRoles(tokenId, REGISTRATION_ROLE_BITMAP, testOwner), "roles");
        assertEq(ethRegistry.getExpiry(tokenId), uint64(block.timestamp) + testDuration, "expiry");
        assertEq(premium, 0, "premium");
        assertEq(base, total, "total");
    }

    function _testGraceAt(uint64 dt) internal {
        // register and warp to dt after expiry
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + dt);

        // registry is available for any time after expiry
        assertEq(
            uint8(ethRegistry.getStatus(tokenId)),
            uint8(IPermissionedRegistry.Status.AVAILABLE)
        );

        // registrar is available for any time after grace
        bool available = dt >= ethRegistrar.GRACE_PERIOD();
        assertEq(ethRegistrar.isAvailable(testLabel), available);

        // should be non-zero during grace
        assertEq(
            ethRegistrar.getRemainingGracePeriod(testLabel),
            available ? 0 : ethRegistrar.GRACE_PERIOD() - dt
        );
    }

    function test_register_grace(uint64 t) external {
        vm.assume(t < ethRegistrar.GRACE_PERIOD() * 2);
        _testGraceAt(t);
    }
    function test_register_graceStart() external {
        _testGraceAt(0);
    }
    function test_register_graceEnd() external {
        _testGraceAt(ethRegistrar.GRACE_PERIOD());
    }

    function _testPremiumAt(uint64 dt) internal {
        // register and warp to dt after grace
        // (account for minimal commit-reveal delay)
        uint256 tokenId = this._register();
        vm.warp(
            ethRegistry.getExpiry(tokenId) + ethRegistrar.GRACE_PERIOD() + dt - testCommitDelay
        );

        // register again (using identity token for unit versions)
        testPaymentToken = tokenIdentity;
        uint256 total = testPaymentToken.balanceOf(testOwner);
        tokenId = this._register();
        total -= testPaymentToken.balanceOf(testOwner);

        // check against to oracle
        (uint256 base, uint256 premium) = rentPriceOracle.registerPrice(
            testLabel,
            dt,
            testDuration,
            testPaymentToken
        );
        assertEq(premium, rentPriceOracle.premiumPriceAfter(dt), "premium");
        assertEq(base + premium, total, "total");
    }

    function test_register_premiumStart() external {
        _testPremiumAt(0);
    }
    function test_register_premiumEnd() external {
        _testPremiumAt(rentPriceOracle.premiumPeriod());
    }
    function test_register_premium(uint64 t) external {
        vm.assume(t < 2 * rentPriceOracle.premiumPeriod());
        _testPremiumAt(t);
    }

    function test_register_insufficientAllowance() external {
        vm.prank(testSender);
        tokenUSDC.approve(address(ethRegistrar), 0); // wrong
        (, , uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
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
        tokenUSDC.nuke(testSender); // wrong
        (, , uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            testLabel,
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

    function test_register_alreadyRegistered() external {
        this._register();
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.CannotRegister.selector, testLabel));
        this._register();
    }

    function test_register_alreadyReserved() external {
        _reserve();
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.CannotRegister.selector, testLabel));
        this._register();
    }

    ////////////////////////////////////////////////////////////////////////
    // renew()
    ////////////////////////////////////////////////////////////////////////

    function test_renew() external {
        uint256 tokenId = this._register();
        IPermissionedRegistry.State memory state = ethRegistry.getState(tokenId);
        uint256 total = testPaymentToken.balanceOf(testOwner);
        (, , uint256 base, ) = ethRegistrar.rentPrice(testLabel, testDuration, testPaymentToken);
        vm.expectEmit();
        emit IETHRegistrar.NameRenewed(
            LibLabel.withVersion(LibLabel.id(testLabel), 0),
            testLabel,
            testDuration,
            state.expiry + testDuration,
            testPaymentToken,
            testReferrer,
            base
        );
        this._renew();
        total -= testPaymentToken.balanceOf(testOwner);
        assertEq(ethRegistry.getExpiry(tokenId), state.expiry + testDuration, "expiry");
        assertEq(base, total, "total");
    }

    function test_renew_alreadyReserved() external {
        _reserve();
        this._renew();
    }

    function test_renew_available() external {
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.CannotRenew.selector, testLabel));
        this._renew();
    }

    function test_renew_expired_graceStart() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId));
        this._renew();
    }

    function test_renew_expired_beforeGraceEnd() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + ethRegistrar.GRACE_PERIOD() - 1);
        this._renew();
    }

    function test_renew_expired_beforeGraceEnd_stillGrace() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + ethRegistrar.GRACE_PERIOD() - 1);
        assertTrue(ethRegistrar.getRemainingGracePeriod(testLabel) > 0);
        testDuration = ethRegistrar.MIN_RENEW_DURATION();
        this._renew();
        assertTrue(ethRegistrar.getRemainingGracePeriod(testLabel) > 0);
    }

    function test_renew_expired_graceEnd() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + ethRegistrar.GRACE_PERIOD());
        vm.expectRevert(abi.encodeWithSelector(IETHRegistrar.CannotRenew.selector, testLabel));
        this._renew();
    }

    function test_renew_durationTooShort() external {
        uint64 min = ethRegistrar.MIN_RENEW_DURATION();
        this._register();
        testDuration = min - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IETHRegistrar.DurationTooShort.selector, testDuration, min)
        );
        this._renew();
    }

    function test_renew_insufficientAllowance() external {
        this._register();
        vm.prank(testSender);
        tokenUSDC.approve(address(ethRegistrar), 0); // wrong
        (, , uint256 base, ) = ethRegistrar.rentPrice(testLabel, testDuration, testPaymentToken);
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

    function test_renew_insufficientBalance() external {
        this._register();
        tokenUSDC.nuke(testSender); // wrong
        (, , uint256 base, ) = ethRegistrar.rentPrice(testLabel, testDuration, testPaymentToken);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                testSender, // sender
                0, // allowance
                base // needed
            )
        );
        this._renew();
    }

    ////////////////////////////////////////////////////////////////////////
    // Beneficiary
    ////////////////////////////////////////////////////////////////////////

    function test_beneficiary_register() external {
        uint256 loss = testPaymentToken.balanceOf(testOwner);
        uint256 gain = testPaymentToken.balanceOf(beneficiary);
        this._register();
        gain = testPaymentToken.balanceOf(beneficiary) - gain;
        loss -= testPaymentToken.balanceOf(testOwner);
        assertEq(gain, loss);
    }

    function test_beneficiary_renew() external {
        this._register();
        uint256 loss = testPaymentToken.balanceOf(testOwner);
        uint256 gain = testPaymentToken.balanceOf(beneficiary);
        this._renew();
        gain = testPaymentToken.balanceOf(beneficiary) - gain;
        loss -= testPaymentToken.balanceOf(testOwner);
        assertEq(gain, loss);
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC-20 Quirks
    ////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

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
        vm.prank(testSender);
        ethRegistrar.commit(commitment);
        vm.warp(block.timestamp + testCommitDelay);
        vm.prank(testSender);
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
}
