// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IEnhancedAccessControl} from "../access-control/interfaces/IEnhancedAccessControl.sol";

import {IAddressSet} from "./interfaces/IAddressSet.sol";

/// @notice Authority which permits upgrades via signature.
///
/// Requires auditor to verify the current requested proxy is upgradeable.
///
/// Auditor must ensure roles like `ROLE_UPGRADE` are held only by the authority
/// to prevent upgrades between the audit (signature) and the upgrade (transaction).
///
/// After upgrading, transfers roles to the original account.
///
contract TrustedRegistryUpgradeAuthority is Ownable, IAddressSet {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Current trusted signer.
    address public signer;

    /// @dev Currently allowed upgrade proxy.
    address internal _allowed;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Signature did not authorize the requested upgrade.
    /// @dev Error selector: `0xc8ab00cf`
    error UpgradeNotAuthorized();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param owner_ Contract owner.
    /// @param signer_ Initial trusted signer.
    constructor(address owner_, address signer_) Ownable(owner_) {
        signer = signer_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Change the trusted signer.
    /// @param signer_ The new trusted signer.
    function setSigner(address signer_) external onlyOwner {
        signer = signer_;
    }

    /// @notice Upgrade an UUPS proxy with an trusted signature.
    /// @param proxy Proxy to upgrade.
    /// @param admin Account to restore upgrade roles to.
    /// @param impl New proxy implementation.
    /// @param data Upgrade calldata.
    /// @param sig Trusted signature.
    function upgrade(
        address proxy,
        address admin,
        address impl,
        bytes calldata data,
        bytes calldata sig
    )
        external
    {
        if (
            !SignatureChecker.isValidSignatureNow(
                signer,
                keccak256(abi.encode(proxy, admin, impl, data)),
                sig
            )
        ) {
            revert UpgradeNotAuthorized();
        }
        _allowed = proxy;
        UUPSUpgradeable(proxy).upgradeToAndCall(impl, data);
        delete _allowed;
        uint256 roleBitmap = IEnhancedAccessControl(proxy).roles(0, address(this));
        IEnhancedAccessControl(proxy).grantRootRoles(roleBitmap, admin);
        IEnhancedAccessControl(proxy).revokeRootRoles(roleBitmap, address(this));
    }

    /// @inheritdoc IAddressSet
    function includes(address addr) external view returns (bool) {
        return _allowed == addr;
    }
}
