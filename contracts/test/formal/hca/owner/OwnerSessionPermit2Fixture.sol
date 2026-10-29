// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";
import {HCAPermit2Lib} from "~src/hca/libraries/HCAPermit2Lib.sol";

import {OwnerSessionFixture} from "./OwnerSessionFixture.sol";

/// @title HCA Owner Session Permit2 Wire Fixture
/// @notice Independently encodes and hashes the one-source-token, one-output-token Permit2 route.
/// @dev Reuses production typehash constants while deriving the ABI struct hashes and packed fields
///      independently of the production decoder. No Permit2 transfer or cross-chain execution is
///      modeled. The production validator's destination authorization is the verification subject.
abstract contract OwnerSessionPermit2Fixture is OwnerSessionFixture {
    /// @dev Returns a destination claim whose deadline and fill expiry are unbounded uint256 maxima.
    function _claim() internal view returns (HCAPermit2Lib.Claim memory claim) {
        claim.spender = address(0xC1A1);
        claim.deadline = type(uint256).max;
        claim.sourceToken = PAYMENT_TOKEN;
        claim.sourceAmount = 1;
        claim.recipient = address(account);
        claim.targetChainId = block.chainid;
        claim.fillExpiry = type(uint256).max;
        claim.tokenOut = PAYMENT_TOKEN;
        claim.amountOut = 1;
    }

    /// @dev Independently encodes the exact 410-byte supported claim shape.
    function _claimData(HCAPermit2Lib.Claim memory claim, bytes32 operationHash)
        internal
        pure
        returns (bytes memory data)
    {
        bytes memory source =
            abi.encodePacked(
                claim.spender,
                claim.nonce,
                claim.deadline,
                uint8(1),
                bytes32(uint256(uint160(claim.sourceToken))),
                claim.sourceAmount
            );
        bytes memory target =
            abi.encodePacked(
                claim.recipient,
                claim.targetChainId,
                claim.fillExpiry,
                uint8(1),
                bytes32(uint256(uint160(claim.tokenOut))),
                claim.amountOut
            );
        data = bytes.concat(
            source,
            target,
            abi.encodePacked(uint128(0), bytes32(0), operationHash, bytes32(0))
        );
        assert(data.length == HCAPermit2Lib.CLAIM_DATA_LENGTH);
    }

    /// @dev Independently reconstructs the EIP-712 batch-witness digest for the fixture's claim shape.
    function _permitDigest(
        HCAPermit2Lib.Claim memory claim,
        uint256 sourceChain,
        bytes32 operationHash
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 sourceTokens =
            keccak256(
                abi.encodePacked(
                    keccak256(
                        abi.encode(
                            HCAPermit2Lib.TOKEN_PERMISSIONS_TYPEHASH,
                            claim.sourceToken,
                            claim.sourceAmount
                        )
                    )
                )
            );
        bytes32 targetTokens =
            keccak256(
                abi.encodePacked(
                    keccak256(
                        abi.encode(HCAPermit2Lib.TOKEN_TYPEHASH, claim.tokenOut, claim.amountOut)
                    )
                )
            );
        bytes32 target =
            keccak256(
                abi.encode(
                    HCAPermit2Lib.TARGET_TYPEHASH,
                    claim.recipient,
                    targetTokens,
                    claim.targetChainId,
                    claim.fillExpiry
                )
            );
        bytes32 mandate =
            keccak256(
                abi.encode(
                    HCAPermit2Lib.MANDATE_TYPEHASH,
                    target,
                    uint128(0),
                    bytes32(0),
                    operationHash,
                    bytes32(0)
                )
            );
        bytes32 permit =
            keccak256(
                abi.encode(
                    HCAPermit2Lib.PERMIT_TYPEHASH,
                    sourceTokens,
                    claim.spender,
                    claim.nonce,
                    claim.deadline,
                    mandate
                )
            );
        bytes32 domain =
            keccak256(
                abi.encode(
                    HCAPermit2Lib.EIP712_DOMAIN_TYPEHASH,
                    HCAPermit2Lib.PERMIT2_NAME_HASH,
                    sourceChain,
                    codec.permit2Address()
                )
            );
        return MessageHashUtils.toTypedDataHash(domain, permit);
    }

    /// @dev Builds a complete signed Permit2 session around a canonical ERC-1271 operation.
    function _permitEnvelope(
        HCAPermit2Lib.Claim memory claim,
        Execution[] memory executions,
        uint256 sourceChain
    )
        internal
        view
        returns (Envelope memory envelope)
    {
        bytes32 mode = HCAOperationHashLib.ERC7579_ERC1271_MODE;
        bytes32 operationHash = _operationHash(mode, executions);
        envelope.digest = _permitDigest(claim, sourceChain, operationHash);
        envelope.data = _permitWire(
            _claimData(claim, operationHash),
            sourceChain,
            _encode(mode, executions),
            envelope.digest
        );
    }

    /// @dev Combines a standard owner authorization with arbitrary claim and operation byte strings.
    function _permitWire(
        bytes memory claimData,
        uint256 sourceChain,
        bytes memory operation,
        bytes32 digest
    )
        internal
        view
        returns (bytes memory)
    {
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        return
            bytes.concat(
                abi.encodePacked(codec.permit2Mode(), permissionId, packed, sourceChain),
                claimData,
                operation,
                _sign(SESSION_KEY, digest)
            );
    }
}
