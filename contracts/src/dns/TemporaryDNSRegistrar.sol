// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {PublicSuffixList} from "@ens/contracts/dnsregistrar/PublicSuffixList.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

/// @notice Temporary `DNSRegistrar` for managing public suffixes.
contract TemporaryDNSRegistrar is ERC165, Ownable {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    /// @notice Shared `PublicSuffixList`.
    PublicSuffixList public immutable PUBLIC_SUFFIX_LIST;

    /// @notice Owner of the public suffix tokens.
    address public immutable TOKEN_OWNER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Default resolver for public suffixes.
    address public defaultResolver;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The suffix is 
    /// @dev Error selector: `0xe061c9ea`
    error InvalidSuffix(bytes name);

    /// @dev Error selector: `0x0b647277`
    error SuffixOwned(bytes name, address owner);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param owner_ Contract owner.
    /// @param rootRegistry ENSv2 root registry.
    /// @param tokenOwner Owner of the public suffix tokens.
    /// @param publicSuffixList Shared `PublicSuffixList`.
    /// @param resolver Default resolver for public suffixes.
    constructor(
        address owner_,
        IPermissionedRegistry rootRegistry,
        address tokenOwner,
        PublicSuffixList publicSuffixList,
        address resolver
    )
        Ownable(owner_)
    {
        ROOT_REGISTRY = rootRegistry;
        TOKEN_OWNER = tokenOwner;
        PUBLIC_SUFFIX_LIST = publicSuffixList;
        defaultResolver = resolver;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Update the default resolver for public suffixes.
    /// @param resolver New default resolver.
    function setDefaultResolver(address resolver) external onlyOwner {
        defaultResolver = resolver;
    }

    /// @notice Ensure every public suffix is enabled and using the latest resolver.
    /// @param names List of suffixes to sync.
    function syncSuffixes(bytes[] calldata names) external {
        for (uint256 i; i < names.length; ++i) {
            syncSuffix(names[i]);
        }
    }

    /// @notice Ensure public suffix is enabled and using the latest resolver.
    /// @param name DNS-encoded name.
    function syncSuffix(bytes calldata name) public {
        if (!PUBLIC_SUFFIX_LIST.isPublicSuffix(name) || NameCoder.countLabels(name, 0) != 1) {
            revert InvalidSuffix(name);
        }
        string memory label = NameCoder.firstLabel(name);
        IPermissionedRegistry.State memory state = ROOT_REGISTRY.getState(LibLabel.id(label));
        if (state.status == IPermissionedRegistry.Status.REGISTERED) {
            if (state.latestOwner != TOKEN_OWNER) {
                revert SuffixOwned(name, state.latestOwner);
            }
            // check if resolver needs updated
            if (ROOT_REGISTRY.getResolver(label) != defaultResolver) {
                ROOT_REGISTRY.setResolver(state.tokenId, defaultResolver); // assumes: TOKEN_OWNER.setApprovalForAll(this, true)
            }
        } else {
            // on v2 launch, dns domains were reserved
            ROOT_REGISTRY.register(
                label,
                TOKEN_OWNER,
                IRegistry(address(0)),
                defaultResolver,
                EACBaseRolesLib.ALL_ROLES, // MUST have ROLE_REGISTER
                type(uint64).max
            );
        }
    }
}
