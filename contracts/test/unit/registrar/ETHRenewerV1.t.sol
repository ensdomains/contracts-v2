// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {
    INameWrapper,
    CANNOT_APPROVE,
    CANNOT_TRANSFER,
    CANNOT_UNWRAP,
    CAN_DO_EVERYTHING
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {
    MigrationControllerFixture,
    RegistryRolesLib,
    IRegistry,
    NameCoder
} from "~test/fixtures/MigrationControllerFixture.sol";
import {
    StandardRentPriceOracleFixture,
    StandardPricing,
    MockERC20
} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {
    ETHRenewerV1,
    ETHRegistrar,
    INameRenewer,
    IWrappedETHRegistrarController,
    IPermissionedRegistry
} from "~src/registrar/ETHRenewerV1.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

// [gas analysis]
// * Juggle: 35500
// * Renew w/MockUSDC: 118524

contract ETHRenewerV1Test is MigrationControllerFixture, StandardRentPriceOracleFixture {
    MockWrappedETHRegistrarController wrappedController;
    ETHRegistrar ethRegistrar;
    ETHRenewerV1 ethRenewer;

    string labelUnwrapped = "unwrapped";
    string labelUnlocked = "unlocked";
    string labelLocked = "locked";
    string labelCannotTransfer = "cannot-transfer";
    string labelFrozenApproval = "frozen-approval";

    bytes32 testReferrer;

    function setUp() external {
        deployMigrationControllerFixture();
        deployStandardRentPriceOracleFixture();

        setupPaymentTokens(user);

        testReferrer = bytes32(vm.randomUint());

        ethRegistrar = new ETHRegistrar(
            hcaFactory,
            ethRegistry,
            StandardPricing.MIN_COMMITMENT_AGE,
            StandardPricing.MAX_COMMITMENT_AGE,
            StandardPricing.GRACE_PERIOD,
            rentPriceOracle
        );

        wrappedController = new MockWrappedETHRegistrarController(nameWrapper);
        ethRenewer = new ETHRenewerV1(
            hcaFactory,
            nameWrapper,
            address(wrappedController),
            ethRegistrar
        );
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, address(ethRenewer));

        // register v1 migration cases (before registrar is disabled)
        registerUnwrapped(labelUnwrapped);
        testDurationV1 += testDurationV1;
        registerWrappedETH2LD(labelUnlocked, CAN_DO_EVERYTHING);
        testDurationV1 += testDurationV1;
        registerWrappedETH2LD(labelLocked, CANNOT_UNWRAP);
        testDurationV1 += testDurationV1;
        registerWrappedETH2LD(labelCannotTransfer, CANNOT_UNWRAP | CANNOT_TRANSFER);
        testDurationV1 += testDurationV1;
        {
            bytes memory name = registerWrappedETH2LD(labelFrozenApproval, CANNOT_UNWRAP);
            bytes32 node = NameCoder.namehash(name, 0);
            vm.prank(user);
            nameWrapper.approve(address(1), uint256(node));
            vm.prank(user);
            nameWrapper.setFuses(node, uint16(CANNOT_APPROVE));
        }

        nameWrapper.setController(ensV1Controller, false); // remove default controller
        nameWrapper.setController(address(wrappedController), true); // add mock wrapped controller
        nameWrapper.renounceOwnership(); // lock it

        baseRegistrar.removeController(ensV1Controller); // remove default controller
        baseRegistrar.addController(address(ethRenewer)); // add ethRenewer
        baseRegistrar.transferOwnership(address(ethRenewer)); // transfer to ethRenewer

        // check state
        assertEq(nameWrapper.owner(), address(0), "NameWrapper locked");
        assertFalse(nameWrapper.controllers(ensV1Controller), "NameWrapper og controller");
        assertFalse(baseRegistrar.controllers(ensV1Controller), "BaseRegistrar og controller");
        assertEq(baseRegistrar.owner(), address(ethRenewer), "Renewer owns BaseRegistrar");
        assertTrue(
            baseRegistrar.controllers(address(ethRenewer)),
            "Renewer is BaseRegistrar controller"
        );

        // BaseRegistrar.owner = ethRenewer
        // BaseRegistrar.controllers = [graveyard, ethRenewer]
        // NameWrapper.controllers = [wrappedController]
    }

    function test_constructor() external view {
        assertEq(address(ethRenewer.NAME_WRAPPER()), address(nameWrapper), "NAME_WRAPPER");
        assertEq(
            address(ethRenewer.WRAPPED_CONTROLLER()),
            address(wrappedController),
            "WRAPPED_CONTROLLER"
        );
        assertEq(address(ethRenewer.ETH_REGISTRAR()), address(ethRegistrar), "ETH_REGISTRAR");
    }

    function test_renew_unregistered() external {
        uint256 tokenIdV1 = LibLabel.id(testLabel);
        assertTrue(baseRegistrar.available(tokenIdV1));

        assertEq(baseRegistrar.nameExpires(tokenIdV1), 0, "v1");
        assertEq(ethRegistry.getExpiry(tokenIdV1), 0, "v2");

        vm.expectRevert(abi.encodeWithSelector(INameRenewer.NameNotRenewable.selector, testLabel));
        ethRenewer.renew(testLabel, 1, address(tokenUSDC), testReferrer);
    }

    function test_renew_migrated() external {
        ethRegistry.register(
            testLabel,
            address(user),
            IRegistry(address(0)),
            address(0),
            0,
            _soon()
        );

        vm.expectRevert(abi.encodeWithSelector(INameRenewer.NameNotRenewable.selector, testLabel));
        ethRenewer.renew(testLabel, 1, address(tokenUSDC), testReferrer);
    }

    function test_renew_afterGrace() external {
        uint256 tokenIdV1 = LibLabel.id(labelUnwrapped);
        vm.warp(baseRegistrar.nameExpires(tokenIdV1) + gracePeriodV1 + 1);
        assertTrue(baseRegistrar.available(tokenIdV1), "v1");
        assertTrue(ethRegistrar.isAvailable(labelUnwrapped), "v2");

        vm.expectRevert(abi.encodeWithSelector(INameRenewer.NameNotRenewable.selector, testLabel));
        ethRenewer.renew(testLabel, 1, address(tokenUSDC), testReferrer);
    }

    function test_renew_unwrapped(uint256) external {
        _testRenew(labelUnwrapped, false);
    }

    function test_renew_unlocked(uint256) external {
        _testRenew(labelUnlocked, true);
    }

    function test_renew_locked(uint256) external {
        _testRenew(labelLocked, true);
    }

    function test_renew_cannotTransfer(uint256) external {
        _testRenew(labelCannotTransfer, true);
    }

    function test_renew_frozenApproval(uint256) external {
        _testRenew(labelFrozenApproval, true);
    }

    function _testRenew(string memory label, bool wrapped) internal {
        if (vm.randomBool()) _warpToGrace(label);
        MockERC20 paymentToken = vm.randomBool() ? tokenUSDC : tokenDAI;
        uint64 duration = uint64(vm.randomUint(minRenewDuration, 10000 days));
        uint256 tokenIdV1 = LibLabel.id(label);
        IPermissionedRegistry.State memory state = ethRegistry.getState(tokenIdV1);
        uint256 amount = rentPriceOracle.getRenewPrice(
            label,
            state.expiry,
            duration,
            address(paymentToken)
        );
        uint256 balance0 = paymentToken.balanceOf(user);
        vm.expectEmit();
        emit INameRenewer.NameRenewed(
            state.tokenId,
            label,
            duration,
            state.expiry + duration,
            address(paymentToken),
            testReferrer,
            amount
        );
        vm.prank(user);
        ethRenewer.renew(label, duration, address(paymentToken), testReferrer);
        assertEq(paymentToken.balanceOf(user), balance0 - amount, "balance");
        _checkExpiry(label);
        if (wrapped) {
            string[] memory labels = new string[](1);
            labels[0] = label;
            ethRenewer.syncWrapper(labels);
            _checkSyncWrapper(label);
        }
    }

    function test_syncWrapper_notWrapped() external {
        string[] memory labels = new string[](1);
        labels[0] = labelUnwrapped;
        ethRenewer.syncWrapper(labels);
    }

    function test_syncWrapper_batch(uint256) external {
        string[] memory labels = new string[](4);
        uint256 n;
        if (vm.randomBool()) labels[n++] = labelUnlocked;
        if (vm.randomBool()) labels[n++] = labelLocked;
        if (vm.randomBool()) labels[n++] = labelCannotTransfer;
        if (vm.randomBool()) labels[n++] = labelFrozenApproval;
        assembly {
            mstore(labels, n) // truncate
        }

        for (uint256 i; i < labels.length; ++i) {
            vm.prank(user);
            ethRenewer.renew(labels[i], 1, address(tokenUSDC), testReferrer);
        }

        ethRenewer.syncWrapper(labels);

        for (uint256 i; i < labels.length; ++i) {
            _checkSyncWrapper(labels[i]);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Gas
    ////////////////////////////////////////////////////////////////////////

    function test_gas_juggle() external {
        vm.startPrank(address(ethRenewer));
        uint256 g = gasleft();
        baseRegistrar.addController(address(wrappedController));
        baseRegistrar.removeController(address(wrappedController));
        g -= gasleft();
        vm.stopPrank();
        console.log("Gas: %s", g);
    }

    function test_gas_renew() external {
        vm.prank(user);
        uint256 g = gasleft();
        ethRenewer.renew(labelUnwrapped, 1, address(tokenUSDC), testReferrer);
        g -= gasleft();
        console.log("Gas: %s", g);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _warpToGrace(string memory label) internal {
        uint256 tokenIdV1 = LibLabel.id(label);
        vm.warp(baseRegistrar.nameExpires(tokenIdV1) + vm.randomUint(0, gracePeriodV1 - 1));
        vm.expectRevert();
        baseRegistrar.ownerOf(tokenIdV1);
        assertFalse(baseRegistrar.available(tokenIdV1), "grace:available");
    }

    function _checkExpiry(string memory label) internal view {
        uint256 tokenIdV1 = LibLabel.id(label);
        uint64 expiryV1 = uint64(baseRegistrar.nameExpires(tokenIdV1));
        uint64 expiryV2 = ethRegistry.getExpiry(tokenIdV1);
        assertEq(expiryV1 + premigrationBonusPeriod, expiryV2, "v2=v1+BONUS");
    }

    function _checkSyncWrapper(string memory label) internal view {
        uint256 tokenIdV1 = LibLabel.id(label);
        bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenIdV1));
        uint64 unwrappedExpiry = uint64(baseRegistrar.nameExpires(tokenIdV1));
        (, , uint64 wrappedExpiry) = nameWrapper.getData(uint256(node));
        assertEq(wrappedExpiry, unwrappedExpiry + gracePeriodV1, "syncWrapper");
    }
}

// https://github.com/ensdomains/ens-contracts/blob/staging/deployments/mainnet/WrappedETHRegistrarController.json
contract MockWrappedETHRegistrarController {
    INameWrapper internal immutable NAME_WRAPPER;
    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
    }
    function renew(string calldata label, uint256 duration) external payable {
        require(duration == 0);
        NAME_WRAPPER.renew(LibLabel.id(label), duration);
    }
}
