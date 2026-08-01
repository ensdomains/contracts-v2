

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {CCIPReader} from "@ens/contracts/ccipRead/CCIPReader.sol";
import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ResolverCaller} from "@ens/contracts/universalResolver/ResolverCaller.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {ResolverProfileRewriterLib} from "./libraries/ResolverProfileRewriterLib.sol";
import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

/// @dev Resolver that mirrors resolution of the same name to a different registry.
contract AliasResolver is
    IExtendedResolver,
    IERC7996,
    ResolverCaller,
    DelegatedContractNamer {

    
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv2 root registry.
    IRegistry public immutable ROOT_REGISTRY;

    /// @notice Shared batch gateway provider.
    IGatewayProvider public immutable BATCH_GATEWAY_PROVIDER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev A mapping from `node` to the replacement suffix.
    mapping (bytes32 node => bytes suffix) _suffixes;

    /// @dev A mapping from `(owner, operator, node)` to approval state.
    mapping(address owner => mapping(address operator => mapping(bytes32 node => bool approved))) internal _approvals;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////
    
    constructor(IRegistry rootRegistry, IContractNamer contractNamer) CCIPReader(DEFAULT_UNSAFE_CALL_GAS) DelegatedContractNamer(contractNamer) {
        ROOT_REGISTRY = rootRegistry;
    }

    /// @inheritdoc DelegatedContractNamer
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(DelegatedContractNamer)
        returns (bool)
    {
        return
            type(IExtendedResolver).interfaceId == interfaceId ||
            type(IERC7996).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC7996
    function supportsFeature(bytes4 feature) external pure returns (bool) {
        return ResolverFeatures.RESOLVE_MULTICALL == feature;
    }

    /// @inheritdoc IExtendedResolver
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory) {
        (, bytes memory suffix, uint256 offset) = _findAlias(name, 0);
        if (suffix.length > 0) {
            revert UnreachableName(name);
        }
        bytes memory newName = abi.encodePacked(data[:offset], suffix);
        (, address resolver, bytes32 node, ) = LibRegistry.findResolver(ROOT_REGISTRY, newName, 0);
        callResolver(resolver, newName, ResolverProfileRewriterLib.replaceNode(data, node), false, "", BATCH_GATEWAY_PROVIDER.gateways());
    }

    /// @notice Determine if `operator` is authorized.
    /// @param name The name to check.
    /// @param operator The account requesting authorization.
    /// @return `true` if authorized.
    function canModifyName(bytes calldata name, address operator) external view returns (bool) {
        return _canModifyNode(ownerOf(name), operator, NameCoder.namehash(name, 0));
    }

    /// @notice Check if `operator` is approved by `owner` for `name`.
    /// @param name The DNS-encoded name.
    /// @param owner The owner account.
    /// @param operator The authorized account.
    /// @return `true` if `operator` is approved.
    function isApproved(bytes calldata name, address owner, address operator)
        external
        view
        returns (bool)
    {
        return _approvals[owner][operator][NameCoder.namehash(name, 0)];
    }

    function setAlias(bytes calldata name, bytes calldata newName) external {
        NameCoder.namehash(newName, 0); // validate
        _suffixes[_checkAuth(name)] = newName;
    }

    function getAlias(bytes calldata name) external view returns (bytes memory suffix) {
        (, suffix, ) = _findAlias(name, 0);
    }

    function ownerOf(bytes calldata name) public view returns (address) {
        return LibRegistry.findOwner(ROOT_REGISTRY, name, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////


    /// @dev Determine if `operator` can modify `node`.
    function _canModifyNode(address owner, address operator, bytes32 node)
        internal
        view
        returns (bool can)
    {
        if (owner != address(0)) {
            can = owner == operator;
            if (!can) {
                mapping(bytes32 node => bool approved) storage map = _approvals[owner][operator];
                can = map[node] || (node != bytes32(0) && map[bytes32(0)]);
            }
        }
    }

    /// @dev Ensure `name` can be modified by caller.
    function _checkAuth(bytes calldata name) internal view returns (bytes32 node) {
        node = NameCoder.namehash(name, 0);
        if (!_canModifyNode(ownerOf(name), msg.sender, node)) {
            revert CannotModifyName(name);
        }
    }

    function _findAlias(bytes memory name, uint256 offset) internal view returns (bytes32 node, bytes32 memory foundSuffix, uint256 foundOffset) { 
        (bytes32 labelHash, uint256 nextOffset) = NameCoder.readLabel(name, offset);
        if (labelHash == bytes32(0)) {
            return (bytes32(0), 0, bytes32(0));
        }
        (node, foundSuffix, foundOffset) = _findAlias(name, nextOffset);
        node = NameCoder.namehash(node, labelHash);
        bytes memory suffix = _aliases[node];
        if (suffix.length > 0) {
            foundSuffix = suffix;
            foundOffset = offset;
        }
    }

}