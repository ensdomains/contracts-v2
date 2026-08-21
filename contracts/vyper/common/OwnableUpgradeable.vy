# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

_owner: address
_initialized: bool

event OwnershipTransferred:
    previousOwner: indexed(address)
    newOwner: indexed(address)

error OwnableUnauthorizedAccount:
    account: address

error OwnableInvalidOwner:
    owner: address

error InvalidInitialization:
    pass

@internal
def _initialize_owner(initial_owner: address):
    if self._initialized:
        raise InvalidInitialization()
    if initial_owner == empty(address):
        raise OwnableInvalidOwner(owner=initial_owner)
    self._initialized = True
    self._owner = initial_owner
    log OwnershipTransferred(previousOwner=empty(address), newOwner=initial_owner)

@internal
@view
def _check_owner():
    if msg.sender != self._owner:
        raise OwnableUnauthorizedAccount(account=msg.sender)

@internal
@view
def _owner_value() -> address:
    return self._owner

@external
@view
def owner() -> address:
    return self._owner

@external
def transferOwnership(new_owner: address):
    self._check_owner()
    if new_owner == empty(address):
        raise OwnableInvalidOwner(owner=new_owner)
    old_owner: address = self._owner
    self._owner = new_owner
    log OwnershipTransferred(previousOwner=old_owner, newOwner=new_owner)

@external
def renounceOwnership():
    self._check_owner()
    old_owner: address = self._owner
    self._owner = empty(address)
    log OwnershipTransferred(previousOwner=old_owner, newOwner=empty(address))
