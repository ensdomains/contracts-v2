// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ENSIP19, COIN_TYPE_ETH, COIN_TYPE_DEFAULT} from "@ens/contracts/utils/ENSIP19.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {HCAContext} from "../hca/HCAContext.sol";
import {HCAContextUpgradeable} from "../hca/HCAContextUpgradeable.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IResolverAuthority} from "./interfaces/IResolverAuthority.sol";
import {ISubdomainResolver} from "./interfaces/ISubdomainResolver.sol";
import {AuthorizedResolverLib} from "./libraries/AuthorizedResolverLib.sol";

bytes32 constant NAMED_SLOT = keccak256("eth.ens.storage.AuthorizedResolver");

contract AuthorizedResolver is
    ISubdomainResolver,
    HCAContextUpgradeable,
    UUPSUpgradeable,
    EnhancedAccessControl,
    IERC7996,
    IExtendedResolver,
    IMulticallable
{
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct Record {
        bytes contentHash;
        string name;
        mapping(uint256 coinType => bytes addressBytes) addresses;
        mapping(string key => string value) texts;
    }

    struct Storage {
        uint256 resourceIndex;
        address authority;
        mapping(string label => uint256) resources;
        mapping(string label => uint256) versions;
        mapping(string label => mapping(uint256 version => Record)) records;
        mapping(bytes32 part => mapping(address => bool)) every;
        mapping(uint256 resource => mapping(bytes32 part => mapping(address => bool))) one;
    }

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event NewVersion(string indexed labelHash, uint256 version);
    event ResourceChanged(string indexed labelHash, uint256 oldResource, uint256 newResource);
    event AddressChanged(string indexed labelHash, uint256 indexed coinType, bytes addressBytes);
    event ContentHashChanged(string indexed labelHash, bytes contentHash);
    event TextChanged(string indexed labelHash, string indexed keyHash, string key, string value);
    event NameChanged(string indexed labelHash, string name);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error NotAuthority();
    error InvalidResource();

    /// @notice The resolver profile cannot be answered.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    /// @notice The address could not be converted to `address`.
    /// @dev Error selector: `0x8d666f60`
    error InvalidEVMAddress(bytes addressBytes);

    /// @notice The coin type is not a power of 2.
    /// @dev Error selector: `0xe7cf0ac4`
    error InvalidContentType(uint256 contentType);

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    modifier onlyPartiallyAuthorized(bytes32 part, string memory label, uint256 rolesBitmap) {
        address sender = _msgSender();
        if (!isAuthority(label, sender)) {
            Storage storage S = _storage();
            if (!S.every[part][sender]) {
                uint256 resource = S.resources[label];
                if (!S.one[resource][part][sender]) {
                    _checkRoles(resource, rolesBitmap, sender);
                }
            }
        }
        _;
    }

    modifier onlyAuthorized(string memory label, uint256 rolesBitmap) {
        address sender = _msgSender();
        if (!isAuthority(label, sender)) {
            _checkRoles(_storage().resources[label], rolesBitmap, sender);
        }
        _;
    }

    modifier onlyAuthority(string memory label) {
        if (!isAuthority(label, _msgSender())) {
            revert NotAuthority();
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
            type(ISubdomainResolver).interfaceId == interfaceId ||
            type(IExtendedResolver).interfaceId == interfaceId ||
            type(IERC7996).interfaceId == interfaceId ||
            type(IMulticallable).interfaceId == interfaceId ||
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
    /// @param account The account to give authority.
    /// @param roleBitmap The roles granted to `admin` or 0 if account is an `IResolverAuthority`.
    function initialize(address account, uint256 roleBitmap) external initializer {
        __UUPSUpgradeable_init();
        if (roleBitmap == 0) {
            _storage().authority = account;
        } else {
            _grantRoles(ROOT_RESOURCE, roleBitmap, account, false);
        }
    }

    /// @notice Create a new EAC resource for `label` and assign roles.
    ///         If `enable = false`, forget existing resource.
    function authorize(
        string calldata label,
        address account,
        uint256 rolesBitmap,
        bool enable
    ) external onlyAuthority(label) returns (uint256 newResource) {
        Storage storage S = _storage();
        uint256 oldResource = S.resources[label];
        if (enable) {
            newResource = ++S.resourceIndex;
        } else if (oldResource == 0) {
            revert InvalidResource();
        }
        S.resources[label] = newResource;
        emit ResourceChanged(label, oldResource, newResource);
        if (enable) {
            _grantRoles(newResource, rolesBitmap, account, false);
        }
    }

    /// @notice Authorize `account` to modify `coinType` for any label.
    ///         If `enable = false`, remove authorization.
    function authorizeEveryAddr(
        address account,
        uint256 coinType,
        bool enable
    ) external onlyRootRoles(AuthorizedResolverLib.ROLE_AUTHORITY) {
        _storage().every[AuthorizedResolverLib.addr(coinType)][account] = enable;
    }

    /// @notice Authorize `account` to modify `coinType` for one label.
    ///         If `enable = false`, remove authorization.
    function authorizeAddr(
        string calldata label,
        address account,
        uint256 coinType,
        bool enable
    ) external onlyAuthority(label) {
        Storage storage S = _storage();
        bytes32 part = AuthorizedResolverLib.addr(coinType);
        uint256 resource = S.resources[label];
        if (resource == 0) {
            revert InvalidResource();
        }
        S.one[resource][part][account] = enable;
    }

    function clearRecords(
        string calldata label
    ) external onlyAuthorized(label, AuthorizedResolverLib.ROLE_CLEAR) {
        uint256 version = ++_storage().versions[label];
        emit NewVersion(label, version);
    }

    function setAddr(
        string calldata label,
        uint256 coinType,
        bytes calldata addressBytes
    )
        external
        onlyPartiallyAuthorized(
            AuthorizedResolverLib.addr(coinType),
            label,
            AuthorizedResolverLib.ROLE_SET_ADDR
        )
    {
        if (
            addressBytes.length != 0 && addressBytes.length != 20 && ENSIP19.isEVMCoinType(coinType)
        ) {
            revert InvalidEVMAddress(addressBytes);
        }
        _record(label).addresses[coinType] = addressBytes;
        emit AddressChanged(label, coinType, addressBytes);
    }

    function setText(
        string calldata label,
        string calldata key,
        string calldata value
    )
        external
        onlyPartiallyAuthorized(
            AuthorizedResolverLib.text(key),
            label,
            AuthorizedResolverLib.ROLE_SET_TEXT
        )
    {
        _record(label).texts[key] = value;
        emit TextChanged(label, key, key, value);
    }

    function setContentHash(
        string calldata label,
        bytes calldata contentHash
    ) external onlyAuthorized(label, AuthorizedResolverLib.ROLE_SET_CONTENTHASH) {
        _record(label).contentHash = contentHash;
        emit ContentHashChanged(label, contentHash);
    }

    function setName(
        string calldata label,
        string calldata name
    ) external onlyAuthorized(label, AuthorizedResolverLib.ROLE_SET_NAME) {
        _record(label).name = name;
        emit NameChanged(label, name);
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

    function resolveSubdomain(
        string calldata label,
        bytes calldata data
    ) external view returns (bytes memory) {
        Record storage R = _record(label);
        if (bytes4(data) == IAddressResolver.addr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(_addr(R, coinType));
        } else if (bytes4(data) == ITextResolver.text.selector) {
            (, string memory key) = abi.decode(data[4:], (bytes32, string));
            return abi.encode(R.texts[key]);
        } else if (bytes4(data) == IContentHashResolver.contenthash.selector) {
            return abi.encode(R.contentHash);
        } else if (bytes4(data) == INameResolver.name.selector) {
            return abi.encode(R.name);
        } else if (bytes4(data) == IHasAddressResolver.hasAddr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(R.addresses[coinType].length > 0);
        } else if (bytes4(data) == IAddrResolver.addr.selector) {
            bytes memory v = _addr(R, COIN_TYPE_ETH);
            return abi.encode(address(bytes20(v)));
        } else {
            revert UnsupportedResolverProfile(bytes4(data));
        }
    }

    /// @notice Get the EAC resource for `label`.
    function getResource(string calldata label) external view returns (uint256) {
        return _storage().resources[label];
    }

    /// @notice Get the maximum EAC resource.
    function getResourceMax() external view returns (uint256) {
        return _storage().resourceIndex;
    }

    /// @notice Get the resolver authority.
    function getAuthority() external view returns (IResolverAuthority) {
        return IResolverAuthority(_storage().authority);
    }

    /// @inheritdoc IExtendedResolver
    function resolve(
        bytes calldata name,
        bytes calldata data
    ) external view returns (bytes memory) {
        string memory label = NameCoder.firstLabel(name);
        if (bytes4(data) == IMulticallable.multicall.selector) {
            // note: cannot staticcall multicall() because it reverts with first error
            bytes[] memory m = abi.decode(data[4:], (bytes[]));
            for (uint256 i; i < m.length; ++i) {
                try this.resolveSubdomain(label, m[i]) returns (bytes memory v) {
                    m[i] = v;
                } catch (bytes memory v) {
                    m[i] = v;
                }
            }
            return abi.encode(m);
        } else {
            return this.resolveSubdomain(label, data);
        }
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

    /// @notice Determine if `operator` is an authority of `label`.
    function isAuthority(string memory label, address operator) public view returns (bool) {
        NameCoder.assertLabelSize(label);
        address authority = _storage().authority;
        return
            authority == address(0)
                ? hasRootRoles(AuthorizedResolverLib.ROLE_AUTHORITY, operator)
                : IResolverAuthority(authority).isAuthorized(label, operator);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allow `ROLE_UPGRADE` to upgrade.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRootRoles(AuthorizedResolverLib.ROLE_UPGRADE) {
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

    /// @dev Get address according to ENSIP-19.
    function _addr(Record storage R, uint256 coinType) internal view returns (bytes memory v) {
        v = R.addresses[coinType];
        if (v.length == 0 && ENSIP19.chainFromCoinType(coinType) > 0) {
            v = R.addresses[COIN_TYPE_DEFAULT];
        }
    }

    /// @dev Access record storage pointer.
    function _record(string memory label) internal view returns (Record storage R) {
        Storage storage S = _storage();
        return S.records[label][S.versions[label]];
    }

    /// @dev Access global storage pointer.
    function _storage() internal pure returns (Storage storage S) {
        bytes32 slot = NAMED_SLOT;
        assembly {
            S.slot := slot
        }
    }
}
