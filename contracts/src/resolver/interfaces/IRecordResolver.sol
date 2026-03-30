// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IDataResolver} from "@ens/contracts/resolvers/profiles/IDataResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";

import {IResolverSetters} from "./IResolverSetters.sol";

/// @dev The complete interface selector: `0xff38f248`
bytes4 constant RECORD_RESOLVER_INTERFACE_ID = type(IResolverSetters).interfaceId ^
    type(IABIResolver).interfaceId ^
    type(IAddressResolver).interfaceId ^
    type(IAddrResolver).interfaceId ^
    type(IContentHashResolver).interfaceId ^
    type(IDataResolver).interfaceId ^
    type(IHasAddressResolver).interfaceId ^
    type(IInterfaceResolver).interfaceId ^
    type(INameResolver).interfaceId ^
    type(IPubkeyResolver).interfaceId ^
    type(ITextResolver).interfaceId;

/// @dev Interface selector: `0x9323847d`
interface IRecordResolver is
    IResolverSetters,
    IABIResolver,
    IAddrResolver,
    IAddressResolver,
    IContentHashResolver,
    IDataResolver,
    IHasAddressResolver,
    IInterfaceResolver,
    INameResolver,
    IPubkeyResolver,
    ITextResolver
{
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `name` was associateed with a record.
    ///         If `recordId = 0`, the `name` was unassociated.
    /// @param node The namehash of name.
    /// @param name The DNS-encoded name.
    /// @param recordId The record ID.
    /// @param sender The caller address.
    event RecordLinked(
        bytes32 indexed node,
        bytes name,
        uint256 indexed recordId,
        address indexed sender
    );

    /// @notice All values of a record were cleared.
    /// @param recordId The new record ID.
    /// @param sender The caller address.
    event RecordCleared(uint256 indexed recordId, address indexed sender);

    /// @notice ABI data of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param contentType The content type bit.
    /// @param sender The caller address.
    event ABIUpdated(uint256 indexed recordId, uint256 indexed contentType, address indexed sender);

    /// @notice Address of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param coinType The coin type.
    /// @param addressBytes The new encoded address.
    /// @param sender The caller address.
    event AddressUpdated(
        uint256 indexed recordId,
        uint256 indexed coinType,
        bytes addressBytes,
        address indexed sender
    );

    /// @notice Content hash of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param contentHash The content hash.
    /// @param sender The caller address.
    event ContentHashUpdated(uint256 indexed recordId, bytes contentHash, address indexed sender);

    /// @notice Data for `key` of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param keyHash The hashed data key.
    /// @param key The data key.
    /// @param value The new data value.
    /// @param sender The caller address.
    event DataUpdated(
        uint256 indexed recordId,
        string indexed keyHash,
        string key,
        bytes value,
        address indexed sender
    );

    /// @notice Interface implementer for `interfaceId` of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param interfaceId The interface ID.
    /// @param implementer The new implementer address.
    /// @param sender The caller address.
    event InterfaceUpdated(
        uint256 indexed recordId,
        bytes4 indexed interfaceId,
        address implementer,
        address indexed sender
    );

    /// @notice Primary name of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param name The primary name.
    /// @param sender The new caller address.
    event NameUpdated(uint256 indexed recordId, string name, address indexed sender);

    /// @notice Pubkey of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param x The new x-coordinate.
    /// @param y The new y-coordinate.
    /// @param sender The new caller address.
    event PubkeyUpdated(uint256 indexed recordId, bytes32 x, bytes32 y, address indexed sender);

    /// @notice Text for `key` of a record was updated.
    /// @param recordId The record ID that was updated.
    /// @param keyHash The hashed data key.
    /// @param key The data key.
    /// @param value The new text value.
    /// @param sender The caller address.
    event TextUpdated(
        uint256 indexed recordId,
        string indexed keyHash,
        string key,
        string value,
        address indexed sender
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Record does not exist.
    /// @dev Error selector: `0xf2a3e8db`
    error InvalidRecord();

    /// @notice The resolver profile cannot be answered.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    /// @notice The address could not be converted to `address`.
    /// @dev Error selector: `0x8d666f60`
    error InvalidEVMAddress(bytes addressBytes);

    /// @notice The coin type is not a power of 2.
    /// @dev Error selector: `0x5742bb26`
    error InvalidContentType(uint256 contentType);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Clear record.
    /// @param name The DNS-encoded name.
    function clear(bytes calldata name) external;

    /// @notice Associate `name` with `targetNode`.
    /// @param name The DNS-encoded name to link.
    /// @param targetNode The target namehash or null to unlink.
    function link(bytes calldata name, bytes32 targetNode) external;

    /// @notice Find the record linked to `node`.
    /// @param node The namehash to find.
    /// @return The record ID or 0 if not linked.
    function getRecordId(bytes32 node) external view returns (uint256);
}
