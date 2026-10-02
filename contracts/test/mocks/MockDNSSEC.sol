// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DNSSEC} from "@ens/contracts/dnssec-oracle/DNSSEC.sol";
import {RRUtils} from "@ens/contracts/dnssec-oracle/RRUtils.sol";

/// @dev This DNSSEC impl ignores the gateway response and returns the rrs
///      supplied to `setResponse()` from `verifyRRSet()` and never fails.
contract MockDNSSEC is DNSSEC {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    bytes private _rrs;

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function setResponse(bytes memory rrs_) external {
        _rrs = rrs_;
    }

    function verifyRRSet(RRSetWithSignature[] memory input)
        external
        view
        override
        returns (RRUtils.SignedSet[] memory)
    {
        return verifyRRSet(input, block.timestamp);
    }

    function verifyRRSet(RRSetWithSignature[] memory, uint256)
        public
        view
        override
        returns (RRUtils.SignedSet[] memory sss)
    {
        sss = new RRUtils.SignedSet[](1);
        sss[0].data = _rrs;
    }
}
