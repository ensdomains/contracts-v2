// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ENS} from "@ens/contracts/registry/ENS.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {
    IStandaloneReverseRegistrar
} from "@ens/contracts/reverseRegistrar/IStandaloneReverseRegistrar.sol";
import {INameReverser} from "@ens/contracts/reverseResolver/INameReverser.sol";
import {ENSIP19, COIN_TYPE_ETH, CHAIN_ID_ETH} from "@ens/contracts/utils/ENSIP19.sol";
import {LibABI} from "@ens/contracts/utils/LibABI.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IContractName} from "../reverse-registrar/interfaces/IContractName.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";
import {LibString} from "../utils/LibString.sol";

/// @dev Namehash of "addr.reverse"
bytes32 constant ADDR_REVERSE_NODE =
    0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

/// @notice Reverses an EVM address using the first non-null response from the following sources:
///
/// 1. `name()` from "{addr}.addr.reverse" in V1 Registry
/// 2. `IContractName(addr).ensContractName()`
/// 3. `IStandaloneReverseRegistrar` for "default.reverse"
///
contract AddrReverseResolver is DelegatedContractNamer, IExtendedResolver, INameReverser {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev The ENS registry contract.
    ENS internal immutable _REGISTRY_V1;

    /// @notice The reverse registrar contract for "default.reverse".
    IStandaloneReverseRegistrar public immutable DEFAULT_REGISTRAR;

    /// @dev The reverse registrar contract for "addr.reverse".
    address internal immutable _ADDR_REGISTRAR;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `resolve()` was called with a profile other than `name()``.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    /// @notice `name` is not a valid DNS-encoded ENSIP-19 reverse name or namespace.
    /// @dev Error selector: `0x5fe9a5df`
    error UnreachableName(bytes name);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param registryV1 The ENSv1 registry.
    /// @param defaultRegistrar The reverse registrar contract for "default.reverse".
    /// @param addrRegistrar The reverse registrar contract for "addr.reverse".
    /// @param contractNamer Delegated contract namer.
    constructor(
        ENS registryV1,
        IStandaloneReverseRegistrar defaultRegistrar,
        address addrRegistrar,
        IContractNamer contractNamer
    )
        DelegatedContractNamer(contractNamer)
    {
        _REGISTRY_V1 = registryV1;
        DEFAULT_REGISTRAR = defaultRegistrar;
        _ADDR_REGISTRAR = addrRegistrar;
    }

    /// @inheritdoc DelegatedContractNamer
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IExtendedResolver).interfaceId ||
            interfaceId == type(INameReverser).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IExtendedResolver
    /// @notice Resolves `name()` if `name` is an ENSIP-19 reverse name of a mainnet EVM address.
    /// @param name The reverse name to resolve, in normalised and DNS-encoded form.
    /// @param data The resolution data, as specified in ENSIP-10.
    /// @return result The encoded response for the requested profile.
    function resolve(bytes calldata name, bytes calldata data)
        external
        view
        returns (bytes memory result)
    {
        bytes4 selector = bytes4(data);
        if (selector != INameResolver.name.selector) {
            revert UnsupportedResolverProfile(selector);
        }
        (bytes memory a, uint256 ct) = ENSIP19.parse(name);
        if (a.length != 20 || ct != COIN_TYPE_ETH) {
            revert UnreachableName(name);
        }
        address addr = address(bytes20(a));
        return abi.encode(_resolveName(addr));
    }

    /// @inheritdoc INameReverser
    function resolveNames(address[] calldata addrs) external view returns (string[] memory names) {
        names = new string[](addrs.length);
        for (uint256 i; i < addrs.length; ++i) {
            names[i] = _resolveName(addrs[i]);
        }
    }

    /// @inheritdoc INameReverser
    function chainRegistrar() external view returns (address) {
        return _ADDR_REGISTRAR;
    }

    /// @inheritdoc INameReverser
    function coinType() external pure returns (uint256) {
        return COIN_TYPE_ETH;
    }

    /// @inheritdoc INameReverser
    function chainId() external pure returns (uint32) {
        return CHAIN_ID_ETH;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Determine `name` for `addr`.
    function _resolveName(address addr) internal view returns (string memory name) {
        // #1
        bytes32 node =
            NameCoder.namehash(ADDR_REVERSE_NODE, keccak256(bytes(LibString.toAddressString(addr))));
        address resolver = _REGISTRY_V1.resolver(node);
        if (resolver != address(0)) {
            // note: this only supports onchain direct calls (no extended, no offchain)
            (bool ok, bytes memory v) =
                resolver.staticcall{gas: 100_000}(abi.encodeCall(INameResolver.name, (node)));
            if (ok) {
                (ok, v) = LibABI.tryDecodeBytes(v);
            }
            if (!ok) {
                return ""; // terminate on revert or decode failure
            }
            if (v.length > 0) {
                return string(v);
            }
        }
        // #2
        if (addr.code.length > 0) {
            (bool ok, bytes memory v) =
                addr.staticcall{gas: 100_000}(abi.encodeCall(IContractName.contractName, ()));
            if (ok) {
                (ok, v) = LibABI.tryDecodeBytes(v);
                if (ok && v.length > 0) {
                    return string(v);
                }
            }
        }
        // #3
        return DEFAULT_REGISTRAR.nameForAddr(addr);
    }
}
