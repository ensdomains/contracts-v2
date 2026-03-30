// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {GatewayProvider} from "@ens/contracts/ccipRead/GatewayProvider.sol";
import {VerifiableFactory, UUPSProxy} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {BaseUriRegistryMetadata} from "~src/registry/BaseUriRegistryMetadata.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {UniversalResolverV2} from "~src/universalResolver/UniversalResolverV2.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

/// @dev Reusable testing fixture for ENSv2 with a basic ".eth" deployment.
contract V2Fixture is Test, ERC1155Holder {
    VerifiableFactory verifiableFactory;
    MockHCAFactoryBasic hcaFactory;
    BaseUriRegistryMetadata metadata;
    UserRegistry userRegistryImpl;
    PermissionedRegistry rootRegistry;
    PermissionedRegistry ethRegistry;
    GatewayProvider batchGatewayProvider;
    UniversalResolverV2 universalResolver;

    /// @dev Role bitmaps matching README Static Deployment Permissions.
    function _rootRegistryRootRoles() internal pure returns (uint256) {
        return
            RegistryRolesLib.ROLE_REGISTRAR |
            RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
            RegistryRolesLib.ROLE_REGISTER_RESERVED |
            RegistryRolesLib.ROLE_REGISTER_RESERVED_ADMIN |
            RegistryRolesLib.ROLE_SET_PARENT |
            RegistryRolesLib.ROLE_SET_PARENT_ADMIN |
            RegistryRolesLib.ROLE_RENEW |
            RegistryRolesLib.ROLE_RENEW_ADMIN;
    }

    function _ethRegistryRootRoles() internal pure returns (uint256) {
        return
            RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
            RegistryRolesLib.ROLE_REGISTER_RESERVED_ADMIN |
            RegistryRolesLib.ROLE_SET_PARENT |
            RegistryRolesLib.ROLE_SET_PARENT_ADMIN |
            RegistryRolesLib.ROLE_RENEW_ADMIN;
    }

    function _ethTokenRoles() internal pure returns (uint256) {
        return
            RegistryRolesLib.ROLE_SET_SUBREGISTRY |
            RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN |
            RegistryRolesLib.ROLE_SET_RESOLVER |
            RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
    }

    function deployV2Fixture() public {
        verifiableFactory = new VerifiableFactory();
        hcaFactory = new MockHCAFactoryBasic();
        metadata = new BaseUriRegistryMetadata(hcaFactory);
        userRegistryImpl = new UserRegistry(hcaFactory, metadata);
        rootRegistry = new PermissionedRegistry(
            hcaFactory,
            metadata,
            address(this),
            _rootRegistryRootRoles()
        );
        ethRegistry = new PermissionedRegistry(
            hcaFactory,
            metadata,
            address(this),
            _ethRegistryRootRoles()
        );
        rootRegistry.register(
            "eth",
            address(this),
            ethRegistry,
            address(0),
            _ethTokenRoles(),
            type(uint64).max
        );
        ethRegistry.setParent(rootRegistry, "eth");
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, address(this));
        batchGatewayProvider = new GatewayProvider(address(this), new string[](0));
        universalResolver = new UniversalResolverV2(rootRegistry, batchGatewayProvider);
    }

    function findResolverV2(bytes memory name) public view returns (address resolver) {
        (resolver, , ) = universalResolver.findResolver(name);
    }

    function deployUserRegistry(
        address owner,
        uint256 roleBitmap,
        uint256 salt
    ) public returns (UserRegistry) {
        return
            UserRegistry(
                verifiableFactory.deployProxy(
                    address(userRegistryImpl),
                    salt,
                    abi.encodeCall(UserRegistry.initialize, (owner, roleBitmap))
                )
            );
    }

    function _computeVerifiableFactoryAddress(
        address deployer,
        uint256 salt
    ) internal view returns (address) {
        bytes32 outerSalt = keccak256(abi.encode(deployer, salt));
        return
            vm.computeCreate2Address(
                outerSalt,
                keccak256(
                    abi.encodePacked(
                        type(UUPSProxy).creationCode,
                        abi.encode(verifiableFactory, outerSalt)
                    )
                ),
                address(verifiableFactory)
            );
    }
}
