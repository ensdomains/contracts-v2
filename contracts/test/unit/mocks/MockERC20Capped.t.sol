// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {MockERC20Capped} from "~test/mocks/MockERC20.sol";

contract MockERC20CappedTest is Test {
    MockERC20Capped token;

    address admin;
    address alice;

    uint256 constant MAX_SUPPLY = 1_000e6;
    uint256 constant MINT_LIMIT = 100e6;

    function setUp() external {
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        vm.prank(admin);
        token = new MockERC20Capped("USDC", 6, MAX_SUPPLY, MINT_LIMIT);
    }

    function test_constructor() external view {
        assertEq(token.symbol(), "USDC", "symbol");
        assertEq(token.decimals(), 6, "decimals");
        assertEq(token.MAX_SUPPLY(), MAX_SUPPLY, "MAX_SUPPLY");
        assertEq(token.MINT_LIMIT(), MINT_LIMIT, "MINT_LIMIT");
        assertEq(token.ADMIN(), admin, "ADMIN");
        assertEq(token.totalSupply(), 0, "totalSupply");
    }

    function test_mint() external {
        vm.prank(alice);
        token.mint(alice, 1e6);
        assertEq(token.balanceOf(alice), 1e6, "balance");
        assertEq(token.totalSupply(), 1e6, "totalSupply");
    }

    function test_mint_atPerCallLimit() external {
        token.mint(alice, MINT_LIMIT);
        assertEq(token.balanceOf(alice), MINT_LIMIT, "balance");
    }

    function test_mint_revertAbovePerCallLimit() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC20Capped.MintLimitExceeded.selector,
                MINT_LIMIT + 1,
                MINT_LIMIT
            )
        );
        token.mint(alice, MINT_LIMIT + 1);
    }

    function test_mint_revertAboveMaxSupply() external {
        uint256 calls = MAX_SUPPLY / MINT_LIMIT;
        for (uint256 i; i < calls; ++i) {
            token.mint(alice, MINT_LIMIT);
        }
        assertEq(token.totalSupply(), MAX_SUPPLY, "totalSupply");
        vm.expectRevert(abi.encodeWithSelector(MockERC20Capped.MaxSupplyExceeded.selector, 1, 0));
        token.mint(alice, 1);
    }

    function test_mint_revertAboveRemainingSupply() external {
        // A ceiling that is not a whole number of mints leaves a remainder below the limit.
        MockERC20Capped capped = new MockERC20Capped("USDC", 6, 950e6, MINT_LIMIT);
        while (capped.totalSupply() + MINT_LIMIT <= capped.MAX_SUPPLY()) {
            capped.mint(alice, MINT_LIMIT);
        }
        uint256 remaining = capped.MAX_SUPPLY() - capped.totalSupply();
        assertLt(remaining, MINT_LIMIT, "remaining below per-call limit");
        vm.expectRevert(
            abi.encodeWithSelector(
                MockERC20Capped.MaxSupplyExceeded.selector,
                remaining + 1,
                remaining
            )
        );
        capped.mint(alice, remaining + 1);
    }

    function test_mint_fuzz(uint256 amount) external {
        amount = bound(amount, 0, MINT_LIMIT);
        token.mint(alice, amount);
        assertEq(token.balanceOf(alice), amount, "balance");
    }

    function test_nuke() external {
        token.mint(alice, 1e6);
        vm.prank(admin);
        token.nuke(alice);
        assertEq(token.balanceOf(alice), 0, "balance");
        assertEq(token.totalSupply(), 0, "totalSupply");
    }

    function test_nuke_revertNotAdmin() external {
        token.mint(alice, 1e6);
        vm.expectRevert(abi.encodeWithSelector(MockERC20Capped.Unauthorized.selector, alice));
        vm.prank(alice);
        token.nuke(alice);
    }
}
