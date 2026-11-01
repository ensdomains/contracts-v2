// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {
    IEACGrantInitializable,
    Grant
} from "~src/access-control/interfaces/IEACGrantInitializable.sol";
import {IRegistryURIRenderer} from "~src/registry/interfaces/IRegistryURIRenderer.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {UserRegistryWithUpgradeSet} from "~src/registry/UserRegistryWithUpgradeSet.sol";
import {UserRegistryWithUpgradeBlackout} from "~src/registry/UserRegistryWithUpgradeBlackout.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";

contract UserRegistryWithUpgradeTest is Test {
    VerifiableFactory verifiableFactory;
    LabelStore labelStore;
    UserRegistry implV0;
    UserRegistryWithUpgradeBlackout implV0ToV1;
    UserRegistryWithUpgradeSet implV1ToV2;
    UserRegistryWithUpgradeSet implV0V1ToV3;
    uint256 privateKey = 4;
    address upgradeSigner;
    address admin = makeAddr("admin");

    function setUp() external {
        verifiableFactory = new VerifiableFactory();
        labelStore = new LabelStore(IContractNamer(address(0)));
        IRegistryURIRenderer renderer;
        address namer = address(this);
        upgradeSigner = vm.addr(privateKey);

        // initial implementatation 
        implV0 = new UserRegistry(labelStore, renderer, namer);

        // blackout implementation with authorized upgrade
        {
            address[] memory impls = new address[](1);
            impls[0] = address(implV0);
            implV0ToV1 = new UserRegistryWithUpgradeBlackout(
                labelStore,
                renderer,
                namer,
                impls,
                upgradeSigner
            );
        }

        // the fixed implementation after authorized upgrade
        implV1ToV2 = UserRegistryWithUpgradeSet(vm.computeCreateAddress(address(implV0ToV1), 1));

        // untrusted implementation that accepts upgrade from initial or blackout
        {
            address[] memory impls = new address[](2);
            impls[0] = address(implV0);
            impls[1] = address(implV0ToV1);
            implV0V1ToV3 = new UserRegistryWithUpgradeSet(labelStore, renderer, namer, impls);
        }
    }

    function test_upgrade() external {
        address proxy = verifiableFactory.deployProxy(address(implV0), 0, _initData());
        assertEq(verifiableFactory.verifyContract(proxy), address(implV0), "@implV0");

        uint256 blocks = 100;

        // can upgrade any => blackout
        vm.prank(admin);
        UserRegistry(proxy).upgradeToAndCall(
            address(implV0ToV1),
            abi.encodeCall(UserRegistryWithUpgradeBlackout.reinitWithUpgradeBlackout, blocks)
        );
        assertEq(verifiableFactory.verifyContract(proxy), address(implV0ToV1), "@implV0ToV1");
        uint256 blockNumber = block.number;

        // check the blackout
        assertEq(
            UserRegistryWithUpgradeBlackout(proxy).upgradeBlackoutFirstBlock(),
            blockNumber,
            "first block"
        );
        assertEq(
            UserRegistryWithUpgradeBlackout(proxy).upgradeBlackoutLastBlock(),
            blockNumber + blocks,
            "last block"
        );

        // extend the blackout
        blocks <<= 1;
        vm.prank(admin);
        UserRegistryWithUpgradeBlackout(proxy).refreshUpgradeBlackout(blocks);
        assertEq(
            UserRegistryWithUpgradeBlackout(proxy).upgradeBlackoutFirstBlock(),
            blockNumber,
            "first block (unchanged)"
        );
        blocks += blockNumber - block.number;
        assertEq(
            UserRegistryWithUpgradeBlackout(proxy).upgradeBlackoutLastBlock(),
            blockNumber + blocks,
            "last block (changed)"
        );

        // cannot normal upgrade during blackout
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeDuringBlackout.selector)
        );
        vm.prank(admin);
        UserRegistry(proxy).upgradeToAndCall(address(implV0V1ToV3), "");

        // cannot blackout upgrade before blackout
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeRequiresBlackout.selector)
        );
        vm.prank(admin);
        UserRegistry(proxy).upgradeToAndCall(address(implV1ToV2), abi.encode(blockNumber - 1, ""));

        // cannot blackout upgrade after blackout
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeRequiresBlackout.selector)
        );
        vm.prank(admin);
        UserRegistry(proxy).upgradeToAndCall(
            address(implV1ToV2),
            abi.encode(blockNumber + blocks + 1, "")
        );

        // cannot blackout upgrade with invalid signature
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeNotAuthorized.selector)
        );
        vm.prank(admin);
        UserRegistry(proxy).upgradeToAndCall(address(implV1ToV2), abi.encode(blockNumber, ""));

        // can blackout upgrade with valid signature
        vm.prank(admin);
        UserRegistry(proxy).upgradeToAndCall(
            address(implV1ToV2),
            abi.encode(blockNumber, _sign(keccak256(abi.encode(proxy, implV1ToV2, blockNumber))))
        );
        assertEq(verifiableFactory.verifyContract(proxy), address(implV1ToV2), "@implV1ToV2");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _initData() internal view returns (bytes memory) {
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(admin, EACBaseRolesLib.ALL_ROLES);
        return abi.encodeCall(IEACGrantInitializable.initialize, (grants));
    }

    function _sign(bytes32 hash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encodePacked(r, s, v);
    }
}
