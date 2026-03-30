// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {HCAContext, HCAEquivalence} from "~src/hca/HCAContext.sol";
import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";

contract MockERC20 is ERC20, HCAContext {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    uint8 private _decimals;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        string memory symbol,
        uint8 decimals_,
        IHCAFactoryBasic factory
    ) ERC20(symbol, symbol) HCAEquivalence(factory) {
        _decimals = decimals_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function nuke(address owner) external {
        _burn(owner, balanceOf(owner));
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function _msgSender() internal view virtual override(Context, HCAContext) returns (address) {
        return HCAContext._msgSender();
    }
}

contract MockERC20Blacklist is MockERC20 {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    mapping(address account => bool isBlacklisted) public isBlacklisted;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error Blacklisted(address);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor()
        MockERC20("BLACK", 6, IHCAFactoryBasic(0x0000000000000000000000000000000000000000))
    {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function setBlacklisted(address account, bool blacklisted) external {
        isBlacklisted[account] = blacklisted;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (isBlacklisted[from]) revert Blacklisted(from);
        if (isBlacklisted[to]) revert Blacklisted(to);
        return super.transferFrom(from, to, amount);
    }
}

contract MockERC20VoidReturn is MockERC20 {
    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor()
        MockERC20("VOID", 6, IHCAFactoryBasic(0x0000000000000000000000000000000000000000))
    {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        assembly {
            return(0, 0) // return void
        }
    }
}

contract MockERC20FalseReturn is MockERC20 {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    bool public shouldFail;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor()
        MockERC20("FALSE", 18, IHCAFactoryBasic(0x0000000000000000000000000000000000000000))
    {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false; // return false instead of revert
    }
}
