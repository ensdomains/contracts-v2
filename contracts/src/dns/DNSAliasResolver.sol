// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {CCIPReader} from "@ens/contracts/ccipRead/CCIPReader.sol";
import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {IExtendedDNSResolver} from "@ens/contracts/resolvers/profiles/IExtendedDNSResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ResolverCaller} from "@ens/contracts/universalResolver/ResolverCaller.sol";
import {BytesUtils} from "@ens/contracts/utils/BytesUtils.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {ResolverProfileRewriterLib} from "../resolver/libraries/ResolverProfileRewriterLib.sol";
import {LibRegistry, IRegistry} from "../universalResolver/libraries/LibRegistry.sol";

/// @notice Gasless DNSSEC resolver that forwards to another name.
///
/// Format: `ENS1 <this> <context>`
///
/// 1. Rewrite: `context = <oldSuffix> <newSuffix>`
///    eg. `*.nick.com` + `ENS1 <this> com base.eth` &rarr; `*.nick.base.eth`
/// 2. Replace: `context = <newName>`
///    eg. `notdot.net` + `ENS1 <this> nick.eth` &rarr; `nick.eth`
///
contract DNSAliasResolver is ERC165, ResolverCaller, IERC7996, IExtendedDNSResolver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    IRegistry public immutable ROOT_REGISTRY;

    IGatewayProvider public immutable BATCH_GATEWAY_PROVIDER;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The `name` did not end with `suffix`.
    /// @dev Error selector: `0x017817ea`
    ///
    /// @param name The DNS-encoded name.
    /// @param suffix THe DNS-encoded suffix.
    error NoSuffixMatch(bytes name, bytes suffix);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IRegistry rootRegistry,
        IGatewayProvider batchGatewayProvider
    ) CCIPReader(DEFAULT_UNSAFE_CALL_GAS) {
        ROOT_REGISTRY = rootRegistry;
        BATCH_GATEWAY_PROVIDER = batchGatewayProvider;
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165) returns (bool) {
        return
            type(IExtendedDNSResolver).interfaceId == interfaceId ||
            type(IERC7996).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC7996
    function supportsFeature(bytes4 feature) external pure returns (bool) {
        return ResolverFeatures.RESOLVE_MULTICALL == feature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Apply rewrite rule to name and resolve it instead.
    ///
    /// The operating assumption is that this contract is never called directly,
    /// and instead only invoked by DNSTLDResolver in response to an TXT record.
    ///
    function resolve(
        bytes calldata name,
        bytes calldata data,
        bytes calldata context
    ) external view returns (bytes memory) {
        bytes memory newName = rewriteNameWithContext(name, context);
        (, address resolver, bytes32 node, ) = LibRegistry.findResolver(ROOT_REGISTRY, newName, 0);
        callResolver(
            resolver,
            newName,
            ResolverProfileRewriterLib.replaceNode(data, node),
            false,
            "",
            BATCH_GATEWAY_PROVIDER.gateways()
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Modify `name` using rewrite rule in `context`.
    ///
    /// @param name The DNS-encoded name.
    /// @param context The rewrite rule.
    ///
    /// @return The modified DNS-encoded name.
    function rewriteNameWithContext(
        bytes calldata name,
        bytes calldata context
    ) public pure returns (bytes memory) {
        uint256 sep = BytesUtils.find(context, 0, context.length, " ");
        if (sep < context.length) {
            bytes memory oldSuffix = NameCoder.encode(string(context[:sep]));
            (bool matched, , , uint256 offset) = NameCoder.matchSuffix(
                name,
                0,
                NameCoder.namehash(oldSuffix, 0)
            );
            if (!matched) {
                revert NoSuffixMatch(name, oldSuffix);
            }
            bytes memory newSuffix = NameCoder.encode(string(context[sep + 1:]));
            return abi.encodePacked(name[:offset], newSuffix); // rewrite
        } else {
            return NameCoder.encode(string(context)); // replace
        }
    }
}
