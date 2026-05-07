// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

/// @notice Deploys a new PermissionedResolver proxy via an existing VerifiableFactory.
///         The deployer receives ALL roles (ROLES_ALL) as admin.
///
/// Usage:
///   forge script script/DeployPermissionedResolver.s.sol \
///     --rpc-url <RPC_URL> \
///     --private-key <PRIVATE_KEY> \
///     --broadcast
///
/// Required env vars (or pass via --env-file):
///   VERIFIABLE_FACTORY          — address of the deployed VerifiableFactory
///   PERMISSIONED_RESOLVER_IMPL  — address of the deployed PermissionedResolverImpl
contract DeployPermissionedResolver is Script {
    // All 32 roles + all 32 admin roles — see deploy-constants.ts ROLES.ALL
    uint256 constant ROLES_ALL = 0x1111111111111111111111111111111111111111111111111111111111111111;

    function run() external {
        address factoryAddr = vm.envAddress("VERIFIABLE_FACTORY");
        address implAddr = vm.envAddress("PERMISSIONED_RESOLVER_IMPL");

        vm.startBroadcast();
        address deployer = msg.sender;

        bytes memory initData = abi.encodeCall(PermissionedResolver.initialize, (deployer, ROLES_ALL));
        uint256 salt = uint256(keccak256(abi.encode(deployer, block.timestamp)));
        address proxy = VerifiableFactory(factoryAddr).deployProxy(implAddr, salt, initData);

        console.log("PermissionedResolver proxy:", proxy);
        console.log("Admin:                     ", deployer);
        console.log("VerifiableFactory:         ", factoryAddr);
        console.log("Implementation:            ", implAddr);

        vm.stopBroadcast();
    }
}
