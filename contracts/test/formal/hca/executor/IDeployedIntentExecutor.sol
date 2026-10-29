// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title Pinned IntentExecutor ABI
/// @notice Selected public methods of the verified deployed executor and its proxy.
/// @dev Tuple layouts and selectors are taken from fixtures/intent-executor.json.
interface IDeployedIntentExecutor {
    /// @notice The executor rejected the account's signature before executing or settling.
    error InvalidSignature();

    /// @notice The executor's encoded operation, including execution and signature modes.
    struct Operation {
        bytes data;
    }

    /// @notice A signed standalone operation scoped to one account, nonce, and chain.
    struct SingleChainOps {
        address account;
        uint256 nonce;
        Operation ops;
        bytes signature;
    }

    /// @notice Refund terms included in the signed digest.
    struct GasRefund {
        address token;
        uint256 exchangeRate;
        uint256 overhead;
    }

    /// @notice Executes the signed operation without a gas refund.
    function executeSinglechainOps(SingleChainOps calldata signedOps) external;

    /// @notice Executes the signed operation with the signed ERC20 refund terms.
    function executeSinglechainOpsWithGasRefund_ERC20(
        SingleChainOps calldata signedOps,
        GasRefund calldata gasRefund,
        address gasRefundRecipient
    )
        external
        returns (address account, uint256 nonce);

    /// @notice Executes the signed operation with a native-currency refund and cap.
    function executeSinglechainOpsWithGasRefund_ETH(
        SingleChainOps calldata signedOps,
        uint256 packedOverhead,
        address gasRefundRecipient
    )
        external
        returns (address account, uint256 nonce);

    /// @notice Reports whether this account has consumed the standalone nonce.
    function isStandaloneIntentNonceConsumed(uint256 nonce, address account)
        external
        view
        returns (bool);

    /// @notice Reports the per-account installation marker.
    function isInitialized(address account) external view returns (bool);

    /// @notice Writes the caller's installation marker.
    function onInstall(bytes calldata data) external;

    /// @notice Clears the caller's installation marker.
    function onUninstall(bytes calldata data) external;

    /// @notice Returns the proxy's current implementation.
    function implementation() external view returns (address);

    /// @notice Returns the proxy's current upgrade authority.
    function owner() external view returns (address);
}
