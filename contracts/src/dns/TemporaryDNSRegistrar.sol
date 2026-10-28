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

/// @dev Roles granted to registered tokens.
uint256 constant TLD_ROLE_BITMAP = EACBaseRolesLib.ALL_ROLES; // MUST have ROLE_REGISTER

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

    /// @notice TLD not in `PublicSuffixList`.
    /// @dev Error selector: `0x0afb8b28`
    error TLDNotPublic(string label);

    /// @notice TLD not owned by `TOKEN_OWNER`.
    /// @dev Error selector: `0x6128680d`
    error TLDNotOwned(string label, address owner);

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

    /// @notice Ensure multiple TLDs are enabled and using the latest resolver.
    /// @param labels List of TLDs to sync.
    function syncTLDs(string[] calldata labels) external {
        for (uint256 i; i < labels.length; ++i) {
            syncTLD(labels[i]);
        }
    }

    /// @notice Ensure TLD is enabled and using the latest resolver.
    /// @param label TLD to sync.
    function syncTLD(string calldata label) public {
        if (!PUBLIC_SUFFIX_LIST.isPublicSuffix(NameCoder.addLabel(hex"00", label))) {
            revert TLDNotPublic(label);
        }
        IPermissionedRegistry.State memory state = ROOT_REGISTRY.getState(LibLabel.id(label));
        if (state.status == IPermissionedRegistry.Status.REGISTERED) {
            if (state.latestOwner != TOKEN_OWNER) {
                revert TLDNotOwned(label, state.latestOwner);
            }
            // check if resolver needs updated
            if (ROOT_REGISTRY.getResolver(label) != defaultResolver) {
                // this contract must have SET_RESOLVER role or approval
                ROOT_REGISTRY.setResolver(state.tokenId, defaultResolver);
            }
        } else {
            // on v2 launch, dns domains were reserved
            ROOT_REGISTRY.register(
                label,
                TOKEN_OWNER,
                IRegistry(address(0)),
                defaultResolver,
                TLD_ROLE_BITMAP,
                type(uint64).max
            );
        }
    }
}
