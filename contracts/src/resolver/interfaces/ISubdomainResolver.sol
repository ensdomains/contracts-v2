// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface ISubdomainResolver {
    function resolveSubdomain(
        string calldata label,
        bytes calldata data
    ) external view returns (bytes memory);
}
