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

/// @dev The complete interface selector: `0x604cb589`
bytes4 constant RECORD_RESOLVER_INTERFACE_ID = type(IABIResolver).interfaceId ^
    type(IAddressResolver).interfaceId ^
    type(IAddrResolver).interfaceId ^
    type(IContentHashResolver).interfaceId ^
    type(IDataResolver).interfaceId ^
    type(IHasAddressResolver).interfaceId ^
    type(IInterfaceResolver).interfaceId ^
    type(INameResolver).interfaceId ^
    type(IPubkeyResolver).interfaceId ^
    type(ITextResolver).interfaceId;

/// @dev Interface selector: `0x042c07b4`
interface IRecordResolver is
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

    /// @notice Associate `recordId` with `name`.
    ///         If `recordId = 0`, the association is cleared.
    event RecordLinked(
        bytes32 indexed node,
        bytes name,
        uint256 indexed recordId,
        address indexed sender
    );
    event RecordCleared(uint256 indexed recordId, address indexed sender);

    event ABIUpdated(uint256 indexed recordId, uint256 indexed contentType, address indexed sender);
    event AddressUpdated(
        uint256 indexed recordId,
        uint256 indexed coinType,
        bytes addressBytes,
        address indexed sender
    );
    event ContentHashUpdated(uint256 indexed recordId, bytes data, address indexed sender);
    event DataUpdated(
        uint256 indexed recordId,
        bytes32 indexed keyHash,
        string key,
        bytes data,
        address indexed sender
    );
    event InterfaceUpdated(
        uint256 indexed recordId,
        bytes4 indexed interfaceId,
        address implementor,
        address indexed sender
    );
    event NameUpdated(uint256 indexed recordId, string name, address indexed sender);
    event PubkeyUpdated(uint256 indexed recordId, bytes32 x, bytes32 y, address indexed sender);
    event TextUpdated(
        uint256 indexed recordId,
        bytes32 indexed keyHash,
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

    /// @notice Update a record.
    /// @param name The DNS-encoded name or `0x00` for default.
    /// @param setters The ABI-encoded `IRecordSetter` calldata.
    function update(bytes calldata name, bytes[] calldata setters) external;

    /// @notice Associate `name` with `targetName`.
    /// @param name The DNS-encoded name to link.
    /// @param targetNode The target namehash or null to unlink.
    function link(bytes calldata name, bytes32 targetNode) external;

    /// @notice Get the record associated with `node`.
    function getRecordId(bytes32 node) external view returns (uint256);
}
