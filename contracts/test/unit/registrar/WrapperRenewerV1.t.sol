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

        // register migration cases Before registrar is disabled
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
            // remove default controller
            nameWrapper.setController(ensV1Controller, false);
            // add mock wrapped controller
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

        // BaseRegistrar.controllers = []
        // NameWrapper.controllers = [wrappedController]
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
        string memory label = NameCoder.firstLabel(name);
        uint256 labelId = LibLabel.id(label);
        uint64 duration = 1;
        assertEq(renewer.canRenew(label), expect, "canRenew");
        uint64 expiryV1Before = uint64(ethRegistrarV1.nameExpires(labelId));
        uint64 expiryV2Before = ethRegistry.getExpiry(labelId);
        assertEq(expiryV1Before, expiryV2Before, "before");
        if (!expect) {
            vm.expectRevert(abi.encodeWithSelector(LibMigration.NameRequiresMigration.selector));
        }
        renewer.renew{value: address(this).balance}(label, duration);
        if (!expect) {
            duration = 0;
        }
        uint64 expiryV1After = uint64(ethRegistrarV1.nameExpires(labelId));
        uint64 expiryV2After = ethRegistry.getExpiry(LibLabel.id(label));
        assertEq(expiryV1Before + duration, expiryV1After, "expiryV1");
        assertEq(expiryV2Before + duration, expiryV2After, "expiryV2");
        assertEq(expiryV1After, expiryV2After, "after");
        (address owner, , uint64 wrappedExpiry) = nameWrapper.getData(
            uint256(NameCoder.namehash(name, 0))
        );
        if (owner != address(0)) {
            assertEq(wrappedExpiry, expiryV1After + ethRegistrarV1.GRACE_PERIOD(), "sync");
        }
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
