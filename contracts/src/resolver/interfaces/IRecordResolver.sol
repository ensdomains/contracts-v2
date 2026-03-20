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

    /// @notice Set address for `coinType`.
    /// @param name The DNS-encoded name.
    /// @param coinType The coin type.
    /// @param addressBytes The encoded address.
    function setAddress(
        bytes calldata name,
        uint256 coinType,
        bytes calldata addressBytes
    ) external;

    /// @notice Set data for `key`.
    /// @param name The DNS-encoded name.
    /// @param key The data key.
    /// @param data The data.
    function setData(bytes calldata name, string calldata key, bytes calldata data) external;

    /// @notice Set text for `key`.
    /// @param name The DNS-encoded name.
    /// @param key The text key.
    /// @param value The text value.
    function setText(bytes calldata name, string calldata key, string calldata value) external;

    /// @notice Set the contenthash.
    /// @param name The DNS-encoded name.
    /// @param contentHash The content hash.
    function setContentHash(bytes calldata name, bytes calldata contentHash) external;

    /// @notice Set ABI data for `contentType`.
    /// @param name The DNS-encoded name.
    /// @param contentType The content type bit of the ABI encoding.
    /// @param data The encoded ABI data.
    function setABI(bytes calldata name, uint256 contentType, bytes calldata data) external;

    /// @notice Set the primary name.
    /// @param name The DNS-encoded name.
    /// @param fqdn The name.
    function setName(bytes calldata name, string calldata fqdn) external;

    /// @notice Set implementer for `interfaceId`.
    /// @param name The DNS-encoded name.
    /// @param interfaceId The EIP-165 interface ID.
    /// @param implementer The address of the contract that implements this interface.
    function setInterface(bytes calldata name, bytes4 interfaceId, address implementer) external;

    /// @notice Set the SECP256k1 public key associated with an ENS node.
    /// @param name The DNS-encoded name.
    /// @param x The x coordinate of the public key.
    /// @param y The y coordinate of the public key.
    function setPubkey(bytes calldata name, bytes32 x, bytes32 y) external;

    /// @notice Clears a record.
    /// @param name The DNS-encoded name.
    function clear(bytes calldata name) external;

    /// @notice Associate `name` with `targetNode`.
    /// @param name The DNS-encoded name to link.
    /// @param targetNode The target namehash or null to unlink.
    function link(bytes calldata name, bytes32 targetNode) external;

    /// @notice Get the record associated with `node`.
    function getRecordId(bytes32 node) external view returns (uint256);
}
