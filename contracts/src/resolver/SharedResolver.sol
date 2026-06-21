// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/Multicallable.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IDataResolver} from "@ens/contracts/resolvers/profiles/IDataResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ENSIP19, COIN_TYPE_ETH, COIN_TYPE_DEFAULT} from "@ens/contracts/utils/ENSIP19.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {IAddressSetter} from "./interfaces/setters/IAddressSetter.sol";
import {IContentHashSetter} from "./interfaces/setters/IContentHashSetter.sol";
import {IDataSetter} from "./interfaces/setters/IDataSetter.sol";
import {IInterfaceSetter} from "./interfaces/setters/IInterfaceSetter.sol";
import {INameSetter} from "./interfaces/setters/INameSetter.sol";
import {IPubkeySetter} from "./interfaces/setters/IPubkeySetter.sol";
import {ITextSetter} from "./interfaces/setters/ITextSetter.sol";

/// @notice PublicResolver that respects the ENSv2 registry and uses name-based setters.
contract SharedResolver is
    DelegatedContractNamer,
    IExtendedResolver,
    IERC7996,
    IMulticallable,
    IAddressSetter,
    IContentHashSetter,
    IDataSetter,
    IInterfaceSetter,
    INameSetter,
    IPubkeySetter,
    ITextSetter
{
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct RecordPointer {
        uint256 version;
        mapping(uint256 version => Record record) records;
    }

    struct Record {
        bytes contentHash;
        bytes32[2] pubkey;
        string name;
        mapping(uint256 coinType => bytes addressBytes) addresses;
        mapping(string key => string value) texts;
        mapping(string key => bytes value) datas;
        mapping(uint256 contentType => bytes value) abis;
        mapping(bytes4 interfaceId => address implementer) interfaces;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2  Root Registry contract.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev A mapping from `node` to `RecordPointer`.
    mapping(bytes32 node => RecordPointer pointer) internal _pointers;

    /// @dev A mapping from `(owner, operator, node)` to approval state.
    mapping(address owner => mapping(address operator => mapping(bytes32 node => bool approved))) internal _approvals;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice All records for `name` were cleared.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    event Cleared(bytes32 indexed node, bytes name);

    /// @notice Authorization for `name` has changed.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    /// @param owner The owner account.
    /// @param operator The authorized account.
    /// @param approved The authorization state.
    event ApprovalUpdated(
        bytes32 indexed node,
        bytes name,
        address indexed owner,
        address indexed operator,
        bool approved
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Caller cannot modify name.
    /// @dev Error selector: `0x76652b32`
    error CannotModifyName(bytes name);

    /// @notice The resolver profile cannot be answered.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The ENSv2 Root Registry contract.
    /// @param contractNamer Delegated contract namer.
    constructor(IPermissionedRegistry rootRegistry, IContractNamer contractNamer)
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
    }

    /// @inheritdoc DelegatedContractNamer
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IExtendedResolver).interfaceId ||
            interfaceId == type(IERC7996).interfaceId ||
            interfaceId == type(IMulticallable).interfaceId ||
            interfaceId == type(IAddressSetter).interfaceId ||
            interfaceId == type(IContentHashSetter).interfaceId ||
            interfaceId == type(IDataSetter).interfaceId ||
            interfaceId == type(IInterfaceSetter).interfaceId ||
            interfaceId == type(INameSetter).interfaceId ||
            interfaceId == type(IPubkeySetter).interfaceId ||
            interfaceId == type(ITextSetter).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC7996
    function supportsFeature(bytes4 feature) external pure returns (bool) {
        return ResolverFeatures.RESOLVE_MULTICALL == feature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Authorize `operator` for `name`.
    /// @dev Use root name to authorize all names.
    /// @param name The DNS-encoded name.
    /// @param operator The account to authorize.
    /// @param approved The authorization state.
    function approve(bytes calldata name, address operator, bool approved) external {
        bytes32 node = NameCoder.namehash(name, 0);
        _approvals[msg.sender][operator][node] = approved;
        emit ApprovalUpdated(node, name, msg.sender, operator, approved);
    }

    /// @notice Clear all records for `name`.
    /// @param name The DNS-encoded name.
    function clear(bytes calldata name) external {
        bytes32 node = _checkAuth(name);
        ++_pointers[node].version;
        emit Cleared(node, name);
    }

    /// @inheritdoc IAddressSetter
    function setAddress(bytes calldata name, uint256 coinType, bytes calldata addressBytes)
        external
    {
        bytes32 node = _checkAuth(name);
        if (
            addressBytes.length != 0 && addressBytes.length != 20 && ENSIP19.isEVMCoinType(coinType)
        ) {
            revert InvalidEVMAddress(addressBytes);
        }
        _record(node).addresses[coinType] = addressBytes;
        emit AddressUpdated(node, name, coinType, addressBytes);
    }

    /// @inheritdoc IContentHashSetter
    function setContentHash(bytes calldata name, bytes calldata contentHash) external {
        bytes32 node = _checkAuth(name);
        _record(node).contentHash = contentHash;
        emit ContentHashUpdated(node, name, contentHash);
    }

    /// @inheritdoc IDataSetter
    function setData(bytes calldata name, string calldata key, bytes calldata value) external {
        bytes32 node = _checkAuth(name);
        _record(node).datas[key] = value;
        emit DataUpdated(node, name, key, key, value);
    }

    /// @inheritdoc IInterfaceSetter
    function setInterface(bytes calldata name, bytes4 interfaceId, address implementer) external {
        bytes32 node = _checkAuth(name);
        _record(node).interfaces[interfaceId] = implementer;
        emit InterfaceUpdated(node, name, interfaceId, implementer);
    }

    /// @inheritdoc INameSetter
    function setName(bytes calldata name, string calldata primaryName) external {
        bytes32 node = _checkAuth(name);
        _record(node).name = primaryName;
        emit NameUpdated(node, name, primaryName);
    }

    /// @inheritdoc IPubkeySetter
    function setPubkey(bytes calldata name, bytes32 x, bytes32 y) external {
        bytes32 node = _checkAuth(name);
        _record(node).pubkey = [x, y];
        emit PubkeyUpdated(node, name, x, y);
    }

    /// @inheritdoc ITextSetter
    function setText(bytes calldata name, string calldata key, string calldata value) external {
        bytes32 node = _checkAuth(name);
        _record(node).texts[key] = value;
        emit TextUpdated(node, name, key, key, value);
    }

    /// @notice Same as `multicall()`.
    /// @param {node} Ignored, for interface compatibility.
    /// @param calls The calls to make.
    /// @return results The results of the calls.
    function multicallWithNodeCheck(
        bytes32 /*node*/,
        bytes[] calldata calls
    )
        external
        returns (bytes[] memory)
    {
        return multicall(calls);
    }

    /// @notice Determine if `operator` is authorized.
    /// @param name The name to check.
    /// @param operator The account requesting authorization.
    /// @return `true` if authorized.
    function canModifyName(bytes calldata name, address operator) external view returns (bool) {
        return _canModifyNode(ownerOf(name), operator, NameCoder.namehash(name, 0));
    }

    /// @notice Check if `operator` is approved by `owner` for `name`.
    /// @param name The DNS-encoded name.
    /// @param owner The owner account.
    /// @param operator The authorized account.
    /// @return `true` if `operator` is approved.
    function isApproved(bytes calldata name, address owner, address operator)
        external
        view
        returns (bool)
    {
        return _approvals[owner][operator][NameCoder.namehash(name, 0)];
    }

    /// @inheritdoc IMulticallable
    /// @notice Perform multiple write operations.
    /// @dev Reverts with first error.
    /// @param calls The calls to make.
    /// @return results The results of the calls.
    function multicall(bytes[] calldata calls) public returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory v) = address(this).delegatecall(calls[i]);
            if (!ok) {
                assembly {
                    revert(add(v, 32), mload(v)) // propagate the first error
                }
            }
            results[i] = v;
        }
    }

    /// @inheritdoc IExtendedResolver
    /// @dev The first argument of data (`bytes32 node`) is ignored.
    function resolve(bytes calldata name, bytes calldata data) public view returns (bytes memory) {
        bytes4 selector = bytes4(data);
        if (selector == IMulticallable.multicall.selector) {
            bytes[] memory m = abi.decode(data[4:], (bytes[]));
            for (uint256 i; i < m.length; ++i) {
                try this.resolve(name, m[i]) returns (bytes memory v) {
                    m[i] = v;
                } catch (bytes memory v) {
                    unchecked {
                        uint256 pad = (4 - v.length) & 31;
                        if (pad > 0) {
                            v = abi.encodePacked(v, new bytes(pad));
                        }
                    }
                    m[i] = v;
                }
            }
            return abi.encode(m); // bytes[]
        }
        Record storage r = _record(NameCoder.namehash(name, 0));
        if (selector == IAddrResolver.addr.selector) {
            return abi.encode(_getAddr(r)); // address
        } else if (selector == IAddressResolver.addr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(_getAddress(r, coinType)); // bytes
        } else if (selector == ITextResolver.text.selector) {
            (, string memory key) = abi.decode(data[4:], (bytes32, string));
            return abi.encode(r.texts[key]); // string
        } else if (selector == IDataResolver.data.selector) {
            (, string memory key) = abi.decode(data[4:], (bytes32, string));
            return abi.encode(r.datas[key]); // bytes
        } else if (selector == INameResolver.name.selector) {
            return abi.encode(r.name); // string
        } else if (selector == IContentHashResolver.contenthash.selector) {
            return abi.encode(r.contentHash); // bytes
        } else if (selector == IHasAddressResolver.hasAddr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(r.addresses[coinType].length > 0); // boolean
        } else if (selector == IPubkeyResolver.pubkey.selector) {
            return abi.encode(r.pubkey);
        } else if (selector == IInterfaceResolver.interfaceImplementer.selector) {
            (, bytes4 interfaceId) = abi.decode(data[4:], (bytes32, bytes4));
            address implementer = r.interfaces[interfaceId];
            if (implementer == address(0)) {
                address pointer = _getAddr(r);
                if (ERC165Checker.supportsInterface(pointer, interfaceId)) {
                    implementer = pointer;
                }
            }
            return abi.encode(implementer); // address
        } else {
            revert UnsupportedResolverProfile(selector);
        }
    }

    /// @notice Find the owner for `name`.
    /// @param name The DNS-encoded name.
    /// @return The owner address or null if unowned or not found.
    function ownerOf(bytes calldata name) public view returns (address) {
        return LibRegistry.findOwner(ROOT_REGISTRY, name, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Determine if `operator` can modify `node`.
    function _canModifyNode(address owner, address operator, bytes32 node)
        internal
        view
        returns (bool can)
    {
        if (owner != address(0)) {
            can = owner == operator;
            if (!can) {
                mapping(bytes32 node => bool approved) storage approvals =
                    _approvals[owner][operator];
                can = approvals[node];
                if (!can && node != 0) {
                    can = approvals[0];
                }
            }
        }
    }

    /// @dev Ensure `name` can be modified by caller.
    function _checkAuth(bytes calldata name) internal view returns (bytes32 node) {
        node = NameCoder.namehash(name, 0);
        if (!_canModifyNode(ownerOf(name), msg.sender, node)) {
            revert CannotModifyName(name);
        }
    }

    /// @dev Get the active storage record.
    function _record(bytes32 node) internal view returns (Record storage) {
        RecordPointer storage p = _pointers[node];
        return p.records[p.version];
    }

    /// @dev Determine address according to ENSIP-19.
    function _getAddress(Record storage r, uint256 coinType)
        internal
        view
        returns (bytes storage addressBytes)
    {
        addressBytes = r.addresses[coinType];
        if (addressBytes.length == 0 && ENSIP19.chainFromCoinType(coinType) > 0) {
            addressBytes = r.addresses[COIN_TYPE_DEFAULT];
        }
    }

    /// @dev Convenience for mainnet address.
    function _getAddr(Record storage r) internal view returns (address) {
        return address(bytes20(_getAddress(r, COIN_TYPE_ETH)));
    }
}
