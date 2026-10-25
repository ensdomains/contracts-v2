// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockERC20 is ERC20Permit {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    uint8 private _decimals;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(string memory symbol, uint8 decimals_) ERC20(symbol, symbol) ERC20Permit(symbol) {
        _decimals = decimals_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates `amount` tokens for `to`.
    function mint(address to, uint256 amount) external virtual {
        _mint(to, amount);
    }

    /// @notice Burns the whole balance of `owner`.
    function nuke(address owner) external virtual {
        _burn(owner, balanceOf(owner));
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}


/// @notice Mock ERC-20 whose issuance is bounded by a total supply ceiling and a
/// per-call mint limit, with burning reserved for its admin.
/// @dev Used for the mock payment token on public testnets, where anyone may mint
/// from a faucet but the token must not be infinitely inflatable or wipeable.
contract MockERC20Capped is MockERC20 {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Maximum total supply the token can ever reach.
    uint256 public immutable MAX_SUPPLY;

    /// @notice Maximum amount a single mint call can create.
    uint256 public immutable MINT_LIMIT;

    /// @notice Account allowed to burn balances with {nuke}.
    address public immutable ADMIN;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice A mint asked for more than the per-call limit.
    error MintLimitExceeded(uint256 amount, uint256 limit);

    /// @notice A mint would take the total supply past {MAX_SUPPLY}.
    error MaxSupplyExceeded(uint256 amount, uint256 remainingSupply);

    /// @notice The caller is not {ADMIN}.
    error Unauthorized(address caller);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(string memory symbol, uint8 decimals_, uint256 maxSupply_, uint256 mintLimit_)
        MockERC20(symbol, decimals_)
    {
        MAX_SUPPLY = maxSupply_;
        MINT_LIMIT = mintLimit_;
        ADMIN = msg.sender;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates `amount` tokens for `to` within {MINT_LIMIT} and {MAX_SUPPLY}.
    function mint(address to, uint256 amount) external override {
        if (amount > MINT_LIMIT) {
            revert MintLimitExceeded(amount, MINT_LIMIT);
        }
        uint256 remainingSupply = MAX_SUPPLY - totalSupply();
        if (amount > remainingSupply) {
            revert MaxSupplyExceeded(amount, remainingSupply);
        }
        _mint(to, amount);
    }

    /// @notice Burns the whole balance of `owner`. Restricted to {ADMIN}.
    function nuke(address owner) external override {
        if (msg.sender != ADMIN) {
            revert Unauthorized(msg.sender);
        }
        _burn(owner, balanceOf(owner));
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

    constructor() MockERC20("BLACK", 6) {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function setBlacklisted(address account, bool blacklisted) external {
        isBlacklisted[account] = blacklisted;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _checkBlacklist(from);
        _checkBlacklist(to);
        return super.transferFrom(from, to, amount);
    }

    function _checkBlacklist(address addr) internal view {
        if (isBlacklisted[addr]) {
            revert Blacklisted(addr);
        }
    }
}


contract MockERC20VoidReturn is MockERC20 {
    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor() MockERC20("VOID", 11) {}

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
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor() MockERC20("FALSE", 13) {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false; // return false instead of revert
    }
}
