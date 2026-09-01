// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ENS} from "@ens/contracts/registry/ENS.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRegistry} from "../registry/interfaces/IRegistry.sol";

/// @title CustomResolver
/// @notice Test-only v1-style resolver holding the record subset the weighted
///         migration corpus writes, referenced by scenarios as
///         `fixture.CustomResolver`.
/// @dev Writes are authorised against the live ENS registry owner, so the
///      resolver follows ownership as scenarios transfer names around. It holds
///      no ENSv2 state.
contract CustomResolver is IERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev Interface id of the single-address resolver profile.
    bytes4 private constant _ADDR_INTERFACE_ID = 0x3b3b57de;
    /// @dev Interface id of the multicoin address resolver profile.
    bytes4 private constant _ADDR_COIN_INTERFACE_ID = 0xf1cb7e06;
    /// @dev Interface id of the text record resolver profile.
    bytes4 private constant _TEXT_INTERFACE_ID = 0x59d1d43c;
    /// @dev Interface id of the contenthash resolver profile.
    bytes4 private constant _CONTENTHASH_INTERFACE_ID = 0xbc1c58d1;

    /// @notice The v1 ENS registry consulted for write authorisation.
    ENS public immutable ENS_REGISTRY;

    mapping(bytes32 => mapping(uint256 => bytes)) private _addresses;
    mapping(bytes32 => mapping(string => string)) private _texts;
    mapping(bytes32 => bytes) private _contenthashes;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when the coin type 60 address changes.
    /// @param node The namehash of the name.
    /// @param a The new address.
    event AddrChanged(bytes32 indexed node, address a);

    /// @notice Emitted when an address of any coin type changes.
    /// @param node The namehash of the name.
    /// @param coinType The SLIP-44 coin type.
    /// @param newAddress The new address bytes.
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress);

    /// @notice Emitted when a text record changes.
    /// @param node The namehash of the name.
    /// @param indexedKey The record key, indexed.
    /// @param key The record key.
    /// @param value The new value.
    event TextChanged(bytes32 indexed node, string indexed indexedKey, string key, string value);

    /// @notice Emitted when the contenthash changes.
    /// @param node The namehash of the name.
    /// @param hash The new contenthash.
    event ContenthashChanged(bytes32 indexed node, bytes hash);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The caller does not control the node.
    /// @param node The namehash of the name.
    /// @param caller The unauthorised caller.
    /// @dev Error selector: `0x14c417b5`
    error NotAuthorised(bytes32 node, address caller);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param ensRegistry The v1 ENS registry to consult for authorisation.
    constructor(ENS ensRegistry) {
        ENS_REGISTRY = ensRegistry;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set the coin type 60 address.
    /// @param node The namehash of the name.
    /// @param a The address to record.
    function setAddr(bytes32 node, address a) external {
        _requireAuthorised(node);
        _addresses[node][60] = abi.encodePacked(a);
        emit AddrChanged(node, a);
    }

    /// @notice Set the address for an arbitrary coin type.
    /// @param node The namehash of the name.
    /// @param coinType The SLIP-44 coin type.
    /// @param a The address bytes; empty clears the record.
    function setAddr(bytes32 node, uint256 coinType, bytes calldata a) external {
        _requireAuthorised(node);
        _addresses[node][coinType] = a;
        emit AddressChanged(node, coinType, a);
    }

    /// @notice Set a text record.
    /// @param node The namehash of the name.
    /// @param key The record key.
    /// @param value The value; empty clears the record.
    function setText(bytes32 node, string calldata key, string calldata value) external {
        _requireAuthorised(node);
        _texts[node][key] = value;
        emit TextChanged(node, key, key, value);
    }

    /// @notice Set the contenthash.
    /// @param node The namehash of the name.
    /// @param hash The contenthash; empty clears the record.
    function setContenthash(bytes32 node, bytes calldata hash) external {
        _requireAuthorised(node);
        _contenthashes[node] = hash;
        emit ContenthashChanged(node, hash);
    }

    /// @notice Read the coin type 60 address.
    /// @param node The namehash of the name.
    /// @return The recorded address, or the zero address.
    function addr(bytes32 node) external view returns (address) {
        bytes memory raw = _addresses[node][60];
        if (raw.length != 20)
            return address(0);
        return address(bytes20(raw));
    }

    /// @notice Read the address for a coin type.
    /// @param node The namehash of the name.
    /// @param coinType The SLIP-44 coin type.
    /// @return The recorded address bytes.
    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory) {
        return _addresses[node][coinType];
    }

    /// @notice Read a text record.
    /// @param node The namehash of the name.
    /// @param key The record key.
    /// @return The recorded value.
    function text(bytes32 node, string calldata key) external view returns (string memory) {
        return _texts[node][key];
    }

    /// @notice Read the contenthash.
    /// @param node The namehash of the name.
    /// @return The recorded contenthash.
    function contenthash(bytes32 node) external view returns (bytes memory) {
        return _contenthashes[node];
    }

    /// @notice Report the resolver profiles this contract implements.
    /// @param interfaceId The interface id to probe.
    /// @return True when the profile is supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == _ADDR_INTERFACE_ID ||
            interfaceId == _ADDR_COIN_INTERFACE_ID ||
            interfaceId == _TEXT_INTERFACE_ID ||
            interfaceId == _CONTENTHASH_INTERFACE_ID;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Reverts unless the caller owns the node or is an approved operator.
    function _requireAuthorised(bytes32 node) internal view {
        address owner = ENS_REGISTRY.owner(node);
        if (owner != msg.sender && !ENS_REGISTRY.isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorised(node, msg.sender);
        }
    }
}


/// @title UnsupportedResolver
/// @notice Test-only resolver that stores records but denies every interface
///         probe, referenced by scenarios as `fixture.UnsupportedResolver`.
/// @dev Exercises how migration treats a resolver it cannot recognise. Reads
///      succeed; only interface detection fails.
contract UnsupportedResolver {
    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    mapping(bytes32 => address) private _addresses;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when the recorded address changes.
    /// @param node The namehash of the name.
    /// @param a The new address.
    event AddrChanged(bytes32 indexed node, address a);

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set the recorded address.
    /// @param node The namehash of the name.
    /// @param a The address to record.
    function setAddr(bytes32 node, address a) external {
        _addresses[node] = a;
        emit AddrChanged(node, a);
    }

    /// @notice Read the recorded address.
    /// @param node The namehash of the name.
    /// @return The recorded address.
    function addr(bytes32 node) external view returns (address) {
        return _addresses[node];
    }

    /// @notice Always reports no support, including for ERC-165 itself.
    /// @return False, for every interface id.
    /// @dev Deliberate: this is the property the fixture exists to provide.
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}


/// @title ERC1155ReceiverOwner
/// @notice Test-only contract owner that accepts both ENS token standards,
///         referenced by scenarios as `fixture.ERC1155ReceiverOwner`.
contract ERC1155ReceiverOwner is IERC721Receiver, IERC1155Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Accept an ERC-721 token.
    /// @return The ERC-721 receiver magic value.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Accept a single ERC-1155 token.
    /// @return The ERC-1155 receiver magic value.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @notice Accept a batch of ERC-1155 tokens.
    /// @return The ERC-1155 batch receiver magic value.
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @notice Report the receiver interfaces this contract implements.
    /// @param interfaceId The interface id to probe.
    /// @return True when the interface is supported.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId;
    }
}


/// @title NonReceiverOwner
/// @notice Test-only contract owner that implements no token receiver hook,
///         referenced by scenarios as `fixture.NonReceiverOwner`.
/// @dev Migrating a name to this address must revert; scenarios assert the
///      transfer is rejected rather than stranding a token.
contract NonReceiverOwner {
    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Exists only so the address has code.
    /// @return Always true.
    function ping() external pure returns (bool) {
        return true;
    }
}


/// @title CustomSubregistry
/// @notice Test-only subregistry pointer for migration payloads that name a
///         custom one, referenced by scenarios as `fixture.CustomSubregistry`.
/// @dev Holds no names. It exists so a scenario can pass a non-zero, non-default
///      subregistry and assert how each route treats it — the locked 2LD path
///      ignores it in favour of the deterministic WrapperRegistry.
contract CustomSubregistry is IRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The registry reported as this one's parent.
    IRegistry public parentRegistry;

    /// @notice The label reported as this registry's location under its parent.
    string public parentLabel;

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set the parent this registry reports.
    /// @param parent_ The parent registry.
    /// @param label_ The label under that parent.
    function setParent(IRegistry parent_, string calldata label_) external {
        parentRegistry = parent_;
        parentLabel = label_;
    }

    /// @notice Always reports no subregistry.
    /// @return The zero registry.
    function getSubregistry(string calldata) external pure returns (IRegistry) {
        return IRegistry(address(0));
    }

    /// @notice Always reports no resolver.
    /// @return The zero address.
    function getResolver(string calldata) external pure returns (address) {
        return address(0);
    }

    /// @notice Report the configured parent location.
    /// @return parent The parent registry.
    /// @return label The label under that parent.
    function getParent() external view returns (IRegistry parent, string memory label) {
        return (parentRegistry, parentLabel);
    }
}
