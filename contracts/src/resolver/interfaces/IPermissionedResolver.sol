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

/// @dev Interface selector: `0x8c2427cc`
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

    /// @notice Associate EAC resource with setter argument.
    /// @param resource The resource to associate.
    /// @param arg The setter argument.
    event ResourceArgument(uint256 indexed resource, bytes arg);

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

    /// @notice Authorize fine-grained permission to `account`.
    /// @param setter The ABI-encoded setter calldata to authorize.
    /// @param account The account to be authorize for role.
    /// @return `true` if an authorization was changed.
    function grantSetterRoles(bytes calldata setter, address account) external returns (bool);

    /// @notice Associate `sourceName` with `targetNode`.
    /// @param sourceName The DNS-encoded name to link from.
    /// @param targetNode The target namehash or null to unlink.
    function linkToNode(bytes calldata sourceName, bytes32 targetNode) external;

    /// @notice Associate `name` with `recordId`.
    /// @param sourceName The DNS-encoded name to link.
    /// @param recordId The record ID or 0 to unlink.
    function linkToRecord(bytes calldata sourceName, uint256 recordId) external;

    /// @notice Get the number of created records.
    function getRecordCount() external view returns (uint256);

    /// @notice Get the record linked to `node`.
    /// @param node The namehash to find.
    /// @return The record ID or 0 if not linked.
    function getRecordId(bytes32 node) external view returns (uint256);

    /// @notice Decode setter calldata into parts and corresponding role.
    /// @param setter The ABI-encoded setter calldata.
    /// @return arg The setter argument.
    /// @return resource The EAC resource.
    /// @return roleBitmap The corresponding role bit.
    function decodeSetter(bytes calldata setter)
        external
        pure
        returns (bytes memory arg, uint256 resource, uint256 roleBitmap);
}
