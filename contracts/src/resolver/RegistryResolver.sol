// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {COIN_TYPE_ETH} from "@ens/contracts/utils/ENSIP19.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";

contract RegistryResolver is ERC165, IExtendedResolver {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The resolver profile cannot be answered.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    /// @notice `name` is not a valid DNS-encoded ENSIP-19 reverse name or namespace.
    /// @dev Error selector: `0x5fe9a5df`
    error UnreachableName(bytes name);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param root The root registry.
    constructor(IPermissionedRegistry root) {
        ROOT_REGISTRY = root;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IExtendedResolver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IExtendedResolver
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory) {
        (, address resolver, , uint256 offset) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0);
        if (resolver != address(this)) {
            revert UnreachableName(name);
        }
        (IRegistry registry, , , ) =
            LibRegistry.findResolver(ROOT_REGISTRY, abi.encodePacked(name[:offset], uint8(0)), 0);
        if (bytes4(data) == IAddrResolver.addr.selector) {
            return abi.encode(registry);
        } else if (bytes4(data) == IAddressResolver.addr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(coinType == COIN_TYPE_ETH ? abi.encodePacked(registry) : bytes(""));
        } else {
            revert UnsupportedResolverProfile(bytes4(data));
        }
    }
}
