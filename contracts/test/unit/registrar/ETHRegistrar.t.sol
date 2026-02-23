// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {StandardPricing} from "./StandardPricing.sol";

import {
    IEnhancedAccessControl,
    EACBaseRolesLib
} from "~src/access-control/EnhancedAccessControl.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {SimpleRegistryMetadata} from "~src/registry/SimpleRegistryMetadata.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {InvalidOwner} from "~src/CommonErrors.sol";
import {
    ETHRegistrar,
    IETHRegistrar,
    IRegistry,
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

    function test_Revert_constructor_emptyRange() external {
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

    function test_Revert_constructor_invalidRange() external {
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

    function test_Revert_setRentPriceOracle() external {
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
                uint256(0),
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

    struct RegisterArgs {
        address sender;
        string label;
        address owner;
        bytes32 secret;
        IRegistry subregistry;
        address resolver;
        uint64 duration;
        IERC20 paymentToken;
        bytes32 referrer;
        uint256 wait;
    }

    function _defaultRegisterArgs() internal view returns (RegisterArgs memory args) {
        args.label = "testname";
        args.sender = user;
        args.owner = user;
        args.paymentToken = tokenUSDC;
        args.duration = ethRegistrar.MIN_REGISTER_DURATION();
        args.wait = ethRegistrar.MIN_COMMITMENT_AGE() + 1;
    }

    function _makeCommitment(RegisterArgs memory args) internal view returns (bytes32) {
        return
            ethRegistrar.makeCommitment(
                args.label,
                args.owner,
                args.secret,
                args.subregistry,
                args.resolver,
                args.duration,
                args.referrer
            );
    }

    function _register(RegisterArgs memory args) external returns (uint256 tokenId) {
        bytes32 commitment = _makeCommitment(args);
        vm.startPrank(args.sender);
        ethRegistrar.commit(commitment);
        vm.warp(block.timestamp + args.wait);
        tokenId = ethRegistrar.register(
            args.label,
            args.owner,
            args.secret,
            args.subregistry,
            args.resolver,
            args.duration,
            args.paymentToken,
            args.referrer
        );
        vm.stopPrank();
    }

    function _renew(RegisterArgs memory args) external {
        vm.prank(args.sender);
        ethRegistrar.renew(args.label, args.duration, args.paymentToken, args.referrer);
    }

    function test_commit() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        bytes32 commitment = _makeCommitment(args);
        assertEq(
            commitment,
            keccak256(
                abi.encode(
                    args.label,
                    args.owner,
                    args.secret,
                    args.subregistry,
                    args.resolver,
                    args.duration,
                    args.referrer
                )
            ),
            "hash"
        );
        vm.expectEmit(false, false, false, false);
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

    function test_Revert_commit_unexpiredCommitment() external {
        bytes32 commitment = bytes32(uint256(1));
        ethRegistrar.commit(commitment);
        vm.expectRevert(
            abi.encodeWithSelector(IETHRegistrar.UnexpiredCommitmentExists.selector, commitment)
        );
        ethRegistrar.commit(commitment);
    }

    function test_isAvailable() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        assertTrue(ethRegistrar.isAvailable(args.label), "before");
        this._register(args);
        assertFalse(ethRegistrar.isAvailable(args.label), "after");
    }

    function test_register() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        vm.expectEmit(false, false, false, false);
        bytes32 topic = IETHRegistrar.NameRegistered.selector;
        assembly {
            log2(0, 0, topic, 0)
        }
        uint256 tokenId = this._register(args);
        assertEq(ethRegistry.ownerOf(tokenId), args.owner, "owner");
        assertEq(ethRegistry.getExpiry(tokenId), uint64(block.timestamp) + args.duration, "expiry");
    }

    function test_register_premium_start() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 tokenId = this._register(args);
        uint64 expiry = ethRegistry.getExpiry(tokenId);
        vm.warp(expiry);
        assertEq(rentPriceOracle.premiumPrice(expiry), rentPriceOracle.premiumPriceAfter(0));
    }

    function test_register_premium_end() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 tokenId = this._register(args);
        uint64 expiry = ethRegistry.getExpiry(tokenId);
        vm.warp(expiry + rentPriceOracle.premiumPeriod());
        assertEq(rentPriceOracle.premiumPrice(expiry), 0);
    }

    function test_register_premium_latestOwner() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        this._register(args);
        vm.warp(block.timestamp + args.duration);
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            args.label,
            args.owner,
            args.duration,
            args.paymentToken
        );
        assertEq(premium, 0, "premium");
        uint256 balance0 = args.paymentToken.balanceOf(args.owner);
        this._register(args);
        assertEq(balance0 - base, args.paymentToken.balanceOf(args.owner), "balance");
    }

    function test_Revert_register_insufficientAllowance() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        vm.prank(args.sender);
        tokenUSDC.approve(address(ethRegistrar), 0);
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            args.label,
            args.owner,
            args.duration,
            args.paymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(ethRegistrar), // spender
                0, // allowance
                base + premium // needed
            )
        );
        this._register(args);
    }

    function test_Revert_register_insufficientBalance() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        tokenUSDC.nuke(args.sender);
        (uint256 base, uint256 premium) = ethRegistrar.rentPrice(
            args.label,
            args.owner,
            args.duration,
            args.paymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                args.sender, // sender
                0, // allowance
                base + premium // needed
            )
        );
        this._register(args);
    }

    function test_Revert_register_commitmentTooNew() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 dt = 1;
        args.wait = ethRegistrar.MIN_COMMITMENT_AGE() - dt;
        uint256 t = block.timestamp + args.wait;
        vm.expectRevert(
            abi.encodeWithSelector(
                IETHRegistrar.CommitmentTooNew.selector,
                _makeCommitment(args),
                t + dt,
                t
            )
        );
        this._register(args);
    }

    function test_Revert_register_commitmentTooOld() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 dt = 1;
        args.wait = ethRegistrar.MAX_COMMITMENT_AGE() + dt;
        uint256 t = block.timestamp + args.wait;
        vm.expectRevert(
            abi.encodeWithSelector(
                IETHRegistrar.CommitmentTooOld.selector,
                _makeCommitment(args),
                t - dt,
                t
            )
        );
        this._register(args);
    }

    function test_Revert_register_nameNotAvailable() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        this._register(args);
        vm.expectRevert(
            abi.encodeWithSelector(IETHRegistrar.NameAlreadyRegistered.selector, args.label)
        );
        this._register(args);
    }

    function test_Revert_register_durationTooShort() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        args.duration = ethRegistrar.MIN_REGISTER_DURATION() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IETHRegistrar.DurationTooShort.selector,
                args.duration,
                ethRegistrar.MIN_REGISTER_DURATION()
            )
        );
        this._register(args);
    }

    function test_Revert_register_nullOwner() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        args.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector, args.owner));
        this._register(args);
    }

    function test_renew() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 tokenId = this._register(args);
        uint256 expiry0 = ethRegistry.getExpiry(tokenId);
        vm.expectEmit(false, false, false, false);
        bytes32 topic = IETHRegistrar.NameRenewed.selector;
        assembly {
            log2(0, 0, topic, 0)
        }
        this._renew(args);
        assertEq(ethRegistry.getExpiry(tokenId), expiry0 + args.duration);
    }

    function test_Revert_renew_nameNotRegistered() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        vm.expectRevert(
            abi.encodeWithSelector(IETHRegistrar.NameNotRegistered.selector, args.label)
        );
        this._renew(args);
    }

    function test_Revert_renew_0duration() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        this._register(args);
        args.duration = 0;
        vm.expectRevert(abi.encodeWithSelector(IRentPriceOracle.NotValid.selector, args.label));
        this._renew(args);
    }

    function test_Revert_renew_insufficientAllowance() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        this._register(args);
        vm.prank(args.sender);
        tokenUSDC.approve(address(ethRegistrar), 0);
        (uint256 base, ) = ethRegistrar.rentPrice(
            args.label,
            args.owner,
            args.duration,
            args.paymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(ethRegistrar),
                0,
                base
            )
        );
        this._renew(args);
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
        RegisterArgs memory args = _defaultRegisterArgs();
        (uint256 base, ) = ethRegistrar.rentPrice(
            args.label,
            args.owner,
            args.duration,
            args.paymentToken
        );
        uint256 balance0 = args.paymentToken.balanceOf(beneficiary);
        this._register(args);
        assertEq(args.paymentToken.balanceOf(beneficiary), balance0 + base);
    }

    function test_beneficiary_renew() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        this._register(args);
        uint256 balance0 = args.paymentToken.balanceOf(beneficiary);
        (uint256 base, ) = ethRegistrar.rentPrice(
            args.label,
            args.owner,
            args.duration,
            args.paymentToken
        );
        this._renew(args);
        assertEq(args.paymentToken.balanceOf(beneficiary), balance0 + base);
    }

    function test_registry_bitmap() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 tokenId = this._register(args);
        assertTrue(
            ethRegistry.hasRoles(
                LibLabel.getCanonicalId(tokenId),
                REGISTRATION_ROLE_BITMAP,
                args.owner
            )
        );
    }

    function test_blacklist_user() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        tokenBlack.setBlacklisted(user, true);
        vm.expectRevert(abi.encodeWithSelector(MockERC20Blacklist.Blacklisted.selector, user));
        args.paymentToken = tokenBlack;
        this._register(args);
        args.paymentToken = tokenUSDC;
        this._register(args);
    }

    function test_blacklist_beneficiary() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        tokenBlack.setBlacklisted(ethRegistrar.BENEFICIARY(), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC20Blacklist.Blacklisted.selector,
                ethRegistrar.BENEFICIARY()
            )
        );
        args.paymentToken = tokenBlack;
        this._register(args);
        args.paymentToken = tokenUSDC;
        this._register(args);
    }

    function test_registered_name_has_transfer_role() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 tokenId = this._register(args);

        assertTrue(
            ethRegistry.hasRoles(
                LibLabel.getCanonicalId(tokenId),
                RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN,
                args.owner
            ),
            "Registered name owner should have ROLE_CAN_TRANSFER"
        );
    }

    function test_registered_name_can_be_transferred() external {
        RegisterArgs memory args = _defaultRegisterArgs();
        uint256 tokenId = this._register(args);
        address newOwner = makeAddr("newOwner");

        vm.prank(args.owner);
        ethRegistry.safeTransferFrom(args.owner, newOwner, tokenId, 1, "");

        assertEq(
            ethRegistry.ownerOf(tokenId),
            newOwner,
            "Token should be transferred to new owner"
        );
    }

    function test_voidReturn_acceptedBySafeERC20() public {
        RegisterArgs memory args = _defaultRegisterArgs();
        args.paymentToken = tokenVoid;
        this._register(args);
    }

    function test_falseReturn_rejectedBySafeERC20() public {
        RegisterArgs memory args = _defaultRegisterArgs();
        args.paymentToken = tokenFalse;
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, tokenFalse)
        );
        this._register(args);
    }
}
