// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IExtendedDNSResolver} from "@ens/contracts/resolvers/profiles/IExtendedDNSResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ENSIP19, COIN_TYPE_ETH} from "@ens/contracts/utils/ENSIP19.sol";
import {HexUtils} from "@ens/contracts/utils/HexUtils.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {DNSTXTParserLib} from "./libraries/DNSTXTParserLib.sol";

/// @notice Resolver that answers requests with the data encoded into the context of a DNSSEC "ENS1" TXT record.
///
/// DNS TXT record format: `ENS1 dnstxt.ens.eth <context>`.
/// (where "dnstxt.ens.eth" resolves to this contract.)
///
/// The <context> is a human-readable string that is parsable by `DNSTXTParserLib`.
/// Context format: `<record1> <record2> ...`.
///
/// Support record formats:
/// * `text(key)`
///     - Unquoted: `t[age]=18`
///     - Quoted: `t[description]="Once upon a time, ..."`
///     - Quoted w/escapes: `t[notice]="\"E N S!\""`
/// * `addr(coinType)`
///     - Ethereum Address: `a[60]=0x8000000000000000000000000000000000000001` (see: ENSIP-1)
///     - Default EVM Address: `a[e0]=0x...`
///     - Linea Address: `a[e59144]=0x...`
///     - Bitcoin Address: `a[0]=0x00...` (see: ENSIP-9)
/// * `contenthash()`: `c=0x...` (see: ENSIP-7)
/// * `pubkey()`: `xy=0x...`
///
contract DNSTXTResolver is ERC165, IERC7996, IExtendedDNSResolver {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The resolver profile cannot be answered.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    /// @notice The data was not a hex string.
    /// @dev Matches: `/^0x[0-9a-fA-F]*$/`.
    /// @dev Error selector: `0x626777b1`
    error InvalidHexData(bytes data);

    /// @notice The data was an unexpected length.
    /// @dev Error selector: `0xee0c8b99`
    error InvalidDataLength(bytes data, uint256 expected);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165) returns (bool) {
        return
            type(IExtendedDNSResolver).interfaceId == interfaceId ||
            type(IERC7996).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC7996
    function supportsFeature(bytes4 feature) public pure returns (bool) {
        return ResolverFeatures.RESOLVE_MULTICALL == feature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Resolve using values parsed from `context`.
    ///
    /// The operating assumption is that this contract is never called directly,
    /// and instead only invoked by DNSTLDResolver in response to an TXT record.
    ///
    /// The DNSTLDResolver includes `TEXT_KEY_DNSSEC_CONTEXT`.
    ///
    /// Multicalling this contract directly will not include these values.
    ///
    function resolve(
        bytes calldata /* name */,
        bytes calldata data,
        bytes calldata context
    ) external view returns (bytes memory result) {
        bytes4 selector = bytes4(data);
        if (selector == IMulticallable.multicall.selector) {
            bytes[] memory m = abi.decode(data[4:], (bytes[]));
            for (uint256 i; i < m.length; ++i) {
                (bool ok, bytes memory v) = address(this).staticcall(
                    abi.encodeCall(this.resolve, ("", m[i], context))
                );
                if (ok) {
                    v = abi.decode(v, (bytes)); // unwrap resolve()
                }
                m[i] = v;
            }
            return abi.encode(m);
        } else if (selector == IAddrResolver.addr.selector) {
            bytes memory v = _extractAddress(context, COIN_TYPE_ETH, true);
            return abi.encode(address(bytes20(v)));
        } else if (selector == IAddressResolver.addr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(_extractAddress(context, coinType, true));
        } else if (selector == IHasAddressResolver.hasAddr.selector) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            bytes memory v = _extractAddress(context, coinType, false);
            return abi.encode(v.length > 0);
        } else if (selector == ITextResolver.text.selector) {
            (, string memory key) = abi.decode(data[4:], (bytes32, string));
            bytes memory v = DNSTXTParserLib.find(context, abi.encodePacked("t[", key, "]="));
            return abi.encode(v);
        } else if (selector == IContentHashResolver.contenthash.selector) {
            return abi.encode(_parse0xString(DNSTXTParserLib.find(context, "c=")));
        } else if (selector == IPubkeyResolver.pubkey.selector) {
            bytes memory v = _parse0xString(DNSTXTParserLib.find(context, "xy="));
            if (v.length == 0) {
                return new bytes(64);
            } else if (v.length == 64) {
                return v;
            }
            revert InvalidDataLength(v, 64);
        } else {
            revert UnsupportedResolverProfile(selector);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Extract address from context according to coin type.
    ///      Reverts `InvalidHexData` if non-null and not a hex string.
    ///      Reverts `InvalidEVMAddress` if non-null, coin type is EVM, and address is not 20 bytes.
    ///
    /// @param context The DNS context string.
    /// @param coinType The coin type.
    /// @param useDefault If true and address is null and coin type is EVM, use default EVM coin type.
    ///
    /// @return v The address or null if not found.
    function _extractAddress(
        bytes memory context,
        uint256 coinType,
        bool useDefault
    ) internal pure returns (bytes memory v) {
        if (ENSIP19.isEVMCoinType(coinType)) {
            v = DNSTXTParserLib.find(
                context,
                coinType == COIN_TYPE_ETH
                    ? bytes("a[60]=")
                    : abi.encodePacked(
                        "a[e",
                        Strings.toString(ENSIP19.chainFromCoinType(coinType)),
                        "]="
                    )
            );
            if (useDefault && v.length == 0) {
                v = DNSTXTParserLib.find(context, "a[e0]=");
            }
            v = _parse0xString(v);
            if (v.length != 0 && v.length != 20) {
                revert InvalidDataLength(v, 20);
            }
        } else {
            v = _parse0xString(
                DNSTXTParserLib.find(
                    context,
                    abi.encodePacked("a[", Strings.toString(coinType), "]=")
                )
            );
        }
    }

    /// @dev Convert 0x-prefixed hex-string to bytes.
    ///      Reverts `InvalidHexData` if non-null and not a hex string.
    ///
    /// @param s The string to parse.
    ///
    /// @return v The parsed bytes.
    function _parse0xString(bytes memory s) internal pure returns (bytes memory v) {
        if (s.length > 0) {
            bool valid;
            if (s.length >= 2 && s[0] == "0" && s[1] == "x") {
                (v, valid) = HexUtils.hexToBytes(s, 2, s.length);
            }
            if (!valid) {
                revert InvalidHexData(s);
            }
        }
    }
}
