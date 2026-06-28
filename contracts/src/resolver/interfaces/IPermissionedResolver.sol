// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/Multicallable.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IABISetter} from "./setters/IABISetter.sol";
import {IAddressSetter} from "./setters/IAddressSetter.sol";
import {IContentHashSetter} from "./setters/IContentHashSetter.sol";
import {IDataSetter} from "./setters/IDataSetter.sol";
import {IInterfaceSetter} from "./setters/IInterfaceSetter.sol";
import {INameSetter} from "./setters/INameSetter.sol";
import {IPubkeySetter} from "./setters/IPubkeySetter.sol";
import {ITextSetter} from "./setters/ITextSetter.sol";

/// @dev Interface selector: `0x64ba7075`
interface IPermissionedResolver is
    IEnhancedAccessControl,
    IExtendedResolver,
    IMulticallable,
    IABISetter,
    IAddressSetter,
    IContentHashSetter,
    IDataSetter,
    IInterfaceSetter,
    INameSetter,
    IPubkeySetter,
    ITextSetter
{
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `name` was associated with a record.
    ///         If `recordId = 0`, the `name` was unassociated.
    /// @param node The namehash of name.
    /// @param name The DNS-encoded name.
    /// @param recordId The record ID.
    event Linked(bytes32 indexed node, bytes name, uint256 indexed recordId);

    /// @notice Associate `recordId` with an EAC resource.
    /// @param recordId The record ID.
    /// @param resource The resource to associate.
    /// @param setter The ABI-encoded setter calldata.
    event RecordResource(uint256 indexed recordId, uint256 indexed resource, bytes setter);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Record does not exist.
    /// @dev Error selector: `0xf2a3e8db`
    error InvalidRecord();

    /// @notice Record was already unlinked.
    /// @dev Error selector: `0x5e053393`
    error AlreadyUnlinked();

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Authorize `roleBitmap` permissions to `account` for record of `name`.
    ///         Same as `{grant,revoke}RootRoles()` if name is root.
    /// @param name The DNS-encoded name.
    /// @param roleBitmap The roles bitmap to authorize.
    /// @param account The account to be authorize for roles.
    /// @param grant If `true`, grants, otherwise revokes.
    /// @return `true` if an authorization was changed.
    function authorizeRoles(bytes calldata name, uint256 roleBitmap, address account, bool grant)
        external
        returns (bool);

    /// @notice Authorize fine-grained permission to `account` for record of `name`.
    /// @param setter The ABI-encoded setter calldata to authorize.
    /// @param account The account to be authorize for role.
    /// @param grant If `true`, grants, otherwise revokes.
    /// @return `true` if an authorization was changed.
    function authorizeSubroles(bytes calldata setter, address account, bool grant)
        external
        returns (bool);

    /// @notice Associate `name` with `targetNode`.
    /// @param sourceName The DNS-encoded name to link.
    /// @param targetNode The target namehash or null to unlink.
    function link(bytes calldata sourceName, bytes32 targetNode) external;

    /// @notice Get the number of created records.
    function getRecordCount() external view returns (uint256);

    /// @notice Get the record linked to `node`.
    /// @param node The namehash to find.
    /// @return The record ID or 0 if not linked.
    function getRecordId(bytes32 node) external view returns (uint256);

    /// @notice Decode setter calldata into parts and corresponding role.
    /// @param setter The ABI-encoded setter calldata.
    /// @return name The DNS-encoded name from the setter.
    /// @return part The part hash from the setter's argument.
    /// @return roleBitmap The role bit corresponding to the setter selector.
    /// @return setterPrefix The ABI-encoded setter calldata without values.
    function decodeSetter(bytes calldata setter)
        external
        pure
        returns (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix);
}
