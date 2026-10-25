// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";

/// @notice Test-only mock for configurable upgrade behavior.  Supports VerifiableFactory.
contract MockUpgradeable is UUPSUpgradeable, IProxyAuthorization {
    mapping(address impl => bool on) public upgradeFrom;
    mapping(address impl => bool on) public upgradeTo;
    bytes public revertDuringCanUpgradeFrom;

    function setUpgradeFrom(address impl, bool on) external {
        upgradeFrom[impl] = on;
    }

    function setUpgradeTo(address impl, bool on) external {
        upgradeTo[impl] = on;
    }

    function setRevertDuringCanUpgradeFrom(bytes memory revertData) external {
        revertDuringCanUpgradeFrom = revertData;
    }

    function canUpgradeFrom(address previousImplementation) external view returns (bool) {
        bytes memory v = revertDuringCanUpgradeFrom;
        if (v.length > 0) {
            assembly {
                revert(add(v, 32), mload(v))
            }
        }
        return upgradeFrom[previousImplementation];
    }

    function _authorizeUpgrade(address newImplementation) internal view override {
        require(upgradeTo[newImplementation]);
    }

    function unique() external pure {}
}