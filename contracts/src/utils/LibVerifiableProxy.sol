// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CloneProxyBytecode} from "@ensdomains/verifiable-factory/CloneProxyBytecode.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title Verifiable Proxy Library
/// @notice Computes deterministic addresses for verifiable proxies.
/// @dev Uses the caller-bound salt and shared proxy logic from VerifiableFactory.
library LibVerifiableProxy {
    /// @notice Computes the proxy address for a deployer and user salt.
    /// @dev Mirrors the factory's caller-bound salt and clone bytecode derivation.
    /// @param deployer The account calling the factory to deploy the proxy.
    /// @param salt The user salt supplied to the factory.
    /// @param factory The verifiable factory.
    /// @param proxyLogic The factory's proxy logic.
    /// @return proxy The counterfactual proxy address.
    function computeAddress(address deployer, uint256 salt, address factory, address proxyLogic)
        internal
        pure
        returns (address proxy)
    {
        bytes32 outerSalt = keccak256(abi.encode(deployer, salt));
        return
            Create2.computeAddress(
                outerSalt,
                keccak256(CloneProxyBytecode.creationCode(proxyLogic, outerSalt)),
                factory
            );
    }
}
