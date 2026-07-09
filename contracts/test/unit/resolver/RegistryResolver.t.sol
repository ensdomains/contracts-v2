// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryResolver} from "~src/resolver/RegistryResolver.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract RegistryResolverTest is V2Fixture {
    RegistryResolver registryResolver;

    function setUp() external {
        deployV2Fixture();

        registryResolver = new RegistryResolver(rootRegistry);

        ethRegistry.register(
            "reg",
            address(this),
            IRegistry(address(0)),
            address(registryResolver),
            0,
            type(uint64).max
        );
    }

    function test_root() external {
        assertEq(_resolve("reg.eth"), address(rootRegistry));
    }

    function test_eth() external {
        assertEq(_resolve("eth.reg.eth"), address(ethRegistry));
    }

    function test_unset() external {
        assertEq(_resolve("_dne.reg.eth"), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _resolve(string memory name) internal view returns (address) {
        (bytes memory answer, ) =
            universalResolver.resolve(
                NameCoder.encode(name),
                abi.encodeCall(IAddrResolver.addr, (bytes32(0)))
            );
        return abi.decode(answer, (address));
    }
}
