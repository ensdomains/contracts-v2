// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IContractNamer} from "../interfaces/IContractNamer.sol";

/// @dev Determine if an address is nameable. 
library AddressNamerLib {
    /// @dev Error selector: `0x0d1b7e4e`
    error UnauthorizedNamer(address namer);

    /// @dev Check if an address can be named.
    /// @param addr The address to name.
    /// @param namer The address of the namer.
    /// @return canName `true` if `namer` can name `addr`.
    function isNamer(address addr, address namer) internal view returns (bool canName) {
        if (addr.code.length == 0) {
            canName = addr == namer;
        } else {
            try Ownable(addr).owner() returns (address owner) {
                canName = owner == namer;
            } catch {}
            if (!canName) {
                try IContractNamer(addr).isContractNamer(namer) returns (bool can) {
                    canName = can;
                } catch {}
            }
        }
    }

    /// @dev Ensure `namer` can name `addr`.
    /// @param addr The address to name.
    /// @param namer The address of the namer.
    function requireNamer(address addr, address namer) internal view {
        if (!isNamer(addr, namer)) {
            revert UnauthorizedNamer(namer);
        }
    }
}
