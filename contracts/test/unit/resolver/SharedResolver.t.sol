// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";

//import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IDataResolver} from "@ens/contracts/resolvers/profiles/IDataResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";

// import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";

// import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {IAddressSetter} from "~src/resolver/interfaces/setters/IAddressSetter.sol";
import {IDataSetter} from "~src/resolver/interfaces/setters/IDataSetter.sol";
import {INameSetter} from "~src/resolver/interfaces/setters/INameSetter.sol";
import {IInterfaceSetter} from "~src/resolver/interfaces/setters/IInterfaceSetter.sol";
import {ITextSetter} from "~src/resolver/interfaces/setters/ITextSetter.sol";

import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {
    ENSIP19,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT,
    CHAIN_ID_ETH
} from "@ens/contracts/utils/ENSIP19.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";

//import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {SharedResolver} from "~src/resolver/SharedResolver.sol";

//import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract resolverTest is V2Fixture {
    SharedResolver resolver;

    address actor = makeAddr("actor");
    address friend = makeAddr("friend");

    bytes testName;
    bytes32 testNode;

    function setUp() external {
        deployV2Fixture();
        resolver = new SharedResolver(rootRegistry, contractNamer);

        ethRegistry.register(
            "test",
            address(this),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        testName = NameCoder.ethName("test");
        testNode = NameCoder.namehash(testName, 0);
    }

    function test_supportsInterface() external view {
        // assertTrue(
        //     ERC165Checker.supportsInterface(
        //         address(resolver),
        //         type(IMulticallable).interfaceId
        //     ),
        //     "IMulticallable"
        // );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IContractNamer).interfaceId),
            "IContractNamer"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IExtendedResolver).interfaceId),
            "IExtendedResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IERC7996).interfaceId),
            "IERC7996"
        );

        // setters
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IAddressSetter).interfaceId),
            "IAddressSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IDataSetter).interfaceId),
            "IDataSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IInterfaceSetter).interfaceId),
            "IInterfaceSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(ITextSetter).interfaceId),
            "ITextSetter"
        );
    }

    function test_supportsFeature() external view {
        assertTrue(resolver.supportsFeature(ResolverFeatures.RESOLVE_MULTICALL), "RESOLVE_MULTICALL");
    }

    function test_ownerOf() external {
        assertEq(resolver.ownerOf(NameCoder.encode("")), address(0), "null");
        assertEq(resolver.ownerOf(NameCoder.ethName("dne")), address(0), "dne");
        assertEq(resolver.ownerOf(testName), address(this), "test");
    }

    function test_canModifyName() external {
        assertFalse(resolver.canModifyName(NameCoder.encode(""), address(0)), "null:null");
        assertFalse(resolver.canModifyName(NameCoder.encode(""), address(this)), "null:this");
        assertFalse(resolver.canModifyName(NameCoder.encode(""), address(actor)), "null:actor");

        assertFalse(resolver.canModifyName(testName, address(0)), "test:null");
        assertTrue(resolver.canModifyName(testName, address(this)), "test:this");
        assertFalse(resolver.canModifyName(testName, address(actor)), "test:actor");
    }

    function test_setAddress(uint256 coinType) external {
        bytes memory a = vm.randomBytes(20);

        vm.expectEmit();
        emit IAddressSetter.AddressUpdated(testNode, testName, coinType, a);
        resolver.setAddress(testName, coinType, a);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a)
        );
    }

    function test_setAddress_mainnet() external {
        address addr = vm.randomAddress();
        bytes memory a = abi.encodePacked(addr);

        resolver.setAddress(testName, COIN_TYPE_ETH, a);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(addr)
        );
    }

    function test_setAddress_zeroEVM() external {
        uint256 coinType = COIN_TYPE_ETH;

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(false)
        );

        resolver.setAddress(testName, coinType, abi.encodePacked(address(0)));

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(true)
        );

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(address(0))
        );
    }

    function test_setAddress_default(uint32 chain) external {
        vm.assume(chain < COIN_TYPE_DEFAULT);
        uint256 coinType = _coinTypeFromChain(chain);
        address addr = vm.randomAddress();
        bytes memory a = abi.encodePacked(addr);

        resolver.setAddress(testName, COIN_TYPE_DEFAULT, a);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a)
        );
        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(addr)
        );
    }

    function test_setAddress_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setAddress(testName, 0, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _coinTypeFromChain(uint32 chain) internal pure returns (uint256) {
        return chain == CHAIN_ID_ETH ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);
    }
}
