// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IHCAFactoryBasic} from "./IHCAFactoryBasic.sol";
import {IHCAInitDataParser} from "./IHCAInitDataParser.sol";

/// @title IHCAFactory
/// @notice Full interface for deterministic Hidden Contract Account deployment and lookup.
/// @dev Interface selector: `0xb16756da`
interface IHCAFactory is IHCAFactoryBasic {
    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Deploys or funds the deterministic HCA for the owner encoded in `initData`.
    /// @param initData Initialization data used to identify and initialize the HCA owner.
    /// @return hca The deployed or existing HCA proxy address.
    function createAccount(bytes calldata initData) external payable returns (address payable hca);

    /// @notice Selects the implementation used when deploying this account's HCA.
    /// @param accountImplementation The implementation to select.
    function setAccountImplementation(address accountImplementation) external;

    /// @notice Updates the implementation and init data parser selectable for new HCA proxies.
    /// @param implementation_ The new implementation address.
    /// @param initDataParser_ The parser used to extract account ownership from initialization data.
    function setImplementation(address implementation_, IHCAInitDataParser initDataParser_)
        external;

    /// @notice Returns the implementation selectable for newly deployed HCA proxies.
    function implementation() external view returns (address);

    /// @notice Returns the parser used to extract account ownership from initialization data.
    function initDataParser() external view returns (IHCAInitDataParser);

    /// @notice Returns the immutable implementation that lets an owner defer their HCA upgrade target.
    function deferredImplementation() external view returns (address);

    /// @notice Returns the implementation explicitly selected by an account.
    /// @param account The account to inspect.
    /// @return implementation The selected implementation.
    function accountImplementationOf(address account)
        external
        view
        returns (address implementation);

    /// @notice Computes the deterministic HCA proxy address for an owner.
    /// @param owner The owner whose HCA address to predict.
    /// @return hca The deterministic proxy address.
    function computeAccountAddress(address owner) external view returns (address payable hca);

    /// @notice Extracts the HCA owner from initialization data.
    /// @param initData The initialization data to parse.
    /// @return hcaOwner The owner encoded in the initialization data.
    function getOwnerFromHCAInitdata(bytes calldata initData)
        external
        view
        returns (address hcaOwner);
}
