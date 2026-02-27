// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {ENSRegistry} from "@ens/contracts/registry/ENSRegistry.sol";
import {
    BaseRegistrarImplementation
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {NameWrapper, IMetadataService} from "@ens/contracts/wrapper/NameWrapper.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {RegistryUtils} from "@ens/contracts/universalResolver/RegistryUtils.sol";

/// @dev Reusable testing fixture for ENSv1.
contract V1Fixture is Test, ERC721Holder, ERC1155Holder {
    ENSRegistry ensV1;
    BaseRegistrarImplementation ethRegistrarV1;
    NameWrapper nameWrapper;

    address user = makeAddr("user");
    address ensV1Controller = makeAddr("ensV1Controller");

    function deployV1Fixture() public {
        ensV1 = new ENSRegistry();
        ethRegistrarV1 = new BaseRegistrarImplementation(ensV1, NameCoder.ETH_NODE);
        ethRegistrarV1.addController(ensV1Controller);
        _claimNodes(NameCoder.encode("eth"), 0, address(ethRegistrarV1));
        _claimNodes(NameCoder.encode("addr.reverse"), 0, address(this)); // see: fake ReverseClaimer
        nameWrapper = new NameWrapper(ensV1, ethRegistrarV1, IMetadataService(address(0)));
        nameWrapper.setController(ensV1Controller, true);
        ethRegistrarV1.addController(address(nameWrapper));
        vm.warp(ethRegistrarV1.GRACE_PERIOD() + 1); // avoid timestamp issues
    }

    // fake ReverseClaimer
    function claim(address) external pure returns (bytes32) {}

    /// @dev Claim a name in the registry at any depth.
    ///      Preseves existing ownership until the leaf.
    function _claimNodes(bytes memory name, uint256 offset, address owner) internal {
        (bytes32 labelHash, uint256 nextOffset) = NameCoder.readLabel(name, offset);
        if (labelHash != bytes32(0)) {
            _claimNodes(name, nextOffset, owner);
            // claim if leaf or unset
            if (offset == 0 || ensV1.owner(NameCoder.namehash(name, offset)) == address(0)) {
                bytes32 parentNode = NameCoder.namehash(name, nextOffset);
                vm.prank(ensV1.owner(parentNode));
                ensV1.setSubnodeOwner(parentNode, labelHash, owner);
            }
        }
    }

    function registerUnwrapped(
        string memory label
    ) public returns (bytes memory name, uint256 tokenId) {
        name = NameCoder.ethName(label);
        tokenId = uint256(keccak256(bytes(label)));
        vm.prank(ensV1Controller);
        ethRegistrarV1.register(tokenId, user, 1 days); // test duration
    }

    function registerWrappedETH2LD(
        string memory label,
        uint32 ownerFuses
    ) public virtual returns (bytes memory name) {
        uint256 tokenId;
        (name, tokenId) = registerUnwrapped(label);
        address owner = ethRegistrarV1.ownerOf(tokenId);
        vm.startPrank(owner);
        ethRegistrarV1.setApprovalForAll(address(nameWrapper), true);
        nameWrapper.wrapETH2LD(label, owner, uint16(ownerFuses), address(0));
        vm.stopPrank();
    }

    function createWrappedChild(
        bytes memory parentName,
        string memory label,
        uint32 fuses
    ) public returns (bytes memory name) {
        bytes32 parentNode = NameCoder.namehash(parentName, 0);
        (address owner, , uint64 expiry) = nameWrapper.getData(uint256(parentNode));
        name = NameCoder.addLabel(parentName, label);
        vm.prank(owner);
        nameWrapper.setSubnodeOwner(parentNode, label, owner, fuses, expiry);
    }

    function createWrappedName(
        string memory domain,
        uint32 fuses
    ) public returns (bytes memory name) {
        name = NameCoder.encode(domain);
        _claimNodes(name, 0, user);
        (bytes32 labelHash, uint256 offset) = NameCoder.readLabel(name, 0);
        bytes32 parentNode = NameCoder.namehash(name, offset);
        vm.startPrank(user);
        ensV1.setApprovalForAll(address(nameWrapper), true);
        nameWrapper.wrap(name, user, address(0));
        if (fuses != 0) {
            // this might need to be setChildFuses()
            bytes32 node = NameCoder.namehash(parentNode, labelHash);
            nameWrapper.setFuses(node, uint16(fuses));
        }
        vm.stopPrank();
    }

    function findResolverV1(bytes memory name) public view returns (address resolver) {
        (resolver, , ) = RegistryUtils.findResolver(ensV1, name, 0);
    }
}
