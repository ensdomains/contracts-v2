// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";

import {IDataResolver} from "./IDataResolver.sol";

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
    event RecordName(uint256 indexed recordId, bytes32 indexed node, bytes name);

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

    /// @notice Create a new record, bind it to `name, and update it.
    /// @param name The DNS-encoded name.
    /// @param setters The ABI-encoded `IRecordSetter` calldata.
    /// @return recordId The new record ID.
    function createRecord(
        bytes calldata name,
        bytes[] calldata setters
    ) external returns (uint256 recordId);

    /// @notice Update an existing record by `name`.
    /// @param name The DNS-encoded name.
    /// @param setters The ABI-encoded `IRecordSetter` calldata.
    function updateRecordByName(bytes calldata name, bytes[] calldata setters) external;

    /// @notice Update an existing record by `recordId`.
    /// @param recordId The record ID.
    /// @param setters The ABI-encoded `IRecordSetter` calldata.
    function updateRecordById(uint256 recordId, bytes[] calldata setters) external;

    /// @notice Associate `name` with `recordId`.
    function bindRecord(bytes calldata name, uint256 recordId) external;

    // /// @notice Resolve `data` ignoring `node` and using `recordId` instead.
    // /// @dev Supports `multicall(bytes[])`.
    // /// @param recordId The record ID.
    // /// @param data The ABI-encoded resolver calldata.
    // /// @return The abi-encoded resolver response.
    // function resolveRecord(
    //     uint256 recordId,
    //     bytes calldata data
    // ) external view returns (bytes memory);

    /// @notice Get the record associated with `node`.
    function getRecordId(bytes32 node) external view returns (uint256);
}
