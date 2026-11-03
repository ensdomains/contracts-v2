// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {
    IEACGrantInitializable,
    Grant
} from "~src/access-control/interfaces/IEACGrantInitializable.sol";
import {LabelStore} from "~src/utils/LabelStore.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {IRegistryURIRenderer} from "~src/registry/interfaces/IRegistryURIRenderer.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {UserRegistryWithUpgradeSet} from "~src/registry/UserRegistryWithUpgradeSet.sol";
import {UserRegistryWithUpgradeBlackout} from "~src/registry/UserRegistryWithUpgradeBlackout.sol";

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

    function test_upgradeToAndCall_withoutReinit() external {
        UserRegistry proxy = _deployV0();
        vm.prank(admin);
        proxy.upgradeToAndCall(address(implV0ToV1), "");
        assertEq(verifiableFactory.verifyContract(address(proxy)), address(implV0ToV1), "@V0ToV1");
        assertFalse(UserRegistryWithUpgradeBlackout(address(proxy)).isDuringUpgradeBlackout());
    }

    function test_isDuringUpgradeBlackout() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(10);
        assertTrue(proxy.isDuringUpgradeBlackout(), "1");
        vm.roll(proxy.upgradeBlackoutLastBlock());
        assertTrue(proxy.isDuringUpgradeBlackout(), "2");
        vm.roll(proxy.upgradeBlackoutLastBlock() + 1);
        assertFalse(proxy.isDuringUpgradeBlackout(), "3");
    }

    function test_refreshUpgradeBlackout_init() external {
        uint256 blocks = 100;
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(blocks);
        assertEq(proxy.upgradeBlackoutFirstBlock(), block.number, "first");
        assertEq(proxy.upgradeBlackoutLastBlock(), block.number + blocks, "last");
    }

    function test_refreshUpgradeBlackout_extendLonger() external {
        uint256 blocks = 100;
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(blocks);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        blocks <<= 1; // longer
        vm.prank(admin);
        proxy.refreshUpgradeBlackout(blocks);
        assertEq(proxy.upgradeBlackoutFirstBlock(), firstBlock, "first");
        assertEq(proxy.upgradeBlackoutLastBlock(), firstBlock + blocks, "last");
    }

    function test_refreshUpgradeBlackout_extendShorter() external {
        uint256 blocks = 100;
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(blocks);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        uint256 lastBlock = proxy.upgradeBlackoutLastBlock();
        blocks >>= 1; // shorter
        vm.prank(admin);
        proxy.refreshUpgradeBlackout(blocks);
        assertEq(proxy.upgradeBlackoutFirstBlock(), firstBlock, "first");
        assertEq(proxy.upgradeBlackoutLastBlock(), lastBlock, "last");
    }

    function test_refreshUpgradeBlackout_replace() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(10);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        vm.roll(proxy.upgradeBlackoutLastBlock() + 1);
        assertFalse(proxy.isDuringUpgradeBlackout());

        uint256 blocks = 100;
        vm.prank(admin);
        proxy.refreshUpgradeBlackout(blocks);
        assertNotEq(proxy.upgradeBlackoutFirstBlock(), firstBlock, "diff");
        assertEq(proxy.upgradeBlackoutFirstBlock(), block.number, "first");
        assertEq(proxy.upgradeBlackoutLastBlock(), block.number + blocks, "last");
    }

    function test_upgradeToAndCall_normalDuringBlackout() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(1);
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeDuringBlackout.selector)
        );
        vm.prank(admin);
        proxy.upgradeToAndCall(address(implV0V1ToV3), "");
    }

    function test_upgradeToAndCall_signnedWithoutBlackout() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(1);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        vm.roll(proxy.upgradeBlackoutLastBlock() + 1);
        assertFalse(proxy.isDuringUpgradeBlackout());

        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeRequiresBlackout.selector)
        );
        vm.prank(admin);
        proxy.upgradeToAndCall(address(implV1ToV2), abi.encode(firstBlock, _sign(proxy, firstBlock)));
    }

    function test_upgradeToAndCall_signnedWrongBlock() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(1);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeNotAuthorized.selector)
        );
        vm.prank(admin);
        proxy.upgradeToAndCall(
            address(implV1ToV2),
            abi.encode(firstBlock + 1, _sign(proxy, firstBlock))
        );
    }

    function test_upgradeToAndCall_signnedInvalid() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(1);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        vm.expectRevert(
            abi.encodeWithSelector(UserRegistryWithUpgradeBlackout.UpgradeNotAuthorized.selector)
        );
        vm.prank(admin);
        proxy.upgradeToAndCall(
            address(implV1ToV2),
            abi.encode(firstBlock, _signn(keccak256("wrong")))
        );
    }

    function test_upgradeToAndCall_signnedValid() external {
        UserRegistryWithUpgradeBlackout proxy = _deployV0AndUpgradeToV1(1);
        uint256 firstBlock = proxy.upgradeBlackoutFirstBlock();
        vm.prank(admin);
        proxy.upgradeToAndCall(address(implV1ToV2), abi.encode(firstBlock, _sign(proxy, firstBlock)));
        assertEq(verifiableFactory.verifyContract(address(proxy)), address(implV1ToV2), "@V1ToV2");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Deploy `UserRegistry` with full `admin` control.
    function _deployV0() internal returns (UserRegistry) {
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(admin, EACBaseRolesLib.ALL_ROLES);
        bytes memory initData = abi.encodeCall(IEACGrantInitializable.initialize, (grants));

        address proxy = verifiableFactory.deployProxy(address(implV0), 0, initData);
        assertEq(verifiableFactory.verifyContract(proxy), address(implV0), "@V0");
        return UserRegistry(proxy);
    }

    /// @dev `_deployV0()` and then upgrade to `UserRegistryWithUpgradeBlackout`.
    function _deployV0AndUpgradeToV1(uint256 blocks)
        internal
        returns (UserRegistryWithUpgradeBlackout)
    {
        UserRegistry proxy = _deployV0();
        vm.prank(admin);
        proxy.upgradeToAndCall(
            address(implV0ToV1),
            abi.encodeCall(UserRegistryWithUpgradeBlackout.reinitWithUpgradeBlackout, blocks)
        );
        assertEq(verifiableFactory.verifyContract(address(proxy)), address(implV0ToV1), "@V0ToV1");
        return UserRegistryWithUpgradeBlackout(address(proxy));
    }

    /// @dev Sign arbitrary hash.
    function _signn(bytes32 hash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign valid authorization for a specific proxy and block.
    function _sign(UserRegistryWithUpgradeBlackout proxy, uint256 blockNumber)
        internal
        view
        returns (bytes memory)
    {
        return _signn(keccak256(abi.encode(proxy, implV1ToV2, blockNumber)));
    }
}
