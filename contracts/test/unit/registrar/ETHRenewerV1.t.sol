// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {console} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";

import {LibLabel} from "~src/utils/LibLabel.sol";
import {IRegistryEvents} from "~src/registry/interfaces/IRegistryEvents.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {IETHRenewer} from "~src/registrar/interfaces/IETHRenewer.sol";
import {ETHRenewerV1} from "~src/registrar/ETHRenewerV1.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {MockERC20} from "~test/mocks/MockERC20.sol";
import {StandardRegistrar} from "~test/StandardRegistrar.sol";

// [gas analysis]
// test_renew(): 56159
// test_syncWrapper_unwrapped(): 52572
// test_syncWrapper_wrapped():
//   N | Gas
//   0 | 36785
//   1 | 43289
//   2 | 47798
//   3 | 58807
//   4 | 69819
//   5 | 80833

contract ETHRenewerV1Test is MigrationControllerFixture, StandardRentPriceOracleFixture {
    ETHRenewerV1 ethRenewerV1;

    bytes32 testReferrer = keccak256("referrer");
    MockERC20 testPaymentToken;

    function setUp() external {
        deployMigrationControllerFixture();
        deployStandardRentPriceOracleFixture();

        ethRenewerV1 = new ETHRenewerV1(
            address(this),
            hcaFactory,
            ethRegistry,
            beneficiary,
            rentPriceOracle,
            StandardRegistrar.GRACE_PERIOD_V2,
            StandardRegistrar.BONUS_PERIOD,
            baseRegistrar,
            address(wrappedController)
        );

        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, address(ethRenewerV1));

        baseRegistrar.addController(address(ethRenewerV1));
        baseRegistrar.transferOwnership(address(ethRenewerV1));
        nameWrapper.renounceOwnership();

        setupPaymentTokens(testOwner, address(ethRenewerV1));
        testPaymentToken = tokenUSDC;
        testDuration = ethRenewerV1.MIN_RENEW_DURATION();

        assertEq(
            StandardRegistrar.GRACE_PERIOD_V2 + StandardRegistrar.BONUS_PERIOD,
            gracePeriodV1,
            "invariant: graceV2 + bonus == graceV1"
        );
    }

    function test_constructor() external view {
        assertEq(ethRenewerV1.GRACE_PERIOD(), gracePeriodV1, "GRACE_PERIOD");
        assertEq(address(ethRenewerV1.BASE_REGISTRAR()), address(baseRegistrar), "BASE_REGISTRAR");
        assertEq(
            address(ethRenewerV1.WRAPPED_CONTROLLER()),
            address(wrappedController),
            "WRAPPED_CONTROLLER"
        );
    }

    function test_transferRegistrarOwnership() external {
        ethRenewerV1.transferRegistrarOwnership(actor);
        assertEq(baseRegistrar.owner(), actor);
    }

    function test_transferRegistrarOwnership_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        vm.prank(actor);
        ethRenewerV1.transferRegistrarOwnership(actor);
    }

    ////////////////////////////////////////////////////////////////////////
    // renew()
    ////////////////////////////////////////////////////////////////////////

    function test_isRenewable_unregistered() external view {
        assertFalse(ethRenewerV1.isRenewable(testLabel));
    }

    function test_renew() external {
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        uint256 tokenId = LibLabel.withVersion(tokenIdV1, 0);
        uint64 newExpiry = ethRegistry.getExpiry(tokenId) + testDuration;
        uint256 amount = ethRenewerV1.getRenewPrice(testLabel, testDuration, testPaymentToken);
        vm.expectEmit();
        emit IRegistryEvents.ExpiryUpdated(tokenId, newExpiry, address(ethRenewerV1));
        vm.expectEmit();
        emit IBaseRegistrar.NameRenewed(tokenIdV1, newExpiry - premigrationBonusPeriod);
        vm.expectEmit();
        emit IETHRenewer.NameRenewed(
            tokenId,
            testLabel,
            testDuration,
            newExpiry,
            testPaymentToken,
            testReferrer,
            amount
        );
        vm.prank(testOwner);
        uint256 g = gasleft();
        ethRenewerV1.renew(testLabel, testDuration, testPaymentToken, testReferrer);
        g -= gasleft();
        console.log("Gas: %s", g);
    }

    function test_renew_registered(uint32 duration) external {
        vm.assume(duration >= ethRenewerV1.MIN_RENEW_DURATION());
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.REGISTERED), "status0");
        assertTrue(ethRenewerV1.isRenewable(testLabel), "isRenewable");
        assertEq(ethRenewerV1.getRemainingGracePeriod(testLabel), 0, "remaining");

        uint256 expiryV1 = baseRegistrar.nameExpires(tokenIdV1);
        uint64 expiryV2 = ethRegistry.getExpiry(tokenIdV1);
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, duration, testPaymentToken, testReferrer);

        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.REGISTERED), "status"); // same
        assertEq(baseRegistrar.nameExpires(tokenIdV1), expiryV1 + duration, "expiryV1");
        assertEq(ethRegistry.getExpiry(tokenIdV1), expiryV2 + duration, "expiryV2");
        assertEq(
            baseRegistrar.nameExpires(tokenIdV1) + premigrationBonusPeriod,
            ethRegistry.getExpiry(tokenIdV1),
            "sync"
        );
    }

    function test_renew_duringGrace_outOfGrace(uint32 graceDebt) external {
        vm.assume(graceDebt < gracePeriodV1);
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);

        uint256 expiryV1 = baseRegistrar.nameExpires(tokenIdV1);
        uint64 expiryV2 = ethRegistry.getExpiry(tokenIdV1);

        vm.warp(expiryV1 + graceDebt);
        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.GRACE), "status0");
        assertTrue(ethRenewerV1.isRenewable(testLabel), "isRenewable");
        assertEq(
            ethRenewerV1.getRemainingGracePeriod(testLabel),
            gracePeriodV1 - graceDebt,
            "remaining"
        );

        uint64 duration = gracePeriodV1;
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, duration, testPaymentToken, testReferrer);

        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.REGISTERED), "status");
        assertEq(ethRenewerV1.getRemainingGracePeriod(testLabel), 0, "remaining");
        assertEq(baseRegistrar.nameExpires(tokenIdV1), expiryV1 + duration, "expiryV1");
        assertEq(ethRegistry.getExpiry(tokenIdV1), expiryV2 + duration, "expiryV2");
        assertEq(
            baseRegistrar.nameExpires(tokenIdV1) + premigrationBonusPeriod,
            ethRegistry.getExpiry(tokenIdV1),
            "sync"
        );
    }

    function test_renew_duringGrace_stillInGrace(uint32 graceDebt, uint32 duration) external {
        vm.assume(
            duration >= ethRenewerV1.MIN_RENEW_DURATION() &&
            graceDebt >= duration &&
            graceDebt < gracePeriodV1
        );
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);

        uint256 expiryV1 = baseRegistrar.nameExpires(tokenIdV1);
        uint64 expiryV2 = ethRegistry.getExpiry(tokenIdV1);

        vm.warp(expiryV1 + graceDebt);
        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.GRACE), "status0");
        assertTrue(ethRenewerV1.isRenewable(testLabel), "isRenewable");

        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, duration, testPaymentToken, testReferrer);

        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.GRACE), "status"); // still
        assertEq(
            ethRenewerV1.getRemainingGracePeriod(testLabel),
            gracePeriodV1 - (graceDebt - duration),
            "remaining"
        );
        assertEq(baseRegistrar.nameExpires(tokenIdV1), expiryV1 + duration, "expiryV1");
        assertEq(ethRegistry.getExpiry(tokenIdV1), expiryV2 + duration, "expiryV2");
        assertEq(
            baseRegistrar.nameExpires(tokenIdV1) + premigrationBonusPeriod,
            ethRegistry.getExpiry(tokenIdV1),
            "sync"
        );
    }

    function test_renew_afterGrace() external {
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);

        vm.warp(baseRegistrar.nameExpires(tokenIdV1) + gracePeriodV1);
        assertEq(uint8(getStatusV1(tokenIdV1)), uint8(StatusV1.AVAILABLE), "status0");
        assertFalse(ethRenewerV1.isRenewable(testLabel), "isRenewable");
        assertEq(ethRenewerV1.getRemainingGracePeriod(testLabel), 0, "remaining");

        uint64 duration = ethRenewerV1.MIN_RENEW_DURATION();
        vm.expectRevert(abi.encodeWithSelector(IETHRenewer.NameNotRenewable.selector, testLabel));
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, duration, testPaymentToken, testReferrer);
    }

    function test_renew_balanceChanges(uint32 during, uint32 duration) external {
        vm.assume(
            duration >= ethRenewerV1.MIN_RENEW_DURATION() && during < testDuration + gracePeriodV1
        );
        registerUnwrapped(testLabel);
        vm.warp(block.timestamp + during);
        uint256 owner0 = testPaymentToken.balanceOf(testOwner);
        uint256 beneficiary0 = testPaymentToken.balanceOf(beneficiary);
        uint256 amount = ethRenewerV1.getRenewPrice(testLabel, duration, testPaymentToken);
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, duration, testPaymentToken, testReferrer);
        assertEq(owner0 - amount, testPaymentToken.balanceOf(testOwner), "owner");
        assertEq(beneficiary0 + amount, testPaymentToken.balanceOf(beneficiary), "beneficiary");
    }

    function test_renew_durationTooShort() external {
        uint64 min = ethRenewerV1.MIN_RENEW_DURATION();
        uint64 duration = min - 1;
        registerUnwrapped(testLabel);
        vm.expectRevert(abi.encodeWithSelector(IETHRenewer.DurationTooShort.selector, duration, min));
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, duration, testPaymentToken, testReferrer);
    }

    function test_renew_insufficientAllowance() external {
        registerUnwrapped(testLabel);
        vm.prank(testOwner);
        testPaymentToken.approve(address(ethRenewerV1), 0);
        uint256 amount = ethRenewerV1.getRenewPrice(testLabel, testDuration, testPaymentToken);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(ethRenewerV1), // spender
                0, // allowance
                amount // needed
            )
        );
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, testDuration, testPaymentToken, testReferrer);
    }

    function test_renew_insufficientBalance() external {
        registerUnwrapped(testLabel);
        testPaymentToken.nuke(testOwner);
        uint256 amount = ethRenewerV1.getRenewPrice(testLabel, testDuration, testPaymentToken);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                testOwner, // sender
                0, // balance
                amount // needed
            )
        );
        vm.prank(testOwner);
        ethRenewerV1.renew(testLabel, testDuration, testPaymentToken, testReferrer);
    }

    ////////////////////////////////////////////////////////////////////////
    // syncWrapper()
    ////////////////////////////////////////////////////////////////////////

    function test_syncWrapper_unwrapped() external {
        registerUnwrapped(testLabel);
        string[] memory labels = new string[](1);
        labels[0] = testLabel;
        uint256 g = gasleft();
        ethRenewerV1.syncWrapper(labels); // noop
        g -= gasleft();
        console.log("Gas: %s", g);
    }

    function test_syncWrapper_wrapped() external {
        uint256 k;
        console.log("N | Gas");
        for (uint256 n; n <= 5; ++n) {
            string[] memory labels = new string[](n);
            for (uint256 i; i < n; ++i) {
                string memory label = labels[i] = _label(k++);
                registerWrappedETH2LD(label, 0);
                vm.prank(address(ethControllerV1));
                baseRegistrar.renew(LibLabel.id(label), 1);
            }
            uint256 g = gasleft();
            ethRenewerV1.syncWrapper(labels);
            g -= gasleft();
            console.log("%s | %s", n, g);
        }
    }
}
