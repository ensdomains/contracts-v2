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
import {MigrationControllerFixture, NameCoder} from "~test/fixtures/MigrationControllerFixture.sol";
import {StandardRegistrar} from "~test/StandardRegistrar.sol";
import {ETHSyncer, IETHSyncer, IPermissionedRegistry, Ownable} from "~src/registrar/ETHSyncer.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

// [gas analysis]
// test_syncRegistrar_reserved(): 17106
// test_syncWrapper_unwrapped(): 52469
// test_syncWrapper_wrapped(): 47198
// test_syncWrapper_wrappedGas():
//   0 | 34198
//   1 | 43203
//   2 | 47705
//   3 | 58709
//   4 | 69718
//   5 | 80724
//   6 | 91726
//   7 | 102734
//   8 | 113746

contract ETHSyncerTest is MigrationControllerFixture {
    address actor = makeAddr("actor");

    function setUp() external {
        deployMigrationControllerFixture();
    }

    function test_constructor() external view {
        assertEq(ethSyncer.owner(), address(this), "owner");
        assertEq(address(ethSyncer.NAME_WRAPPER()), address(nameWrapper), "NAME_WRAPPER");
        assertEq(
            address(ethSyncer.WRAPPED_CONTROLLER()),
            address(wrappedController),
            "WRAPPED_CONTROLLER"
        );
        assertEq(address(ethSyncer.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
        assertEq(ethSyncer.BONUS_PERIOD(), StandardRegistrar.BONUS_PERIOD, "BONUS_PERIOD");
    }

    function test_transferRegistrarOwnership() external {
        ethSyncer.transferRegistrarOwnership(user);
        assertEq(baseRegistrar.owner(), user);
    }

    function test_transferRegistrarOwnership_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        vm.prank(actor);
        ethSyncer.transferRegistrarOwnership(user);
    }

    ////////////////////////////////////////////////////////////////////////
    // syncRegistrar()
    ////////////////////////////////////////////////////////////////////////

    function test_syncRegistrar_reserved() external {
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);

        uint64 duration = 1 days;
        uint256 expiryV1 = baseRegistrar.nameExpires(tokenIdV1);
        uint64 expiryV2 = ethRegistry.getExpiry(tokenIdV1);

        assertEq(expiryV1 + premigrationBonusPeriod, expiryV2, "sync:before");

        vm.prank(premigrationController);
        ethRegistry.renew(tokenIdV1, expiryV2 + duration); // renew RESERVED only

        uint256 g = gasleft();
        ethSyncer.syncRegistrar(testLabel);
        g -= gasleft();
        console.log("Gas: %s", g);

        assertEq(baseRegistrar.nameExpires(tokenIdV1), expiryV1 + duration, "expiryV1");
        assertEq(ethRegistry.getExpiry(tokenIdV1), expiryV2 + duration, "expiryV2");
        assertEq(
            baseRegistrar.nameExpires(tokenIdV1) + premigrationBonusPeriod,
            ethRegistry.getExpiry(tokenIdV1),
            "sync:after"
        );
    }

    function test_syncRegistar_available() external {
        assertEq(
            uint8(ethRegistry.getStatus(LibLabel.id(testLabel))),
            uint8(IPermissionedRegistry.Status.AVAILABLE),
            "status"
        );

        vm.expectRevert(abi.encodeWithSelector(IETHSyncer.NameNotSyncable.selector, testLabel));
        ethSyncer.syncRegistrar(testLabel);
    }

    function test_syncRegistar_registered() external {
        vm.prank(premigrationController);
        ethRegistry.register(testLabel, address(1), testRegistry, testResolver, 0, _soon());
        assertEq(
            uint8(ethRegistry.getStatus(LibLabel.id(testLabel))),
            uint8(IPermissionedRegistry.Status.REGISTERED),
            "status"
        );

        vm.expectRevert(abi.encodeWithSelector(IETHSyncer.NameNotSyncable.selector, testLabel));
        ethSyncer.syncRegistrar(testLabel);
    }

    ////////////////////////////////////////////////////////////////////////
    // syncWrapper()
    ////////////////////////////////////////////////////////////////////////

    function test_syncWrapper_unwrapped() external {
        registerUnwrapped(testLabel);
        string[] memory labels = new string[](1);
        labels[0] = testLabel;
        uint256 g = gasleft();
        ethSyncer.syncWrapper(labels); // noop
        g -= gasleft();
        console.log("Gas: %s", g);
    }

    function test_syncWrapper_wrapped() external {
        bytes memory name = registerWrappedETH2LD(testLabel, 0);
        bytes32 node = NameCoder.namehash(name, 0);

        uint64 duration = 1 days;

        vm.prank(address(ethSyncer));
        baseRegistrar.renew(LibLabel.id(testLabel), duration); // renew unwrapped only

        (, , uint64 wrappedExpiry0) = nameWrapper.getData(uint256(node));

        nameWrapper.renounceOwnership();

        string[] memory labels = new string[](1);
        labels[0] = testLabel;
        uint256 g = gasleft();
        ethSyncer.syncWrapper(labels);
        g -= gasleft();
        console.log("Gas: %s", g);

        (, , uint64 wrappedExpiry1) = nameWrapper.getData(uint256(node));

        assertEq(wrappedExpiry0 + duration, wrappedExpiry1, "sync");
    }

    function test_syncWrapper_wrappedGas() external {
        uint256 N = 8;
        uint256 i;
        for (uint256 n; n <= N; ++n) {
            for (uint256 j; j < n; ++j) {
                registerWrappedETH2LD(_label(i++), 0);
            }
        }
        i = 0;
        console.log("N | Gas");
        for (uint256 n; n <= N; ++n) {
            string[] memory labels = new string[](n);
            for (uint256 j; j < n; ++j) {
                labels[j] = _label(i++);
            }
            uint256 g = gasleft();
            ethSyncer.syncWrapper(labels);
            g -= gasleft();
            console.log("%s | %s", n, g);
        }
    }
}
