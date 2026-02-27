// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IResolverAuthority {
    function isAuthorized(string calldata label, address operator) external view returns (bool);
}
