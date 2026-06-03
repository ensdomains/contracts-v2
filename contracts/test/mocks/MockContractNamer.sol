// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";

contract MockContractNamer is IContractNamer {
    address internal immutable NAMER;
    constructor(address namer) {
        NAMER = namer;
    }
    function isContractNamer(address namer) external view returns (bool) {
        return namer == NAMER;
    }
}
