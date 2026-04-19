// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";
import {
    INameWrapper,
    CANNOT_APPROVE,
    CANNOT_TRANSFER,
    CANNOT_UNWRAP,
    CAN_DO_EVERYTHING
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IPriceOracle} from "@ens/contracts/ethregistrar/IPriceOracle.sol";
import {MigrationControllerFixture} from "~test/unit/migration/MigrationControllerFixture.sol";
import {
    WrapperRenewerV1,
    IWrappedETHRegistrarController,
    NameCoder,
    LibLabel,
    LibMigration
} from "~src/registrar/WrapperRenewerV1.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";

contract WrapperRenewerV1Test is MigrationControllerFixture {
    MockWrappedETHRegistrarController wrappedController;
    WrapperRenewerV1 renewer;

    bytes nameUnwrapped;
    bytes nameUnlocked;
    bytes nameLocked;
    bytes nameCannotTransfer;
    bytes nameFrozenApproval;

    function setUp() public override {
        super.setUp();

        wrappedController = new MockWrappedETHRegistrarController(nameWrapper);
        renewer = new WrapperRenewerV1(nameWrapper, address(wrappedController), ethRegistry);

        // register migration cases before registrar is disabled
        {
            (nameUnwrapped, ) = registerUnwrapped("unwrapped");

            nameUnlocked = registerWrappedETH2LD("unlocked", CAN_DO_EVERYTHING);

            nameLocked = registerWrappedETH2LD("locked", CANNOT_UNWRAP);

            nameCannotTransfer = registerWrappedETH2LD(
                "cannot-transfer",
                CANNOT_UNWRAP | CANNOT_TRANSFER
            );

            nameFrozenApproval = registerWrappedETH2LD("frozen-approval", CANNOT_UNWRAP);
            bytes32 node = NameCoder.namehash(nameFrozenApproval, 0);
            vm.prank(user);
            nameWrapper.approve(address(1), uint256(node));
            vm.prank(user);
            nameWrapper.setFuses(node, uint16(CANNOT_APPROVE));
        }

        // configure v1
        {
            // remove wrapper controller
            nameWrapper.setController(ensV1Controller, false);
            // add wrapper controller
            nameWrapper.setController(address(wrappedController), true);
            // lock it
            nameWrapper.renounceOwnership();

            // remove eth controller
            ethRegistrarV1.removeController(ensV1Controller);
            // transfer to renewer
            ethRegistrarV1.transferOwnership(address(renewer));
        }

        // configure v2
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, address(renewer));

        // check state
        assertEq(nameWrapper.owner(), address(0), "NameWrapper locked");
        assertFalse(nameWrapper.controllers(ensV1Controller), "NameWrapper og controller");
        assertFalse(ethRegistrarV1.controllers(ensV1Controller), "BaseRegistrar og controller");
        assertEq(ethRegistrarV1.owner(), address(renewer), "Renewer owns BaseRegistrar");
    }

    function test_renew_unwrapped() external {
        _testRenew(nameUnwrapped, false);
    }

    function test_renew_unlocked() external {
        _testRenew(nameUnlocked, false);
    }

    function test_renew_locked() external {
        _testRenew(nameLocked, false);
    }

    function test_renew_cannotTransfer() external {
        _testRenew(nameCannotTransfer, true);
    }

    function test_renew_frozenApproval() external {
        _testRenew(nameFrozenApproval, true);
    }

    function _testRenew(bytes memory name, bool expect) internal {
        bytes32 node = NameCoder.namehash(name, 0);
        string memory label = NameCoder.firstLabel(name);
        uint64 duration = 1;
        assertEq(renewer.canRenew(label), expect, "canRenew");
        (, , uint64 expiryV1before) = nameWrapper.getData(uint256(node));
        uint64 expiryV2before = ethRegistry.getExpiry(LibLabel.id(label));
        if (!expect) {
            vm.expectRevert(abi.encodeWithSelector(LibMigration.NameRequiresMigration.selector));
        }
        renewer.renew{value: address(this).balance}(label, duration);
        if (!expect) {
            duration = 0;
        }
        (, , uint64 expiryV1after) = nameWrapper.getData(uint256(node));
        uint64 expiryV2after = ethRegistry.getExpiry(LibLabel.id(label));
        assertEq(expiryV1before + duration, expiryV1after, "expiryV1");
        assertEq(expiryV2before + duration, expiryV2after, "expiryV2");
    }
}

// https://github.com/ensdomains/ens-contracts/blob/staging/deployments/mainnet/WrappedETHRegistrarController.json
contract MockWrappedETHRegistrarController {
    INameWrapper internal immutable NAME_WRAPPER;
    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
    }
    function renew(string calldata label, uint256 duration) external payable {
        IPriceOracle.Price memory price = rentPrice(label, duration);
        uint256 over = msg.value - price.base; // reverts on underflow

        NAME_WRAPPER.renew(LibLabel.id(label), duration);

        if (over > 0) {
            (bool ok, ) = msg.sender.call{value: over}("");
            require(ok);
        }
    }
    function rentPrice(
        string calldata /*label*/,
        uint256 duration
    ) public pure returns (IPriceOracle.Price memory price) {
        price.base = duration;
    }
}
