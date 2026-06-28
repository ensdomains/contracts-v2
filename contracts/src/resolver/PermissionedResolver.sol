// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {IEnhancedAccessControl} from "../access-control/interfaces/IEnhancedAccessControl.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";

import {AbstractResolverBase} from "./AbstractResolverBase.sol";
import {IPermissionedResolver} from "./interfaces/IPermissionedResolver.sol";
import {IABISetter} from "./interfaces/setters/IABISetter.sol";
import {IAddressSetter} from "./interfaces/setters/IAddressSetter.sol";
import {IContentHashSetter} from "./interfaces/setters/IContentHashSetter.sol";
import {IDataSetter} from "./interfaces/setters/IDataSetter.sol";
import {IInterfaceSetter} from "./interfaces/setters/IInterfaceSetter.sol";
import {INameSetter} from "./interfaces/setters/INameSetter.sol";
import {IPubkeySetter} from "./interfaces/setters/IPubkeySetter.sol";
import {ITextSetter} from "./interfaces/setters/ITextSetter.sol";
import {PermissionedResolverLib} from "./libraries/PermissionedResolverLib.sol";

/// @notice An upgradeable resolver that supports many profiles, multiple names, linked records, and fine-grained permissions.
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
/// Names without a record fall back to the default record, which can be updated using the root name (`0x00`).
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
/// Record setters can be granted with `authorizeRecordRoles()` and are annotated
/// using ABI-encoded calldata: `abi.encodeWithSelector(bytes4(0), name)`.
///
/// Fine-grained record setters have the form: `f(name, <arg>, ...)`
/// They can be granted with `authorizeSetterRoles()` and are annotated
/// using truncated ABI-encoded calldata:
/// * w/data: `abi.encodeCall(setAddr, (name, coinType, "..."))`
/// * w/o data: `abi.encodeCall(setAddr, (name, coinType, ""))`
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
    IPermissionedResolver,
    AbstractResolverBase,
    EnhancedAccessControl,
    IContractNamer,
    UUPSUpgradeable,
    IProxyAuthorization
{
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Number of records created.
    uint256 internal _recordCount;

    /// @dev Mapping from `node` to `recordId`.
    mapping(bytes32 node => uint256 recordId) internal _recordIds;

    /// @dev Mapping from `recordId` to `Record`.
    mapping(uint256 recordId => Record record) internal _records;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param namer The implementation namer.
    constructor(address namer) {
        _grantRoles(
            ROOT_RESOURCE,
            PermissionedResolverLib.ROLE_CAN_NAME | PermissionedResolverLib.ROLE_CAN_NAME_ADMIN,
            namer,
            false
        );
        _disableInitializers();
    }

    /// @inheritdoc AbstractResolverBase
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AbstractResolverBase, EnhancedAccessControl)
        returns (bool)
    {
        return
            type(IPermissionedResolver).interfaceId == interfaceId ||
            type(IContractNamer).interfaceId == interfaceId ||
            type(UUPSUpgradeable).interfaceId == interfaceId ||
            type(IProxyAuthorization).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Initialize the resolver.
    /// @param rootAccount Account granted root roles.
    /// @param roleBitmap The role bitmap granted to `rootAccount`.
    /// @param setters The setter calldata that avoids permission checks.
    function initialize(address rootAccount, uint256 roleBitmap, bytes[] calldata setters)
        external
        initializer
    {
        _grantRoles(ROOT_RESOURCE, roleBitmap, rootAccount, false);
        multicall(setters);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Associate `name` with a new record.
    /// @param name The DNS-encoded name.
    function clear(bytes calldata name) external {
        bytes32 node = NameCoder.namehash(name, 0);
        _checkRecordRoles(_recordIds[node], PermissionedResolverLib.ROLE_MANAGER, bytes32(0));
        uint256 recordId = ++_recordCount;
        _recordIds[node] = recordId;
        emit Linked(node, name, recordId);
    }

    /// @inheritdoc IABISetter
    function setABI(bytes calldata name, uint256 contentType, bytes calldata data) external {
        _checkContentType(contentType);
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_ABI,
            PermissionedResolverLib.partHash(contentType)
        );
        _records[recordId].abis[contentType] = data;
        emit ABIUpdated(recordId, contentType);
    }

    /// @inheritdoc IAddressSetter
    function setAddress(bytes calldata name, uint256 coinType, bytes calldata addressBytes)
        external
    {
        _checkAddress(coinType, addressBytes);
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_ADDRESS,
            PermissionedResolverLib.partHash(coinType)
        );
        _records[recordId].addresses[coinType] = addressBytes;
        emit AddressUpdated(recordId, coinType, addressBytes);
    }

    /// @inheritdoc IContentHashSetter
    function setContentHash(bytes calldata name, bytes calldata contentHash) external {
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(recordId, PermissionedResolverLib.ROLE_SET_CONTENTHASH, bytes32(0));
        _records[recordId].contentHash = contentHash;
        emit ContentHashUpdated(recordId, contentHash);
    }

    /// @inheritdoc IDataSetter
    function setData(bytes calldata name, string calldata key, bytes calldata value) external {
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_DATA,
            PermissionedResolverLib.partHash(key)
        );
        _records[recordId].datas[key] = value;
        emit DataUpdated(recordId, key, key, value);
    }

    /// @inheritdoc IInterfaceSetter
    function setInterface(bytes calldata name, bytes4 interfaceId, address implementer) external {
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_INTERFACE,
            PermissionedResolverLib.partHash(interfaceId)
        );
        _records[recordId].interfaces[interfaceId] = implementer;
        emit InterfaceUpdated(recordId, interfaceId, implementer);
    }

    /// @inheritdoc INameSetter
    function setName(bytes calldata name, string calldata primaryName) external {
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(recordId, PermissionedResolverLib.ROLE_SET_NAME, bytes32(0));
        _records[recordId].name = primaryName;
        emit NameUpdated(recordId, primaryName);
    }

    /// @inheritdoc IPubkeySetter
    function setPubkey(bytes calldata name, bytes32 x, bytes32 y) external {
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(recordId, PermissionedResolverLib.ROLE_SET_PUBKEY, bytes32(0));
        _records[recordId].pubkey = [x, y];
        emit PubkeyUpdated(recordId, x, y);
    }

    /// @inheritdoc ITextSetter
    function setText(bytes calldata name, string calldata key, string calldata value) external {
        uint256 recordId = _ensureRecord(name);
        _checkRecordRoles(
            recordId,
            PermissionedResolverLib.ROLE_SET_TEXT,
            PermissionedResolverLib.partHash(key)
        );
        _records[recordId].texts[key] = value;
        emit TextUpdated(recordId, key, key, value);
    }

    /// @inheritdoc IPermissionedResolver
    function link(bytes calldata sourceName, bytes32 targetNode)
        external
        onlyRootRoles(PermissionedResolverLib.ROLE_MANAGER)
    {
        bytes32 sourceNode = NameCoder.namehash(sourceName, 0);
        uint256 recordId;
        if (targetNode == bytes32(0)) {
            if (_recordIds[sourceNode] == 0) {
                revert AlreadyUnlinked();
            }
        } else {
            recordId = _recordIds[targetNode];
            if (recordId == 0) {
                revert InvalidRecord();
            }
        }
        _recordIds[sourceNode] = recordId;
        emit Linked(sourceNode, sourceName, recordId);
    }

    /// @inheritdoc IPermissionedResolver
    function authorizeRoles(bytes calldata name, uint256 roleBitmap, address account, bool grant)
        external
        returns (bool)
    {
        return
            _authorizeRoles(
                name,
                bytes32(0),
                PermissionedResolverLib.anySetter(name),
                account,
                roleBitmap,
                grant
            );
    }

    /// @inheritdoc IPermissionedResolver
    function authorizeSubroles(bytes calldata setter, address account, bool grant)
        external
        returns (bool)
    {
        (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory prefix) =
            decodeSetter(setter);
        assert(part != bytes32(0));
        return _authorizeRoles(name, part, prefix, account, roleBitmap, grant);
    }

    /// @inheritdoc IPermissionedResolver
    function getRecordCount() external view returns (uint256) {
        return _recordCount;
    }

    /// @inheritdoc IPermissionedResolver
    function getRecordId(bytes32 node) external view returns (uint256) {
        return _recordIds[node];
    }

    /// @notice Declares this implementation as an eligible verifiable proxy upgrade target.
    /// @dev Upgrade authorization is still enforced by the current implementation during the UUPS
    ///      upgrade call.
    /// @param {previousImplementation} Ignored.
    /// @return allowed Always `true` for implementations in this resolver family.
    function canUpgradeFrom(
        address /*previousImplementation*/
    )
        external
        pure
        virtual
        override
        returns (bool allowed)
    {
        return true;
    }

    /// @inheritdoc IContractNamer
    function isContractNamer(address namer) public view virtual returns (bool) {
        return hasRootRoles(PermissionedResolverLib.ROLE_CAN_NAME, namer);
    }

    /// @inheritdoc EnhancedAccessControl
    /// @notice Function is disabled.  Use `authorize{Record|Setter}Roles()` instead.
    function grantRoles(uint256 resource, uint256 roleBitmap, address account)
        public
        pure
        override(EnhancedAccessControl, IEnhancedAccessControl)
        returns (bool)
    {
        revert EACCannotGrantRoles(resource, roleBitmap, account);
    }

    /// @inheritdoc EnhancedAccessControl
    /// @notice Function is disabled.  Use `authorize{Record|Setter}Roles()` instead.
    function revokeRoles(uint256 resource, uint256 roleBitmap, address account)
        public
        pure
        override(EnhancedAccessControl, IEnhancedAccessControl)
        returns (bool)
    {
        revert EACCannotRevokeRoles(resource, roleBitmap, account);
    }

    /// @inheritdoc IPermissionedResolver
    function decodeSetter(bytes calldata setter)
        public
        pure
        returns (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix)
    {
        bytes4 selector = bytes4(setter);
        if (selector == this.setAddress.selector) {
            uint256 coinType;
            (name, coinType) = abi.decode(setter[4:], (bytes, uint256));
            part = PermissionedResolverLib.partHash(coinType);
            roleBitmap = PermissionedResolverLib.ROLE_SET_ADDRESS;
            setterPrefix = abi.encodeWithSelector(selector, name, coinType);
        } else if (selector == this.setText.selector) {
            string memory key;
            (name, key) = abi.decode(setter[4:], (bytes, string));
            part = PermissionedResolverLib.partHash(key);
            roleBitmap = PermissionedResolverLib.ROLE_SET_TEXT;
            setterPrefix = abi.encodeWithSelector(selector, name, key);
        } else if (selector == this.setData.selector) {
            string memory key;
            (name, key) = abi.decode(setter[4:], (bytes, string));
            part = PermissionedResolverLib.partHash(key);
            roleBitmap = PermissionedResolverLib.ROLE_SET_DATA;
            setterPrefix = abi.encodeWithSelector(selector, name, key);
        } else if (selector == this.setABI.selector) {
            uint256 contentType;
            (name, contentType) = abi.decode(setter[4:], (bytes, uint256));
            part = PermissionedResolverLib.partHash(contentType);
            roleBitmap = PermissionedResolverLib.ROLE_SET_ABI;
            setterPrefix = abi.encodeWithSelector(selector, name, contentType);
        } else if (selector == this.setInterface.selector) {
            bytes4 interfaceId;
            (name, interfaceId) = abi.decode(setter[4:], (bytes, bytes4));
            part = PermissionedResolverLib.partHash(interfaceId);
            roleBitmap = PermissionedResolverLib.ROLE_SET_INTERFACE;
            setterPrefix = abi.encodeWithSelector(selector, name, interfaceId);
        } else {
            revert UnsupportedResolverProfile(selector);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Authorize EAC roles.
    function _authorizeRoles(
        bytes memory name,
        bytes32 part,
        bytes memory setterPrefix,
        address account,
        uint256 roleBitmap,
        bool grant
    )
        internal
        returns (bool)
    {
        (uint8 size, ) = NameCoder.nextLabel(name, 0);
        uint256 recordId;
        if (grant) {
            if (size > 0) {
                recordId = _ensureRecord(name);
            }
            uint256 resource = PermissionedResolverLib.resource(recordId, part);
            _checkCanGrantRoles(PermissionedResolverLib.resource(recordId), roleBitmap, msg.sender);
            if (roleCount(resource) == 0) {
                emit RecordResource(recordId, resource, setterPrefix);
            }
            return _grantRoles(resource, roleBitmap, account, true);
        } else {
            if (size > 0) {
                recordId = _recordIds[NameCoder.namehash(name, 0)];
                if (recordId == 0) {
                    revert InvalidRecord();
                }
            }
            uint256 resource = PermissionedResolverLib.resource(recordId, part);
            _checkCanRevokeRoles(PermissionedResolverLib.resource(recordId), roleBitmap, msg.sender);
            return _revokeRoles(resource, roleBitmap, account, true);
        }
    }

    /// @dev Ensure record exists for `name`.
    function _ensureRecord(bytes memory name) internal returns (uint256 recordId) {
        bytes32 node = NameCoder.namehash(name, 0);
        recordId = _recordIds[node];
        if (recordId == 0) {
            //_checkRoles(ROOT_RESOURCE, PermissionedResolverLib.ROLE_MANAGER, msg.sender);
            recordId = ++_recordCount;
            _recordIds[node] = recordId;
            emit Linked(node, name, recordId);
        }
    }

    /// @dev Allow `ROLE_UPGRADE` to upgrade.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRootRoles(PermissionedResolverLib.ROLE_UPGRADE)
    {}

    /// @dev Assert `sender` has necessary roles to update record.
    function _checkRecordRoles(uint256 recordId, uint256 roleBitmap, bytes32 part) internal view {
        if (
            part == bytes32(0) ||
            (!hasRoles(PermissionedResolverLib.resource(recordId, part), roleBitmap, msg.sender) &&
                !hasRoles(PermissionedResolverLib.resource(0, part), roleBitmap, msg.sender))
        ) {
            _checkRoles(PermissionedResolverLib.resource(recordId), roleBitmap, msg.sender); // reverts with "widest" resource
        }
    }

    /// @dev Avoid permission checks during initialization.
    function _checkRoles(uint256 resource, uint256 roleBitmap, address account)
        internal
        view
        override
    {
        if (!_isInitializing()) {
            super._checkRoles(resource, roleBitmap, account);
        }
    }

    /// @dev Determine the active storage record for `node`.
    function _record(bytes32 node) internal view override returns (Record storage) {
        uint256 recordId = _recordIds[node];
        if (recordId == 0) {
            recordId = _recordIds[bytes32(0)]; // use default
        }
        return _records[recordId];
    }
}
