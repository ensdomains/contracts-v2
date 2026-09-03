// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {ERC1155Singleton} from "~src/erc1155/ERC1155Singleton.sol";
import {IERC1155Singleton} from "~src/erc1155/interfaces/IERC1155Singleton.sol";

/// @dev Exercises singleton NFT rules without registry expiry/version overlays.
contract ERC1155SingletonTest is Test, ERC1155Holder {
    ERC1155SingletonHarness token;
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    uint256 id = 7;

    function setUp() external {
        token = new ERC1155SingletonHarness();
        token.mint(user1, id);
    }

    function test_ownerOf_and_balance() external view {
        assertEq(token.ownerOf(id), user1);
        assertEq(token.balanceOf(user1, id), 1);
        assertEq(token.balanceOf(user2, id), 0);
        assertEq(token.balanceOf(address(0), id), 0);
    }

    function test_supportsInterface() external view {
        assertTrue(token.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(token.supportsInterface(type(IERC1155Singleton).interfaceId));
    }

    function test_safeTransferFrom_valueGreaterThanOne() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector,
                user1,
                1,
                2,
                id
            )
        );
        vm.prank(user1);
        token.safeTransferFrom(user1, user2, id, 2, "");
    }

    function test_safeTransferFrom_movesSingleOwner() external {
        vm.prank(user1);
        token.safeTransferFrom(user1, user2, id, 1, "");
        assertEq(token.ownerOf(id), user2);
        assertEq(token.balanceOf(user1, id), 0);
        assertEq(token.balanceOf(user2, id), 1);
    }

    function test_safeTransferFrom_zeroValueDoesNotChangeOwner() external {
        vm.prank(user1);
        token.safeTransferFrom(user1, user2, id, 0, "");
        assertEq(token.ownerOf(id), user1);
        assertEq(token.balanceOf(user1, id), 1);
    }

    function test_mint_existingIdFromZeroReverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector,
                address(0),
                0,
                1,
                id
            )
        );
        token.mint(user2, id);
        assertEq(token.ownerOf(id), user1);
    }
}


contract ERC1155SingletonHarness is ERC1155Singleton {
    function uri(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint(address to, uint256 id) external {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = id;
        values[0] = 1;
        _update(address(0), to, ids, values);
    }
}
