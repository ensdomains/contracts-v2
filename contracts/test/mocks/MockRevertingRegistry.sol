// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IOwnedRegistry} from "~src/registry/interfaces/IOwnedRegistry.sol";

contract MockRevertingRegistry is ERC165, IOwnedRegistry {
    mapping(bytes4 selector => bytes data) public revertData;
    function setRevertData(bytes4 selector, bytes calldata data) external {
        revertData[selector] = data;
    }
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IRegistry).interfaceId ||
            interfaceId == type(IOwnedRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    function getResolver(string calldata) external view returns (address) {
        _tryRevert();
        return address(0);
    }
    function getSubregistry(string calldata) external view returns (IRegistry) {
        _tryRevert();
        return IRegistry(address(0));
    }
    function getParent() external view returns (IRegistry, string memory) {
        _tryRevert();
        return (IRegistry(address(0)), "");
    }
    function findOwner(string calldata) external view returns (address) {
        _tryRevert();
        return address(0);
    }
    function _tryRevert() internal view {
        bytes memory v = revertData[bytes4(msg.data)];
        if (v.length > 0) {
            assembly {
                revert(add(v, 32), mload(v))
            }
        }
    }
}
