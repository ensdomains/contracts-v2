// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
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

import {IDataResolver} from "./interfaces/IDataResolver.sol";
import {
    IPermissionedResolver,
    PERMISSIONED_RESOLVER_INTERFACE_ID
} from "./interfaces/IPermissionedResolver.sol";
import {IRecordResolver, RECORD_RESOLVER_INTERFACE_ID} from "./interfaces/IRecordResolver.sol";
import {IRecordSetters} from "./interfaces/IRecordSetters.sol";
import {PermissionedResolverLib} from "./libraries/PermissionedResolverLib.sol";

/// @notice A resolver that supports many profiles, multiple names, internal aliasing, and fine-grained permissions.
///
/// Supported profiles and standards:
///
/// - ENSIP-1 / EIP-137: addr()
/// - ENSIP-3 / EIP-181: name()
/// - ENSIP-4 / EIP-205: ABI()
/// - EIP-619: pubkey()
/// - ENSIP-5 / EIP-634: text(key)
/// - ENSIP-7 / EIP-1577: contenthash()
/// - ENSIP-8: interfaceImplementer()
/// - ENSIP-9 / EIP-2304: addr(coinType)
/// - ENSIP-19: addr(default)
/// - ENSIP-24: data(key)
/// - IERC7996: supportsFeature()
/// - IHasAddressResolver: hasAddr()
///
/// Fine-grained Permissions:
///
/// * `setText(key)` can be restricted to a key using: `part(key)`
/// * `setData(key)` can be restricted to a key using: `part(key)`
/// * `setAddress(coinType)` can be restricted to a coinType using: `part(coinType)`
///
/// Setters with `recordId` check (4) EAC resources:
///                                                     Parts
///          Resources      +-----------------------------+------------------------------+
///                         |           Any (*)           |         Specific (1)         |
///          +--------------+-----------------------------+------------------------------+
///          |      Any (*) |       resource(0, 0)        |      resource(0, <part>)     |
///  Records |--------------+-----------------------------+------------------------------+
///          | Specific (1) |   resource(<recordId>, 0)   | resource(<recordId>, <part>) |
///          +--------------+-----------------------------+------------------------------+
///
/// eg. `setText(1, "abc", ...)` will check the following resources for `ROLE_SET_TEXT` permission:
/// * `resource(1, part("abc"))` => part("abc") of record(1)
/// * `resource(1, 0)` => ANY part of record(1)
/// * `resource(0, part("abc"))` => part(abc") of ANY record
/// * `resource(0, 0)` => ANY part of ANY record
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

    uint256 _recordCount;
    mapping(bytes32 node => uint256 recordId) internal _recordIds;
    mapping(uint256 recordId => Record record) internal _records;

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    modifier validRecord(uint256 recordId) {
        if (recordId > _recordCount) {
            revert InvalidRecord();
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

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
            type(IRecordResolver).interfaceId == interfaceId ||
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

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initialize the contract.
    /// @param admin The resolver owner.
    /// @param roleBitmap The roles granted to `admin`.
    function initialize(address admin, uint256 roleBitmap) external initializer {
        if (admin == address(0)) {
            revert InvalidOwner();
        }
        __UUPSUpgradeable_init();
        _grantRoles(ROOT_RESOURCE, roleBitmap, admin, false);
    }

    // @inheritdoc IRecordResolver
    function createRecord(
        bytes calldata name_,
        bytes[] calldata setters
    ) external onlyRootRoles(PermissionedResolverLib.ROLE_RECORDS) returns (uint256 recordId) {
        bytes32 node = NameCoder.namehash(name_, 0);
        recordId = ++_recordCount;
        _recordIds[node] = recordId;
        emit RecordName(recordId, node, name_);
        for (uint256 i; i < setters.length; ++i) {
            _updateRecord(recordId, setters[i]);
        }
        return recordId;
    }

    // @inheritdoc IRecordResolver
    function updateRecordByName(bytes calldata name_, bytes[] calldata setters) external {
        uint256 recordId = _recordIds[NameCoder.namehash(name_, 0)];
        if (recordId == 0) {
            revert InvalidRecord();
        }
        for (uint256 i; i < setters.length; ++i) {
            _updateRecord(recordId, setters[i]);
        }
    }

    // @inheritdoc IRecordResolver
    function updateRecordById(
        uint256 recordId,
        bytes[] calldata setters
    ) external validRecord(recordId) {
        for (uint256 i; i < setters.length; ++i) {
            _updateRecord(recordId, setters[i]);
        }
    }

    /// @inheritdoc IRecordResolver
    /// @dev Use `recordId = 0` to remove an association.
    ///      Reverts `InvalidRecord` if `recordId` has not yet been created.
    function bindRecord(
        bytes calldata name_,
        uint256 recordId
    ) external validRecord(recordId) onlyRootRoles(PermissionedResolverLib.ROLE_RECORDS) {
        bytes32 node = NameCoder.namehash(name_, 0);
        _recordIds[node] = recordId;
        emit RecordName(recordId, node, name_);
    }

    /// @notice Grant `roleBitmap` permissions to `account` for `recordId`.
    function grantRecordRoles(
        uint256 recordId,
        uint256 roleBitmap,
        address account
    ) external validRecord(recordId) returns (bool) {
        uint256 resource = PermissionedResolverLib.resource(
            recordId,
            PermissionedResolverLib.ANY_PART
        );
        _checkCanGrantRoles(resource, roleBitmap, _msgSender());
        if (roleCount(resource) == 0) {
            emit RecordResource(recordId, resource, "");
        }
        return _grantRoles(resource, roleBitmap, account, true);
    }

    /// @notice Grant specific setter permissions to `account` for `recordId`.
    function grantSetterRoles(
        uint256 recordId,
        bytes calldata setterPrefix,
        address account
    ) external validRecord(recordId) returns (bool) {
        bytes32 part;
        uint256 roleBitmap;
        bytes4 selector = bytes4(setterPrefix);
        bytes memory computedPrefix;
        if (selector == IRecordSetters.setAddress.selector) {
            uint256 coinType = abi.decode(setterPrefix[4:], (uint256));
            part = PermissionedResolverLib.partHash(coinType);
            roleBitmap = PermissionedResolverLib.ROLE_SET_ADDRESS;
            computedPrefix = abi.encodeWithSelector(selector, coinType);
        } else if (selector == IRecordSetters.setText.selector) {
            string memory key = abi.decode(setterPrefix[4:], (string));
            part = PermissionedResolverLib.partHash(key);
            roleBitmap = PermissionedResolverLib.ROLE_SET_TEXT;
            computedPrefix = abi.encodeWithSelector(selector, key);
        } else if (selector == IRecordSetters.setData.selector) {
            string memory key = abi.decode(setterPrefix[4:], (string));
            part = PermissionedResolverLib.partHash(key);
            roleBitmap = PermissionedResolverLib.ROLE_SET_DATA;
            computedPrefix = abi.encodeWithSelector(selector, key);
        } else if (selector == IRecordSetters.setABI.selector) {
            uint256 contentType = abi.decode(setterPrefix[4:], (uint256));
            part = PermissionedResolverLib.partHash(contentType);
            roleBitmap = PermissionedResolverLib.ROLE_SET_ABI;
            computedPrefix = abi.encodeWithSelector(selector, contentType);
        } else if (selector == IRecordSetters.setInterface.selector) {
            bytes4 interfaceId = abi.decode(setterPrefix[4:], (bytes4));
            part = PermissionedResolverLib.partHash(uint32(interfaceId));
            roleBitmap = PermissionedResolverLib.ROLE_SET_INTERFACE;
            computedPrefix = abi.encodeWithSelector(selector, interfaceId);
        } else {
            revert UnsupportedResolverProfile(selector);
        }
        uint256 resource = PermissionedResolverLib.resource(recordId, part);
        _checkCanGrantRoles(
            PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
            roleBitmap,
            _msgSender()
        );
        if (roleCount(resource) == 0) {
            emit RecordResource(recordId, resource, computedPrefix);
        }
        return _grantRoles(resource, roleBitmap, account, true);
    }

    /// @notice Same as `multicall()`.
    /// @dev The node parameter is accepted for interface compatibility but is not used.
    ///      Permission checking is handled by individual function calls within the multicall.
    function multicallWithNodeCheck(
        bytes32,
        bytes[] calldata calls
    ) external returns (bytes[] memory) {
        return multicall(calls);
    }

    /// @inheritdoc IABIResolver
    // solhint-disable-next-line func-name-mixedcase
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
        bytes32[2] storage v = _record(node).pubkey;
        return (v[0], v[1]);
    }

    /// @inheritdoc ITextResolver
    function text(bytes32 node, string calldata key) external view returns (string memory) {
        return _record(node).texts[key];
    }

    // /// @inheritdoc IRecordResolver
    // function resolveRecord(
    //     uint256 recordId,
    //     bytes calldata data
    // ) external view returns (bytes memory) {
    //     if (bytes4(data) == IMulticallable.multicall.selector) {
    //         bytes[] memory m = abi.decode(data[4:], (bytes[]));
    //         for (uint256 i; i < m.length; ++i) {
    //             try this.resolveRecord(recordId, m[i]) returns (bytes memory v) {
    //                 m[i] = v;
    //             } catch (bytes memory err) {
    //                 m[i] = err;
    //             }
    //         }
    //         return abi.encode(m);
    //     }
    //     Record storage record = _records[recordId];
    //     if (bytes4(data) == IAddressResolver.addr.selector) {
    //         (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
    //         return abi.encode(_getAddress(record, coinType));
    //     } else if (bytes4(data) == ITextResolver.text.selector) {
    //         (, string memory key) = abi.decode(data[4:], (bytes32, string));
    //         return abi.encode(record.texts[key]);
    //     } else if (bytes4(data) == IContentHashResolver.contenthash.selector) {
    //         return abi.encode(record.contentHash);
    //     } else if (bytes4(data) == INameResolver.name.selector) {
    //         return abi.encode(record.name);
    //     } else if (bytes4(data) == IAddrResolver.addr.selector) {
    //         return abi.encode(_getAddr(record));
    //     } else if (bytes4(data) == IABIResolver.ABI.selector) {
    //         (, uint256 contentTypes) = abi.decode(data[4:], (bytes32, uint256));
    //         (uint256 contentType, bytes memory v) = _getABI(record, contentTypes);
    //         return abi.encode(contentType, v);
    //     } else if (bytes4(data) == IInterfaceResolver.interfaceImplementer.selector) {
    //         (, bytes4 interfaceId) = abi.decode(data[4:], (bytes32, bytes4));
    //         return abi.encode(_getInterfaceImplementer(record, interfaceId));
    //     } else if (bytes4(data) == IHasAddressResolver.hasAddr.selector) {
    //         (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
    //         return abi.encode(record.addresses[coinType].length > 0);
    //     } else if (bytes4(data) == IPubkeyResolver.pubkey.selector) {
    //         return abi.encode(record.pubkey);
    //     } else {
    //         revert UnsupportedResolverProfile(bytes4(data));
    //     }
    // }

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

    /// @notice Function is disabled.  Use `grant{Record|Setter}Roles` instead.
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

    /// @dev Update a record according to `setter`.
    function _updateRecord(uint256 recordId, bytes calldata setter) internal {
        address sender = _msgSender();
        Record storage record = _records[recordId];
        if (bytes4(setter) == IRecordSetters.setAddress.selector) {
            (uint256 coinType, bytes memory addressBytes) = abi.decode(
                setter[4:],
                (uint256, bytes)
            );
            if (
                addressBytes.length != 0 &&
                addressBytes.length != 20 &&
                ENSIP19.isEVMCoinType(coinType)
            ) {
                revert InvalidEVMAddress(addressBytes);
            }
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                PermissionedResolverLib.partHash(coinType),
                sender
            );
            record.addresses[coinType] = addressBytes;
            emit AddressUpdated(recordId, coinType, addressBytes, sender);
        } else if (bytes4(setter) == IRecordSetters.setText.selector) {
            (string memory key, string memory value) = abi.decode(setter[4:], (string, string));
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_TEXT,
                PermissionedResolverLib.partHash(key),
                sender
            );
            record.texts[key] = value;
            emit TextUpdated(recordId, keccak256(bytes(key)), key, value, sender);
        } else if (bytes4(setter) == IRecordSetters.setData.selector) {
            (string memory key, bytes memory data_) = abi.decode(setter[4:], (string, bytes));
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_DATA,
                PermissionedResolverLib.partHash(key),
                sender
            );
            record.datas[key] = data_;
            emit DataUpdated(recordId, keccak256(bytes(key)), key, data_, sender);
        } else if (bytes4(setter) == IRecordSetters.setContentHash.selector) {
            bytes memory contentHash = abi.decode(setter[4:], (bytes));
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_CONTENTHASH,
                PermissionedResolverLib.ANY_PART,
                sender
            );
            record.contentHash = contentHash;
            emit ContentHashUpdated(recordId, contentHash, sender);
        } else if (bytes4(setter) == IRecordSetters.setName.selector) {
            string memory name_ = abi.decode(setter[4:], (string));
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_NAME,
                PermissionedResolverLib.ANY_PART,
                sender
            );
            record.name = name_;
            emit NameUpdated(recordId, name_, sender);
        } else if (bytes4(setter) == IRecordSetters.setABI.selector) {
            (uint256 contentType, bytes memory data_) = abi.decode(setter[4:], (uint256, bytes));
            if (!_isPowerOf2(contentType)) {
                revert InvalidContentType(contentType);
            }
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_ABI,
                PermissionedResolverLib.partHash(contentType),
                sender
            );
            record.abis[contentType] = data_;
            emit ABIUpdated(recordId, contentType, sender);
        } else if (bytes4(setter) == IRecordSetters.setInterface.selector) {
            (bytes4 interfaceId, address implementer) = abi.decode(setter[4:], (bytes4, address));
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_INTERFACE,
                PermissionedResolverLib.partHash(uint32(interfaceId)),
                sender
            );
            record.interfaces[interfaceId] = implementer;
            emit InterfaceUpdated(recordId, interfaceId, implementer, sender);
        } else if (bytes4(setter) == IRecordSetters.setPubkey.selector) {
            (bytes32 x, bytes32 y) = abi.decode(setter[4:], (bytes32, bytes32));
            _checkRecordRoles(
                recordId,
                PermissionedResolverLib.ROLE_SET_PUBKEY,
                PermissionedResolverLib.ANY_PART,
                sender
            );
            record.pubkey = [x, y];
            emit PubkeyUpdated(recordId, x, y, sender);
        } else {
            revert UnsupportedResolverProfile(bytes4(setter));
        }
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
            part == PermissionedResolverLib.ANY_PART ||
            (!hasRoles(PermissionedResolverLib.resource(recordId, part), roleBitmap, sender) &&
                !hasRoles(PermissionedResolverLib.resource(0, part), roleBitmap, sender))
        ) {
            _checkRoles(PermissionedResolverLib.resource(recordId, 0), roleBitmap, sender); // reverts using "widest" resource
        }
    }

    function _msgSender()
        internal
        view
        virtual
        override(HCAContext, HCAContextUpgradeable)
        returns (address)
    {
        return HCAContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(Context, ContextUpgradeable)
        returns (bytes calldata)
    {
        return msg.data;
    }

    function _contextSuffixLength()
        internal
        view
        virtual
        override(Context, ContextUpgradeable)
        returns (uint256)
    {
        return 0;
    }

    /// @dev Shorthand to convert `node` to record.
    function _record(bytes32 node) internal view returns (Record storage) {
        return _records[_recordIds[node]];
    }

    function _getAddress(
        Record storage record,
        uint256 coinType
    ) internal view returns (bytes memory addressBytes) {
        addressBytes = record.addresses[coinType];
        if (addressBytes.length == 0 && ENSIP19.chainFromCoinType(coinType) > 0) {
            addressBytes = record.addresses[COIN_TYPE_DEFAULT];
        }
    }

    function _getAddr(Record storage record) internal view returns (address) {
        return address(bytes20(_getAddress(record, COIN_TYPE_ETH)));
    }

    /// @dev Returns true if `x` has a single bit set.
    function _isPowerOf2(uint256 x) internal pure returns (bool) {
        return x > 0 && (x - 1) & x == 0;
    }
}
