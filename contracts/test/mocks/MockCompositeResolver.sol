// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ICompositeResolver} from "@ens/contracts/resolvers/profiles/ICompositeResolver.sol";
import {OffchainLookup} from "@ens/contracts/ccipRead/EIP3668.sol";

contract MockCompositeResolver is ERC165, ICompositeResolver {
    address public resolver;
    bool public offchain;
    string[] internal _gateways;
    bytes public callbackRevertData;
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(ICompositeResolver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    function setResolver(address x) external {
        resolver = x;
    }
    function setCallbackRevert(bytes calldata v) external {
        callbackRevertData = v;
    }
    function setOnchain() external {
        offchain = false;
    }
    function setOffchain() external {
        offchain = true;
        delete _gateways;
        _gateways.push("data:application/json,{\"data\":\"0x\"}");
    }
    function setGateways(string[] memory v) external {
        offchain = true;
        _gateways = v;
    }
    function getResolver(bytes calldata) external view returns (address, bool) {
        if (!offchain) {
            return (resolver, false);
        }
        revert OffchainLookup(address(this), _gateways, "", this.getResolverCallback.selector, "");
    }
    function getResolverCallback(bytes calldata, bytes calldata)
        external
        view
        returns (address, bool)
    {
        bytes memory v = callbackRevertData;
        if (v.length > 0) {
            assembly {
                revert(add(v, 32), mload(v))
            }
        }
        return (resolver, true);
    }
    function resolve(bytes calldata, bytes calldata) external pure returns (bytes memory) {
        return ""; // unused
    }
    function getGateways() external view returns (string[] memory) {
        return _gateways;
    }
}
