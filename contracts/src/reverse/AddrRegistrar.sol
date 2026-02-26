// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

uint256 constant ROLE_SET = 1 << 0;
uint256 constant ROLE_SET_ADMIN = ROLE_SET << 128;

contract AddrRegistrar is EnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct Entry {
        uint256 resource;
        address resolver;
        string name;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The maximum number of claimed resources.
    uint256 public getResourceMax;

    mapping(address addr => Entry entry) internal _entries;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event ResourceReplaced(address indexed addr, uint256 oldResource, uint256 newResource);
    event AddrUpdated(address indexed addr, string name, address resolver, address sender);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(IHCAFactoryBasic hcaFactory) HCAEquivalence(hcaFactory) {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function reclaim(string calldata name) external {
        address self = _msgSender();
        _register(self, name, address(0), self);
    }

    function reclaim(address resolver) external {
        address self = _msgSender();
        _register(self, "", resolver, self);
    }

    function reclaimTo(address to, string calldata name) external {
        _register(_msgSender(), name, address(0), to);
    }

    function reclaimTo(address to, address resolver) external {
        _register(_msgSender(), "", resolver, to);
    }

    function setName(address addr, string calldata name) external {
        Entry storage entry = _entries[addr];
        address sender = _msgSender();
        _checkRoles(entry.resource, ROLE_SET, sender);
        delete entry.resolver;
        entry.name = name;
        emit AddrUpdated(addr, name, address(0), sender);
    }

    function setResolver(address addr, address resolver) external {
        Entry storage entry = _entries[addr];
        address sender = _msgSender();
        _checkRoles(entry.resource, ROLE_SET, sender);
        entry.resolver = resolver;
        delete entry.name;
        emit AddrUpdated(addr, "", resolver, sender);
    }

    function authorize(address addr, address to, bool on) external returns (bool) {
        Entry storage entry = _entries[addr];
        _checkRoles(entry.resource, ROLE_SET, _msgSender());
        return
            on
                ? _grantRoles(entry.resource, ROLE_SET, to, false)
                : _revokeRoles(entry.resource, ROLE_SET, to, false);
    }

    function getName(address addr) external view returns (string memory) {
        return _entries[addr].name;
    }

    function getResolver(address addr) external view returns (address) {
        return _entries[addr].resolver;
    }

    function getResource(address addr) external view returns (uint256) {
        return _entries[addr].resource;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    function _register(address addr, string memory name, address resolver, address to) internal {
        if (to == address(0)) {
            revert InvalidOwner();
        }
        Entry storage entry = _entries[addr];
        uint256 oldResource = entry.resource;
        uint256 newResource = ++getResourceMax;
        entry.resource = newResource;
        entry.resolver = resolver;
        entry.name = name;
        emit ResourceReplaced(addr, oldResource, newResource);
        emit AddrUpdated(addr, name, resolver, addr);
        _grantRoles(newResource, ROLE_SET_ADMIN | ROLE_SET, to, false);
    }
}
