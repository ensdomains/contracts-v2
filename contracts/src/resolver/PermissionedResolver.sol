// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
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
import {ENSIP19, COIN_TYPE_ETH, COIN_TYPE_DEFAULT} from "@ens/contracts/utils/ENSIP19.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {IEnhancedAccessControl} from "../access-control/interfaces/IEnhancedAccessControl.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {HCAContext} from "../hca/HCAContext.sol";
import {HCAContextUpgradeable} from "../hca/HCAContextUpgradeable.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {
    IPermissionedResolver,
    PERMISSIONED_RESOLVER_INTERFACE_ID
} from "./interfaces/IPermissionedResolver.sol";
import {IRecordResolver, RECORD_RESOLVER_INTERFACE_ID} from "./interfaces/IRecordResolver.sol";
import {IResolverSetters} from "./interfaces/IResolverSetters.sol";
import {PermissionedResolverLib} from "./libraries/PermissionedResolverLib.sol";

/// @notice A resolver that supports many profiles, multiple names, linked records, and fine-grained permissions.
///
/// Supported profiles and standards:
///
/// * ENSIP-1 / EIP-137: addr()
/// * ENSIP-3 / EIP-181: name()
/// * ENSIP-4 / EIP-205: ABI(contentTypes)
/// * EIP-619: pubkey()
/// * ENSIP-5 / EIP-634: text(key)
/// * ENSIP-7 / EIP-1577: contenthash()
/// * ENSIP-8: interfaceImplementer(interfaceId)
/// * ENSIP-9 / EIP-2304: addr(coinType)
/// * ENSIP-19: addr(default)
/// * ENSIP-24: data(key)
/// * IHasAddressResolver: hasAddr(coinType)
///
/// Records are created automatically by setters and assigned internal ID numbers (starting at 1).
/// To create a new record, `ROLE_NEW_RECORD` is required on root.
/// `getRecordId(node)` reveals the internal record ID.
///
/// `link(name, node)` makes `name` use the record currently used by `node`.
/// To link an existing record, `ROLE_LINK_RECORD` is required on root.
///
/// `link(name, bytes32(0))` unlinks `name` from the record.
/// Once a record is no longer referenced, it becomes unreachable and is effectively deleted.
///
/// `clear(name)` reset the record and requires `ROLE_CLEAR_RECORD` on the name or root.
///
/// Names without a record fall back to the default record, which can be updated using the empty name (`0x00`).
///
/// Every record setter has the form: `f(name, ...)`
///
/// Every record setter has a corresponding role:
/// | Function           | Role                   |
/// | ------------------ | ---------------------- |
/// | `setABI()`         | `ROLE_SET_ABI`         |
/// | `setAddress()`     | `ROLE_SET_ADDRESS`     |
/// | `setContentHash()` | `ROLE_SET_CONTENTHASH` |
/// | `setData()`        | `ROLE_SET_DATA`        |
/// | `setInterface()`   | `ROLE_SET_INTERFACE`   |
/// | `setName()`        | `ROLE_SET_NAME`        |
/// | `setText()`        | `ROLE_SET_TEXT`        |
///
/// Record setters can be granted with `getRecordRoles()` and are annotated
/// using ABI-encoded calldata: `abi.encodeWithSelector(bytes4(0), name)`.
///
/// Fine-grained record setters have the form: `f(name, <arg>, ...)`
/// They can be granted with `grantSetterRoles()` and are annotated
/// using truncated ABI-encoded calldata:
/// * w/data: `abi.encodeCall(setAddr, (name, coinType, "..."))`
/// * w/o data: `abi.encodeCall(setAddr, (name coinType, ""))`
/// * truncated: `abi.encodeWithSelector(setAddr.selector, name, coinType)`
/// The `roleBitmap` can be derived from the setter selector.
///
/// The following setters are fine-grained:
/// * `setAddress(name, coinType, ...)`
/// * `setData(name, key, ...)`
/// * `setText(name, key, ...)`
/// * `setABI(name, contentType, ...)`
/// * `setInterface(name, interfaceId, ...)`
///
/// The argument is hashed accordingly:
/// | Argument      | Part                                    |
/// | ------------- | --------------------------------------- |
/// | `uint256 arg` | `PermissionedResolverLib.partHash(arg)` |
/// | `string arg`  | `PermissionedResolverLib.partHash(arg)` |
/// | `bytes4 arg`  | `PermissionedResolverLib.partHash(arg)` |
///
/// Record setters check (4) EAC resources:
///                                                      Part Hash
///             Resources      +-----------------------------+----------------------------------+
///                            |           Any (*)           |           Specific (1)           |
///             +--------------+-----------------------------+----------------------------------+
///             |      Any (*) |       resource(0, 0)        |      resource(0, <partHash>)     |
///  Record ID  |--------------+-----------------------------+----------------------------------+
///             | Specific (1) |   resource(<recordId>, 0)   | resource(<recordId>, <partHash>) |
///             +--------------+-----------------------------+----------------------------------+
///
/// eg. `setText(name, "key", ...)` with `recordId = getRecordId(namehash(name))`
///      will check the following resources for `ROLE_SET_TEXT` permission:
/// 1. `resource(recordId, partHash("key"))` => `arg="key"` for that record
/// 2. `resource(recordId, 0)` => ANY part of that record
/// 3. `resource(0, partHash("key"))` => `arg="key"` for ANY record
/// 4. `resource(0, 0)` => ANY part of ANY record
///
contract PermissionedResolver is
    EnhancedAccessControl,
    HCAContextUpgradeable,
    IPermissionedResolver,
    IMulticallable,
    UUPSUpgradeable
{
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct Record {
        bytes contentHash;
        bytes32[2] pubkey;
        string name;
        mapping(uint256 coinType => bytes addressBytes) addresses;
        mapping(string key => bytes data) datas;
        mapping(string key => string value) texts;
        mapping(uint256 contentType => bytes data) abis;
        mapping(bytes4 interfaceId => address implementer) interfaces;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Number of records created.
    uint256 internal _recordCount;

    /// @dev Mapping from `node` to `recordId`.
    mapping(bytes32 node => uint256 recordId) internal _recordIds;

    /// @dev Mapping from `recordId` to `version`.
    mapping(uint256 recordId => uint256 version) internal _versions;

    /// @dev Mapping from `(recordId, version)` to `Record`.
    mapping(uint256 recordId => mapping(uint256 version => Record record)) internal _records;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates the PermissionedResolver implementation.
    /// @param hcaFactory The HCA factory.
    constructor(IHCAFactoryBasic hcaFactory) HCAEquivalence(hcaFactory) {
        _disableInitializers();
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(IERC165, EnhancedAccessControl) returns (bool) {
        return
            PERMISSIONED_RESOLVER_INTERFACE_ID == interfaceId ||
            RECORD_RESOLVER_INTERFACE_ID == interfaceId ||
            type(IPermissionedResolver).interfaceId == interfaceId ||
            type(IRecordResolver).interfaceId == interfaceId ||
            type(IResolverSetters).interfaceId == interfaceId ||
            type(IMulticallable).interfaceId == interfaceId ||
            type(UUPSUpgradeable).interfaceId == interfaceId ||
            // profiles
            type(IABIResolver).interfaceId == interfaceId ||
            type(IAddrResolver).interfaceId == interfaceId ||
            type(IAddressResolver).interfaceId == interfaceId ||
            type(IContentHashResolver).interfaceId == interfaceId ||
            type(IDataResolver).interfaceId == interfaceId ||
            type(IHasAddressResolver).interfaceId == interfaceId ||
            type(IInterfaceResolver).interfaceId == interfaceId ||
            type(INameResolver).interfaceId == interfaceId ||
            type(IPubkeyResolver).interfaceId == interfaceId ||
            type(ITextResolver).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Initialize the resolver.
    /// @param initialAccount The account granted roles.
    /// @param roleBitmap The roles granted to `initialAccount` on root.
    function initialize(address initialAccount, uint256 roleBitmap) external initializer {
        if (initialAccount == address(0)) {
            revert InvalidOwner();
        }
        __UUPSUpgradeable_init();
        _grantRoles(ROOT_RESOURCE, roleBitmap, initialAccount, false);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IResolverSetters
    function setABI(bytes calldata name_, uint256 contentType, bytes calldata data_) external {
        if (!_isPowerOf2(contentType)) {
            revert InvalidContentType(contentType);
        }
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_ABI,
            PermissionedResolverLib.partHash(contentType),
            sender
        );
        _record(recordId).abis[contentType] = data_;
        emit ABIUpdated(recordId, contentType, sender);
    }

    /// @inheritdoc IResolverSetters
    function setAddress(
        bytes calldata name_,
        uint256 coinType,
        bytes calldata addressBytes
    ) external {
        if (
            addressBytes.length != 0 && addressBytes.length != 20 && ENSIP19.isEVMCoinType(coinType)
        ) {
            revert InvalidEVMAddress(addressBytes);
        }
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_ADDRESS,
            PermissionedResolverLib.partHash(coinType),
            sender
        );
        _record(recordId).addresses[coinType] = addressBytes;
        emit AddressUpdated(recordId, coinType, addressBytes, sender);
    }

    /// @inheritdoc IResolverSetters
    function setContentHash(bytes calldata name_, bytes calldata contentHash) external {
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_CONTENTHASH,
            bytes32(0),
            sender
        );
        _record(recordId).contentHash = contentHash;
        emit ContentHashUpdated(recordId, contentHash, sender);
    }

    /// @inheritdoc IResolverSetters
    function setData(bytes calldata name_, string calldata key, bytes calldata value) external {
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_DATA,
            PermissionedResolverLib.partHash(key),
            sender
        );
        _record(recordId).datas[key] = value;
        emit DataUpdated(recordId, key, key, value, sender);
    }

    /// @inheritdoc IResolverSetters
    function setInterface(bytes calldata name_, bytes4 interfaceId, address implementer) external {
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_INTERFACE,
            PermissionedResolverLib.partHash(interfaceId),
            sender
        );
        _record(recordId).interfaces[interfaceId] = implementer;
        emit InterfaceUpdated(recordId, interfaceId, implementer, sender);
    }

    /// @inheritdoc IResolverSetters
    function setName(bytes calldata name_, string calldata primaryName) external {
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(recordId, PermissionedResolverLib.ROLE_SET_NAME, bytes32(0), sender);
        _record(recordId).name = primaryName;
        emit NameUpdated(recordId, primaryName, sender);
    }

    /// @inheritdoc IResolverSetters
    function setPubkey(bytes calldata name_, bytes32 x, bytes32 y) external {
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(recordId, PermissionedResolverLib.ROLE_SET_PUBKEY, bytes32(0), sender);
        _record(recordId).pubkey = [x, y];
        emit PubkeyUpdated(recordId, x, y, sender);
    }

    /// @inheritdoc IResolverSetters
    function setText(bytes calldata name_, string calldata key, string calldata value) external {
        uint256 recordId = _ensureRecord(name_);
        address sender = _msgSender();
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_TEXT,
            PermissionedResolverLib.partHash(key),
            sender
        );
        _record(recordId).texts[key] = value;
        emit TextUpdated(recordId, key, key, value, sender);
    }

    /// @inheritdoc IRecordResolver
    function clear(bytes calldata name_) external {
        uint256 recordId = _recordIds[NameCoder.namehash(name_, 0)];
        if (recordId > 0) {
            address sender = _msgSender();
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_CLEAR_RECORD,
                bytes32(0),
                sender
            );
            ++_versions[recordId];
            emit RecordCleared(recordId, sender);
        }
    }

    /// @inheritdoc IRecordResolver
    function link(
        bytes calldata sourceName,
        bytes32 targetNode
    ) external onlyRootRoles(PermissionedResolverLib.ROLE_LINK_RECORD) {
        bytes32 sourceNode = NameCoder.namehash(sourceName, 0);
        uint256 recordId;
        if (targetNode == bytes32(0)) {
            if (_recordIds[sourceNode] == 0) {
                revert InvalidRecord(); // already unlinked
            }
        } else {
            recordId = _recordIds[targetNode];
            if (recordId == 0) {
                revert InvalidRecord(); // unknown target
            }
        }
        _recordIds[sourceNode] = recordId;
        emit RecordLinked(sourceNode, sourceName, recordId, _msgSender());
    }

    /// @inheritdoc IPermissionedResolver
    function grantRecordRoles(
        bytes calldata name_,
        uint256 roleBitmap,
        address account
    ) external returns (bool) {
        uint256 recordId = _ensureRecordExceptDefault(name_);
        uint256 resource = PermissionedResolverLib.resource(recordId);
        _checkCanGrantRoles(resource, roleBitmap, _msgSender());
        if (roleCount(resource) == 0) {
            emit RecordResource(recordId, resource, PermissionedResolverLib.anySetter(name_));
        }
        return _grantRoles(resource, roleBitmap, account, true);
    }

    /// @inheritdoc IPermissionedResolver
    function grantSetterRoles(bytes calldata setter, address account) external returns (bool) {
        bytes memory name_;
        bytes32 part;
        uint256 roleBitmap;
        bytes memory compactSetter;
        bytes4 selector = bytes4(setter);
        if (selector == this.setAddress.selector) {
            uint256 coinType;
            (name_, coinType) = abi.decode(setter[4:], (bytes, uint256));
            part = PermissionedResolverLib.partHash(coinType);
            roleBitmap = PermissionedResolverLib.ROLE_SET_ADDRESS;
            compactSetter = abi.encodeWithSelector(selector, name_, coinType);
        } else if (selector == this.setText.selector) {
            string memory key;
            (name_, key) = abi.decode(setter[4:], (bytes, string));
            part = PermissionedResolverLib.partHash(key);
            roleBitmap = PermissionedResolverLib.ROLE_SET_TEXT;
            compactSetter = abi.encodeWithSelector(selector, name_, key);
        } else if (selector == this.setData.selector) {
            string memory key;
            (name_, key) = abi.decode(setter[4:], (bytes, string));
            part = PermissionedResolverLib.partHash(key);
            roleBitmap = PermissionedResolverLib.ROLE_SET_DATA;
            compactSetter = abi.encodeWithSelector(selector, name_, key);
        } else if (selector == this.setABI.selector) {
            uint256 contentType;
            (name_, contentType) = abi.decode(setter[4:], (bytes, uint256));
            part = PermissionedResolverLib.partHash(contentType);
            roleBitmap = PermissionedResolverLib.ROLE_SET_ABI;
            compactSetter = abi.encodeWithSelector(selector, name_, contentType);
        } else if (selector == this.setInterface.selector) {
            bytes4 interfaceId;
            (name_, interfaceId) = abi.decode(setter[4:], (bytes, bytes4));
            part = PermissionedResolverLib.partHash(interfaceId);
            roleBitmap = PermissionedResolverLib.ROLE_SET_INTERFACE;
            compactSetter = abi.encodeWithSelector(selector, name_, interfaceId);
        } else {
            revert UnsupportedResolverProfile(selector);
        }
        assert(part != bytes32(0));
        uint256 recordId = _ensureRecordExceptDefault(name_);
        uint256 resource = PermissionedResolverLib.resource(recordId, part);
        _checkCanGrantRoles(PermissionedResolverLib.resource(recordId), roleBitmap, _msgSender());
        if (roleCount(resource) == 0) {
            emit RecordResource(recordId, resource, compactSetter);
        }
        return _grantRoles(resource, roleBitmap, account, true);
    }

    /// @notice Same as `multicall()`.
    /// @dev The node parameter is accepted for interface compatibility but is not used.
    ///      Permission are checked by individual function calls within the multicall.
    /// @param {node} Ignored, for interface compatibility.
    /// @param calls The calls to make.
    /// @return results The results of the calls.
    function multicallWithNodeCheck(
        bytes32 /* node */,
        bytes[] calldata calls
    ) external returns (bytes[] memory) {
        return multicall(calls);
    }

    /// @inheritdoc IABIResolver
    function ABI(
        bytes32 node,
        uint256 contentTypes
    ) external view returns (uint256 contentType, bytes memory encodedData) {
        Record storage record = _record(node);
        for (uint256 bit = 1; bit > 0 && bit <= contentTypes; bit <<= 1) {
            if ((bit & contentTypes) != 0) {
                bytes memory v = record.abis[bit];
                if (v.length > 0) {
                    return (bit, v);
                }
            }
        }
    }

    /// @inheritdoc IAddrResolver
    function addr(bytes32 node) external view returns (address payable) {
        return payable(_getAddr(_record(node)));
    }

    /// @inheritdoc IAddressResolver
    function addr(
        bytes32 node,
        uint256 coinType
    ) external view returns (bytes memory addressBytes) {
        return _getAddress(_record(node), coinType);
    }

    /// @inheritdoc IContentHashResolver
    function contenthash(bytes32 node) external view returns (bytes memory) {
        return _record(node).contentHash;
    }

    /// @inheritdoc IDataResolver
    function data(bytes32 node, string calldata key) external view returns (bytes memory) {
        return _record(node).datas[key];
    }

    /// @inheritdoc IHasAddressResolver
    function hasAddr(bytes32 node, uint256 coinType) external view returns (bool) {
        return _record(node).addresses[coinType].length > 0;
    }

    /// @inheritdoc IInterfaceResolver
    function interfaceImplementer(
        bytes32 node,
        bytes4 interfaceId
    ) external view returns (address implementer) {
        Record storage record = _record(node);
        implementer = record.interfaces[interfaceId];
        if (implementer == address(0)) {
            address pointer = _getAddr(record);
            if (ERC165Checker.supportsInterface(pointer, interfaceId)) {
                implementer = pointer;
            }
        }
    }

    /// @inheritdoc INameResolver
    function name(bytes32 node) external view returns (string memory) {
        return _record(node).name;
    }

    /// @inheritdoc IPubkeyResolver
    function pubkey(bytes32 node) external view returns (bytes32, bytes32) {
        bytes32[2] storage xy = _record(node).pubkey;
        return (xy[0], xy[1]);
    }

    /// @inheritdoc ITextResolver
    function text(bytes32 node, string calldata key) external view returns (string memory) {
        return _record(node).texts[key];
    }

    /// @notice Get the number of records.
    function getRecordCount() external view returns (uint256) {
        return _recordCount;
    }

    /// @inheritdoc IRecordResolver
    function getRecordId(bytes32 node) external view returns (uint256) {
        return _recordIds[node];
    }

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
        return results;
    }

    /// @inheritdoc EnhancedAccessControl
    /// @notice Function is disabled.  Use `grant{Record|Setter}Roles()` instead.
    function grantRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) public pure override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        revert EACCannotGrantRoles(resource, roleBitmap, account);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Find or create a record.
    function _ensureRecord(bytes memory name_) internal returns (uint256 recordId) {
        bytes32 node = NameCoder.namehash(name_, 0);
        recordId = _recordIds[node];
        if (recordId == 0) {
            address sender = _msgSender();
            _checkRoles(ROOT_RESOURCE, PermissionedResolverLib.ROLE_NEW_RECORD, sender);
            recordId = ++_recordCount;
            _recordIds[node] = recordId;
            emit RecordLinked(node, name_, recordId, sender);
        }
    }

    /// @dev Same as `_ensureRecord()` but doesn't create the default record.
    function _ensureRecordExceptDefault(bytes memory name_) internal returns (uint256) {
        (uint8 size, ) = NameCoder.nextLabel(name_, 0);
        if (size == 0) {
            return 0; // empty name => use default
        }
        return _ensureRecord(name_);
    }

    /// @dev Allow `ROLE_UPGRADE` to upgrade.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRootRoles(PermissionedResolverLib.ROLE_UPGRADE) {
        //
    }

    /// @dev Assert `sender` has necessary roles to update record.
    function _checkRecordRoles(
        uint256 recordId,
        uint256 roleBitmap,
        bytes32 part,
        address sender
    ) internal view {
        if (
            part == bytes32(0) ||
            (!hasRoles(PermissionedResolverLib.resource(recordId, part), roleBitmap, sender) &&
                !hasRoles(PermissionedResolverLib.resource(0, part), roleBitmap, sender))
        ) {
            _checkRoles(PermissionedResolverLib.resource(recordId), roleBitmap, sender); // reverts with "widest" resource
        }
    }

    /// @dev HCA-compatible `_msgSender()`.
    function _msgSender()
        internal
        view
        virtual
        override(HCAContext, HCAContextUpgradeable)
        returns (address)
    {
        return HCAContextUpgradeable._msgSender();
    }

    /// @dev Returns the original `msg.data`.
    ///      Needed to resolve Context/ContextUpgradable inheritance.
    function _msgData()
        internal
        view
        virtual
        override(Context, ContextUpgradeable)
        returns (bytes calldata)
    {
        return msg.data;
    }

    /// @dev Returns 0.
    ///      Needed to resolve Context/ContextUpgradable inheritance.
    function _contextSuffixLength()
        internal
        view
        virtual
        override(Context, ContextUpgradeable)
        returns (uint256)
    {
        return 0;
    }

    /// @dev Get the active storage record.
    function _record(uint256 recordId) internal view returns (Record storage) {
        return _records[recordId][_versions[recordId]];
    }

    /// @dev Determine the active storage record for `node`.
    function _record(bytes32 node) internal view returns (Record storage) {
        uint256 recordId = _recordIds[node];
        if (recordId == 0) {
            recordId = _recordIds[bytes32(0)]; // use default
        }
        return _record(recordId);
    }

    /// @dev Determine address according to ENSIP-19.
    function _getAddress(
        Record storage record,
        uint256 coinType
    ) internal view returns (bytes memory addressBytes) {
        addressBytes = record.addresses[coinType];
        if (addressBytes.length == 0 && ENSIP19.chainFromCoinType(coinType) > 0) {
            addressBytes = record.addresses[COIN_TYPE_DEFAULT];
        }
    }

    /// @dev Convenience for mainnet address.
    function _getAddr(Record storage record) internal view returns (address) {
        return address(bytes20(_getAddress(record, COIN_TYPE_ETH)));
    }

    /// @dev Returns true if `x` has a single bit set.
    function _isPowerOf2(uint256 x) internal pure returns (bool) {
        return x > 0 && (x - 1) & x == 0;
    }
}
