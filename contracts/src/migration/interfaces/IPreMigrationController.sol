// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

/// @dev Interface selector: `0x116350fe`
interface IPreMigrationController {
    /// @notice Claim a pre-migrated name (called by migration controllers)
    /// @dev All roles transfer with the token since pre-migration registers with ROLES.ALL
    /// @param label The label of the name being claimed
    /// @param owner The new owner of the name
    /// @param subregistry The subregistry to set for the name
    /// @param resolver The resolver to set for the name
    function claim(
        string calldata label,
        address owner,
        IRegistry subregistry,
        address resolver
    ) external;
}
