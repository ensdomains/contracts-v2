// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {
    IERC20Errors
} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    SafeERC20,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ERC165Checker
} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IEnhancedAccessControl} from "~src/registry/PermissionedRegistry.sol";
import {IRegistryEvents} from "~src/registry/interfaces/IRegistryEvents.sol";
import {
    ETHRegistrar,
    IETHRegistrar,
    INameRegistrar,
    INameRenewer,
    IRegistry,
    IPermissionedRegistry,
    RegistryRolesLib,
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
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";
import {
    StandardRentPriceOracleFixture,
    StandardPricing
} from "~test/fixtures/StandardRentPriceOracleFixture.sol";

contract ETHRegistrarTest is V2Fixture, StandardRentPriceOracleFixture {
    ETHRegistrar ethRegistrar;

    string testLabel = "testname";
    address testOwner = makeAddr("owner");
    address testSender = testOwner;
    IRegistry testRegistry = IRegistry(makeAddr("registry"));
    address testResolver = makeAddr("resolver");
    address testPaymentToken; //|
    bytes32 testSecret; ////////|
    bytes32 testReferrer; //////| set below
    uint64 testDuration; ///////|
    uint64 testCommitDelay; ////|

    function setUp() external {
        deployV2Fixture();
        deployStandardRentPriceOracleFixture(ethRegistry);

        setupPaymentTokens(testOwner);

        ethRegistrar = new ETHRegistrar(
            hcaFactory,
            ethRegistry,
            StandardPricing.MIN_COMMITMENT_AGE,
            StandardPricing.MAX_COMMITMENT_AGE,
            StandardPricing.GRACE_PERIOD,
            rentPriceOracle
        );
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(ethRegistrar)
        );

        testPaymentToken = address(tokenUSDC);
        testSecret = bytes32(vm.randomUint());
        testReferrer = bytes32(vm.randomUint());
        testDuration = rentPriceOracle.minRegisterDuration();
        testCommitDelay = ethRegistrar.MIN_COMMITMENT_AGE();

        vm.warp(ethRegistrar.GRACE_PERIOD() + rentPriceOracle.premiumPeriod()); // avoid timestamp issues
    }

    function test_constructor() external view {
        assertEq(
            address(ethRegistrar.ETH_REGISTRY()),
            address(ethRegistry),
            "ETH_REGISTRY"
        );
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
            ethRegistrar.GRACE_PERIOD(),
            StandardPricing.GRACE_PERIOD,
            "GRACE_PERIOD"
        );

        assertEq(
            address(ethRegistrar.rentPriceOracle()),
            address(rentPriceOracle),
            "rentPriceOracle"
        );
    }

    function test_constructor_emptyRange() external {
        vm.expectRevert(
            abi.encodeWithSelector(ETHRegistrar.MaxCommitmentAgeTooLow.selector)
        );
        new ETHRegistrar(
            hcaFactory,
            ethRegistry,
            1, // minCommitmentAge
            1, // maxCommitmentAge
            0, // gracePeriod
            rentPriceOracle
        );
    }

    function test_constructor_invalidRange() external {
        vm.expectRevert(
            abi.encodeWithSelector(ETHRegistrar.MaxCommitmentAgeTooLow.selector)
        );
        new ETHRegistrar(
            hcaFactory,
            ethRegistry,
            1, // minCommitmentAge
            0, // maxCommitmentAge
            0, // gracePeriod
            rentPriceOracle
        );
    }

    function test_setRentPriceOracle() external {
        IRentPriceOracle oracle = IRentPriceOracle(makeAddr("oracle"));
        vm.expectEmit();
        emit ETHRegistrar.RentPriceOracleUpdated(oracle);
        ethRegistrar.setRentPriceOracle(oracle);
        assertEq(address(ethRegistrar.rentPriceOracle()), address(oracle));
    }

    function test_setRentPriceOracle_notAuthorized() external {
        address actor = makeAddr("actor");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                ethRegistry.ROOT_RESOURCE(),
                ROLE_SET_ORACLE,
                actor
            )
        );
        vm.prank(actor);
        ethRegistrar.setRentPriceOracle(IRentPriceOracle(address(1)));
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
        emit INameRegistrar.CommitmentMade(commitment);
        ethRegistrar.commit(commitment);
        assertEq(
            ethRegistrar.commitmentAt(commitment),
            block.timestamp,
            "time"
        );
    }

    function test_commitmentAt() external {
        bytes32 commitment = bytes32(uint256(1));
        assertEq(ethRegistrar.commitmentAt(commitment), 0, "before");
        ethRegistrar.commit(commitment);
        assertEq(
            ethRegistrar.commitmentAt(commitment),
            block.timestamp,
            "after"
        );
    }

    function test_commit_unexpiredCommitment() external {
        bytes32 commitment = bytes32(uint256(1));
        ethRegistrar.commit(commitment);
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRegistrar.UnexpiredCommitmentExists.selector,
                commitment
            )
        );
        ethRegistrar.commit(commitment);
    }

    function test_isAvailable() external {
        assertTrue(ethRegistrar.isAvailable(testLabel));
        this._register();
        assertFalse(ethRegistrar.isAvailable(testLabel));
    }

    function test_register(uint32 t) external {
        vm.assume(t >= rentPriceOracle.minRegisterDuration());
        testDuration = t;
        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            testLabel,
            type(uint64).max,
            testDuration,
            testPaymentToken
        );
        uint256 labelId = LibLabel.id(testLabel);
        uint256 tokenId = LibLabel.withVersion(labelId, 0);
        uint64 expiry = uint64(block.timestamp) +
            testCommitDelay +
            testDuration;
        vm.expectEmit();
        emit IRegistryEvents.LabelRegistered(
            tokenId,
            bytes32(labelId),
            testLabel,
            testOwner,
            expiry,
            address(ethRegistrar)
        );
        vm.expectEmit();
        emit INameRegistrar.NameRegistered(
            tokenId,
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
        assertEq(this._register(), tokenId, "token");
        assertEq(ethRegistry.ownerOf(tokenId), testOwner, "owner");
        assertEq(ethRegistry.getExpiry(tokenId), expiry, "expiry");
        assertTrue(
            ethRegistry.hasRoles(tokenId, REGISTRATION_ROLE_BITMAP, testOwner),
            "roles"
        );
        assertFalse(ethRegistrar.isAvailable(testLabel), "available");
    }

    function test_register_whileRegistered(uint32 t) external {
        vm.assume(t < testDuration);
        uint256 tokenId = this._register();
        vm.warp(block.timestamp + t);
        assertEq(
            uint8(ethRegistry.getStatus(tokenId)),
            uint8(IPermissionedRegistry.Status.REGISTERED),
            "status"
        );
        assertFalse(ethRegistrar.isAvailable(testLabel), "available");
        assertEq(ethRegistrar.getRemainingGracePeriod(testLabel), 0, "remaining");
    }

    function test_register_duringGrace(uint32 t) external {
        vm.assume(t < ethRegistrar.GRACE_PERIOD());
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + t);
        assertEq(
            uint8(ethRegistry.getStatus(tokenId)),
            uint8(IPermissionedRegistry.Status.AVAILABLE),
            "status"
        );
        assertFalse(ethRegistrar.isAvailable(testLabel), "available");
        assertEq(
            ethRegistrar.getRemainingGracePeriod(testLabel),
            ethRegistrar.GRACE_PERIOD() - t,
            "remaining"
        );
    }

    function test_register_afterGrace() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + ethRegistrar.GRACE_PERIOD());
        assertEq(
            uint8(ethRegistry.getStatus(tokenId)),
            uint8(IPermissionedRegistry.Status.AVAILABLE),
            "status"
        );
        assertTrue(ethRegistrar.isAvailable(testLabel), "available");
        assertEq(ethRegistrar.getRemainingGracePeriod(testLabel), 0, "remaining");

        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            testLabel,
            testCommitDelay, // due to commit-reveal
            testDuration,
            testPaymentToken
        );
        uint256 balance0 = IERC20(testPaymentToken).balanceOf(testOwner);
        this._register();
        assertEq(
            balance0 - base - premium,
            IERC20(testPaymentToken).balanceOf(testOwner),
            "balance"
        );
    }

    function test_register_afterPremium() external {
        uint256 tokenId = this._register();
        vm.warp(
            ethRegistry.getExpiry(tokenId) +
                ethRegistrar.GRACE_PERIOD() +
                rentPriceOracle.premiumPeriod()
        );

        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            testLabel,
            type(uint64).max,
            testDuration,
            testPaymentToken
        );
        uint256 balance0 = IERC20(testPaymentToken).balanceOf(testOwner);
        this._register();
        assertEq(
            balance0 - base - premium,
            IERC20(testPaymentToken).balanceOf(testOwner),
            "balance"
        );
        assertEq(premium, 0, "premium");
    }

    function test_register_insufficientAllowance() external {
        vm.prank(testSender);
        tokenUSDC.approve(address(rentPriceOracle), 0);
        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            testLabel,
            type(uint64).max,
            testDuration,
            testPaymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(rentPriceOracle), // spender
                0, // allowance
                base + premium // needed
            )
        );
        this._register();
    }

    function test_register_insufficientBalance() external {
        tokenUSDC.nuke(testSender);
        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            testLabel,
            type(uint64).max,
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
        uint64 dt = 1;
        testCommitDelay = ethRegistrar.MIN_COMMITMENT_AGE() - dt;
        uint256 t = block.timestamp + testCommitDelay;
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRegistrar.CommitmentTooNew.selector,
                _makeCommitment(),
                t + dt,
                t
            )
        );
        this._register();
    }

    function test_register_commitmentTooOld() external {
        uint64 dt = 1;
        testCommitDelay = ethRegistrar.MAX_COMMITMENT_AGE() + dt;
        uint256 t = block.timestamp + testCommitDelay;
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRegistrar.CommitmentTooOld.selector,
                _makeCommitment(),
                t - dt,
                t
            )
        );
        this._register();
    }

    function test_register_durationTooShort() external {
        testDuration = rentPriceOracle.minRegisterDuration() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.DurationTooShort.selector,
                testDuration,
                rentPriceOracle.minRegisterDuration()
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
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRegistrar.NameNotAvailable.selector,
                testLabel
            )
        );
        this._register();
    }

    function test_register_reserved() external {
        _reserve();
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRegistrar.NameNotAvailable.selector,
                testLabel
            )
        );
        this._register();
    }

    function test_renew(uint32 t) external {
        vm.assume(t >= minRenewDuration);
        uint256 tokenId = this._register();
        testDuration = t;
        uint64 expiry0 = ethRegistry.getExpiry(tokenId);
        uint64 expiry1 = expiry0 + testDuration;
        uint256 amount = ethRegistrar.getRenewPrice(
            testLabel,
            testDuration,
            testPaymentToken
        );
        vm.expectEmit();
        emit INameRenewer.NameRenewed(
            LibLabel.withVersion(LibLabel.id(testLabel), 0),
            testLabel,
            testDuration,
            expiry1,
            testPaymentToken,
            testReferrer,
            amount
        );
        this._renew();
        assertEq(ethRegistry.getExpiry(tokenId), expiry1);
    }

    function test_renew_reserved() external {
        _reserve();
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRenewer.NameNotRenewable.selector,
                testLabel
            )
        );
        this._renew();
    }

    function test_renew_available() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRenewer.NameNotRenewable.selector,
                testLabel
            )
        );
        this._renew();
    }

    function test_renew_duringGrace(uint32 t) external {
        vm.assume(t < ethRegistrar.GRACE_PERIOD());
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + t);
        this._renew();
    }

    function test_renew_afterGrace() external {
        uint256 tokenId = this._register();
        vm.warp(ethRegistry.getExpiry(tokenId) + ethRegistrar.GRACE_PERIOD());
        vm.expectRevert(
            abi.encodeWithSelector(
                INameRenewer.NameNotRenewable.selector,
                testLabel
            )
        );
        this._renew();
    }

    function test_renew_durationTooShort() external {
        this._register();
        testDuration = minRenewDuration - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRentPriceOracle.DurationTooShort.selector,
                testDuration,
                1
            )
        );
        this._renew();
    }

    function test_renew_insufficientAllowance() external {
        this._register();
        vm.prank(testSender);
        tokenUSDC.approve(address(rentPriceOracle), 0);
        uint256 amount = ethRegistrar.getRenewPrice(
            testLabel,
            testDuration,
            testPaymentToken
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(rentPriceOracle),
                0,
                amount
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
                type(INameRegistrar).interfaceId
            ),
            "INameRegistrar"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(ethRegistrar),
                type(INameRenewer).interfaceId
            ),
            "INameRenewer"
        );
    }

    function test_beneficiary_register() external {
        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            testLabel,
            type(uint64).max,
            testDuration,
            testPaymentToken
        );
        uint256 balance0 = IERC20(testPaymentToken).balanceOf(beneficiary);
        this._register();
        assertEq(
            IERC20(testPaymentToken).balanceOf(beneficiary),
            balance0 + base + premium
        );
    }

    function test_beneficiary_renew() external {
        this._register();
        uint256 amount = ethRegistrar.getRenewPrice(
            testLabel,
            testDuration,
            testPaymentToken
        );
        uint256 balance0 = IERC20(testPaymentToken).balanceOf(beneficiary);
        this._renew();
        assertEq(
            IERC20(testPaymentToken).balanceOf(beneficiary),
            balance0 + amount
        );
    }

    function test_register_bitmap() external {
        uint256 tokenId = this._register();
        assertTrue(
            ethRegistry.hasRoles(tokenId, REGISTRATION_ROLE_BITMAP, testOwner)
        );
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
        ethRegistrar.renew(
            testLabel,
            testDuration,
            testPaymentToken,
            testReferrer
        );
    }

    function _reserve() internal {
        ethRegistry.register(
            testLabel,
            address(0),
            IRegistry(address(0)),
            address(0),
            0,
            uint64(block.timestamp) + testDuration
        );
    }
}
