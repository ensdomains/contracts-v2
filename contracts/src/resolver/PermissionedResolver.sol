// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {IVersionableResolver} from "@ens/contracts/resolvers/profiles/IVersionableResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ENSIP19, COIN_TYPE_ETH, COIN_TYPE_DEFAULT} from "@ens/contracts/utils/ENSIP19.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {HCAContext} from "../hca/HCAContext.sol";
import {HCAContextUpgradeable} from "../hca/HCAContextUpgradeable.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {PermissionedResolverLib} from "./libraries/PermissionedResolverLib.sol";
import {ResolverProfileRewriterLib} from "./libraries/ResolverProfileRewriterLib.sol";

/// @notice An owned resolver that supports multiple names, internal aliasing, and fine-grained permissions.
///
/// Internal Aliasing:
///
/// * Resolved names find the longest match and rewrite the suffix.
/// * Successful matches recursively check for additional aliasing.
/// * `bytes32 node` in calldata is updated accordingly.
/// * Cycles of length 1 apply once.
/// * Cycles of length 2+ result in OOG.
///
/// eg. `setAlias("a.eth", "b.eth")`
/// * `getAlias("a.eth") => "b.eth"`
/// * `getAlias("[sub].a.eth") => "[sub].b.eth"`
/// * `getAlias("[x.y].a.eth") => "[x.y].b.eth"`
/// * `getAlias("abc.eth") => ""`
///
/// Fine-grained Permissions:
///
/// `setText(key)` can be restricted to a key using: `part = textPart(<key>)`.
/// `setAddr(coinType)` can be restricted to a coinType using: `part = addrPart(<coinType>)`.
///
/// Setters with `node` check (4) EAC resources:
///                                                   Parts
///        Resources      +-----------------------------+------------------------------+
///                       |           Any (*)           |         Specific (1)         |
///        +--------------+-----------------------------+------------------------------+
///        |      Any (*) |       resource(0, 0)        |      resource(0, <part>)     |
///  Names |--------------+-----------------------------+------------------------------+
///        | Specific (1) |   resource(<namehash>, 0)   | resource(<namehash>, <part>) |
///        +--------------+-----------------------------+------------------------------+
///
contract PermissionedResolver is
    HCAContextUpgradeable,
    UUPSUpgradeable,
    EnhancedAccessControl,
    IERC7996,
    IExtendedResolver,
    IMulticallable,
    IABIResolver,
    IAddrResolver,
    IAddressResolver,
    IContentHashResolver,
    IHasAddressResolver,
    IInterfaceResolver,
    INameResolver,
    IPubkeyResolver,
    ITextResolver,
    IVersionableResolver
{
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event AliasChanged(
        bytes indexed indexedFromName,
        bytes indexed indexedToName,
        bytes fromName,
        bytes toName
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

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
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    modifier onlyPartRoles(bytes32 node, bytes32 part, uint256 roleBitmap) {
        address sender = _msgSender();
        if (
            !hasRoles(PermissionedResolverLib.resource(node, part), roleBitmap, sender) &&
            !hasRoles(PermissionedResolverLib.resource(0, part), roleBitmap, sender)
        ) {
            _checkRoles(PermissionedResolverLib.resource(node, 0), roleBitmap, sender);
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(IHCAFactoryBasic hcaFactory) HCAEquivalence(hcaFactory) {
        _disableInitializers();
    }

    /// @inheritdoc EnhancedAccessControl
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(EnhancedAccessControl) returns (bool) {
        return
            type(IExtendedResolver).interfaceId == interfaceId ||
            type(IERC7996).interfaceId == interfaceId ||
            type(IMulticallable).interfaceId == interfaceId ||
            type(IABIResolver).interfaceId == interfaceId ||
            type(IAddrResolver).interfaceId == interfaceId ||
            type(IAddressResolver).interfaceId == interfaceId ||
            type(IContentHashResolver).interfaceId == interfaceId ||
            type(IHasAddressResolver).interfaceId == interfaceId ||
            type(IInterfaceResolver).interfaceId == interfaceId ||
            type(INameResolver).interfaceId == interfaceId ||
            type(IPubkeyResolver).interfaceId == interfaceId ||
            type(ITextResolver).interfaceId == interfaceId ||
            type(IVersionableResolver).interfaceId == interfaceId ||
            type(UUPSUpgradeable).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC7996
    function supportsFeature(bytes4 feature) external pure returns (bool) {
        return ResolverFeatures.RESOLVE_MULTICALL == feature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initialize the contract.
    ///
    /// @param admin The resolver owner.
    /// @param roleBitmap The roles granted to `admin`.
    function initialize(address admin, uint256 roleBitmap) external initializer {
        if (admin == address(0)) {
            revert InvalidOwner();
        }
        __UUPSUpgradeable_init();
        _grantRoles(ROOT_RESOURCE, roleBitmap, admin, false);
    }

    /// @notice Clear all records for `node`.
    ///
    /// @param node The node to update.
    function clearRecords(
        bytes32 node
    ) external onlyPartRoles(node, 0, PermissionedResolverLib.ROLE_CLEAR) {
        uint64 version = ++_storage().versions[node];
        emit VersionChanged(node, version);
    }

    /// @notice Create an alias from `fromName` to `toName`.
    ///
    /// @param fromName The source DNS-encoded name.
    /// @param toName The destination DNS-encoded name.
    function setAlias(
        bytes calldata fromName,
        bytes calldata toName
    ) external onlyRootRoles(PermissionedResolverLib.ROLE_SET_ALIAS) {
        _storage().aliases[NameCoder.namehash(fromName, 0)] = toName;
        emit AliasChanged(fromName, toName, fromName, toName);
    }

    /// @notice Set ABI data of the associated ENS node.
    ///
    /// @param node The node to update.
    /// @param contentType The content type of the ABI.
    /// @param data The ABI data.
    function setABI(
        bytes32 node,
        uint256 contentType,
        bytes calldata data
    ) external onlyPartRoles(node, 0, PermissionedResolverLib.ROLE_SET_ABI) {
        if (!_isPowerOf2(contentType)) {
            revert InvalidContentType(contentType);
        }
        _record(node).abis[contentType] = data;
        emit ABIChanged(node, contentType);
    }

    /// @notice Set Ethereum mainnet address of the associated ENS node.
    ///         `address(0)` is stored as `new bytes(20)`.
    ///
    /// @param node The node to update.
    /// @param addr_ The mainnet address.
    function setAddr(bytes32 node, address addr_) external {
        setAddr(node, COIN_TYPE_ETH, abi.encodePacked(addr_));
    }

    /// @notice Set the contenthash of the associated ENS node.
    ///
    /// @param node The node to update.
    /// @param hash The contenthash to set.
    function setContenthash(
        bytes32 node,
        bytes calldata hash
    ) external onlyPartRoles(node, 0, PermissionedResolverLib.ROLE_SET_CONTENTHASH) {
        _record(node).contenthash = hash;
        emit ContenthashChanged(node, hash);
    }

    /// @notice Set an interface of the associated ENS node.
    ///
    /// @param node The node to update.
    /// @param interfaceId The EIP-165 interface ID.
    /// @param implementer The address of the contract that implements this interface for this node.
    function setInterface(
        bytes32 node,
        bytes4 interfaceId,
        address implementer
    ) external onlyPartRoles(node, 0, PermissionedResolverLib.ROLE_SET_INTERFACE) {
        _record(node).interfaces[interfaceId] = implementer;
        emit InterfaceChanged(node, interfaceId, implementer);
    }

    /// @notice Set the SECP256k1 public key associated with an ENS node.
    ///
    /// @param node The node to update.
    /// @param x The x coordinate of the public key.
    /// @param y The y coordinate of the public key.
    function setPubkey(
        bytes32 node,
        bytes32 x,
        bytes32 y
    ) external onlyPartRoles(node, 0, PermissionedResolverLib.ROLE_SET_PUBKEY) {
        _record(node).pubkey = [x, y];
        emit PubkeyChanged(node, x, y);
    }

    /// @notice Set the name of the associated ENS node.
    ///
    /// @param node The node to update.
    /// @param primary The primary name.
    function setName(
        bytes32 node,
        string calldata primary
    ) external onlyPartRoles(node, 0, PermissionedResolverLib.ROLE_SET_NAME) {
        _record(node).name = primary;
        emit NameChanged(node, primary);
    }

    /// @notice Set the text for `key` of the associated ENS node.
    ///
    /// @param node The node to update.
    /// @param key The text key.
    /// @param value The text value.
    function setText(
        bytes32 node,
        string calldata key,
        string calldata value
    )
        external
        onlyPartRoles(
            node,
            PermissionedResolverLib.textPart(key),
            PermissionedResolverLib.ROLE_SET_TEXT
        )
    {
        _record(node).texts[key] = value;
        emit TextChanged(node, key, key, value);
    }

    /// @notice Same as `multicall()`.
    /// @dev The purpose of node check is to prevent a trusted operator from modifying multiple names.
    //       Since there is no trusted operator, the node check logic can be elided.
    function multicallWithNodeCheck(
        bytes32,
        bytes[] calldata calls
    ) external returns (bytes[] memory) {
        return multicall(calls);
    }

    /// @inheritdoc IExtendedResolver
    function resolve(
        bytes calldata fromName,
        bytes calldata fromData
    ) external view returns (bytes memory) {
        bytes memory toName = getAlias(fromName);
        bytes memory toData = ResolverProfileRewriterLib.replaceNode(
            fromData,
            NameCoder.namehash(toName.length == 0 ? fromName : toName, 0) // always rewrite node
        );
        if (bytes4(toData) == IMulticallable.multicall.selector) {
            // note: cannot staticcall multicall() because it reverts with first error
            assembly {
                mstore(add(toData, 4), sub(mload(toData), 4))
                toData := add(toData, 4) // drop selector
            }
            bytes[] memory m = abi.decode(toData, (bytes[]));
            for (uint256 i; i < m.length; ++i) {
                toData = m[i];
                (, bytes memory v) = address(this).staticcall(toData);
                if (v.length == 0) {
                    v = abi.encodeWithSelector(UnsupportedResolverProfile.selector, bytes4(toData));
                }
                m[i] = v;
            }
            return abi.encode(m);
        } else {
            (bool ok, bytes memory v) = address(this).staticcall(toData);
            if (!ok) {
                assembly {
                    revert(add(v, 32), mload(v))
                }
            } else if (v.length == 0) {
                revert UnsupportedResolverProfile(bytes4(fromData));
            }
            return v;
        }
    }

    /// @notice Get the current version.
    ///
    /// @param node The node to check.
    function recordVersions(bytes32 node) external view returns (uint64) {
        return _storage().versions[node];
    }

    /// @inheritdoc IABIResolver
    // solhint-disable-next-line func-name-mixedcase
    function ABI(
        bytes32 node,
        uint256 contentTypes
    ) external view returns (uint256 contentType, bytes memory data) {
        PermissionedResolverLib.Record storage R = _record(node);
        for (contentType = 1; contentType > 0 && contentType <= contentTypes; contentType <<= 1) {
            if ((contentType & contentTypes) != 0) {
                data = R.abis[contentType];
                if (data.length > 0) {
                    return (contentType, data);
                }
            }
        }
        return (0, "");
    }

    /// @inheritdoc IHasAddressResolver
    function hasAddr(bytes32 node, uint256 coinType) external view returns (bool) {
        return _record(node).addresses[coinType].length > 0;
    }

    /// @inheritdoc IContentHashResolver
    function contenthash(bytes32 node) external view returns (bytes memory) {
        return _record(node).contenthash;
    }

    /// @inheritdoc IInterfaceResolver
    function interfaceImplementer(
        bytes32 node,
        bytes4 interfaceId
    ) external view returns (address implementer) {
        implementer = _record(node).interfaces[interfaceId];
        if (implementer == address(0) && ERC165Checker.supportsInterface(addr(node), interfaceId)) {
            implementer = address(this);
        }
    }

    /// @inheritdoc INameResolver
    function name(bytes32 node) external view returns (string memory) {
        return _record(node).name;
    }

    /// @inheritdoc IPubkeyResolver
    function pubkey(bytes32 node) external view returns (bytes32 x, bytes32 y) {
        PermissionedResolverLib.Record storage R = _record(node);
        x = R.pubkey[0];
        y = R.pubkey[1];
    }

    /// @inheritdoc ITextResolver
    function text(bytes32 node, string calldata key) external view returns (string memory) {
        return _record(node).texts[key];
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

    /// @notice Set the address for `coinType` of the associated ENS node.
    ///         Reverts `InvalidEVMAddress` if coin type is EVM and not 0 or 20 bytes.
    ///
    /// @param node The node to update.
    /// @param coinType The coin type.
    /// @param addressBytes The encoded address.
    function setAddr(
        bytes32 node,
        uint256 coinType,
        bytes memory addressBytes
    )
        public
        onlyPartRoles(
            node,
            PermissionedResolverLib.addrPart(coinType),
            PermissionedResolverLib.ROLE_SET_ADDR
        )
    {
        if (
            addressBytes.length != 0 && addressBytes.length != 20 && ENSIP19.isEVMCoinType(coinType)
        ) {
            revert InvalidEVMAddress(addressBytes);
        }
        _record(node).addresses[coinType] = addressBytes;
        emit AddressChanged(node, coinType, addressBytes);
        if (coinType == COIN_TYPE_ETH) {
            emit AddrChanged(node, address(bytes20(addressBytes)));
        }
    }

    /// @inheritdoc IAddressResolver
    function addr(bytes32 node, uint256 coinType) public view returns (bytes memory addressBytes) {
        PermissionedResolverLib.Record storage R = _record(node);
        addressBytes = R.addresses[coinType];
        if (addressBytes.length == 0 && ENSIP19.chainFromCoinType(coinType) > 0) {
            addressBytes = R.addresses[COIN_TYPE_DEFAULT];
        }
    }

    /// @inheritdoc IAddrResolver
    function addr(bytes32 node) public view returns (address payable) {
        return payable(address(bytes20(addr(node, COIN_TYPE_ETH))));
    }

    /// @notice Determine which name is queried when `fromName` is resolved.
    ///
    /// @param fromName The source DNS-encoded name.
    ///
    /// @return toName The destination DNS-encoded name or empty if not aliased.
    function getAlias(bytes memory fromName) public view returns (bytes memory toName) {
        bytes32 prev;
        for (;;) {
            bytes memory matchName;
            (matchName, fromName) = _resolveAlias(fromName);
            if (fromName.length == 0) break; // no alias
            bytes32 next = keccak256(matchName);
            if (next == prev) break; // same alias
            toName = fromName;
            prev = next;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allow `ROLE_UPGRADE` to upgrade.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRootRoles(PermissionedResolverLib.ROLE_UPGRADE) {
        //
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

    /// @dev Apply one round of aliasing.
    ///
    /// @param fromName The source DNS-encoded name.
    ///
    /// @return matchName The alias that matched.
    /// @return toName The destination DNS-encoded name or empty if no match.
    function _resolveAlias(
        bytes memory fromName
    ) internal view returns (bytes memory matchName, bytes memory toName) {
        mapping(bytes32 => bytes) storage A = _storage().aliases;
        uint256 offset;
        while (offset < fromName.length) {
            matchName = A[NameCoder.namehash(fromName, offset)];
            if (matchName.length > 0) {
                if (offset > 0) {
                    // rewrite prefix: [x.y].{fromName[offset:]} => [x.y].{matchName}
                    toName = new bytes(offset + matchName.length);
                    assembly {
                        mcopy(add(toName, 32), add(fromName, 32), offset) // copy prefix
                        mcopy(add(toName, add(32, offset)), add(matchName, 32), mload(matchName)) // copy suffix
                    }
                } else {
                    toName = matchName;
                }
                break;
            }
            (, offset) = NameCoder.nextLabel(fromName, offset);
        }
    }

    /// @dev Access record storage pointer.
    function _record(
        bytes32 node
    ) internal view returns (PermissionedResolverLib.Record storage R) {
        PermissionedResolverLib.Storage storage S = _storage();
        return S.records[node][S.versions[node]];
    }

    /// @dev Access global storage pointer.
    function _storage() internal pure returns (PermissionedResolverLib.Storage storage S) {
        uint256 slot = PermissionedResolverLib.NAMED_SLOT;
        assembly {
            S.slot := slot
        }
    }

    /// @dev Returns true if `x` has a single bit set.
    function _isPowerOf2(uint256 x) internal pure returns (bool) {
        return x > 0 && (x - 1) & x == 0;
    }
}
