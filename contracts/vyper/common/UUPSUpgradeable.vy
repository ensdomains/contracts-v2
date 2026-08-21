# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

interface IERC1822Proxiable:
    def proxiableUUID() -> bytes32: view

IMPLEMENTATION_SLOT: constant(bytes32) = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
SELF: immutable(address)
_implementation: address

event Upgraded:
    implementation: indexed(address)

error UUPSUnauthorizedCallContext:
    pass

error UUPSUnsupportedProxiableUUID:
    slot: bytes32

error ERC1967InvalidImplementation:
    implementation: address

@abstract
def _authorize_upgrade(new_implementation: address):
    ...

@deploy
def __init__():
    SELF = self

@internal
@view
def _check_proxy():
    if self == SELF or self._implementation != SELF:
        raise UUPSUnauthorizedCallContext()

@external
@view
def proxiableUUID() -> bytes32:
    if self != SELF:
        raise UUPSUnauthorizedCallContext()
    return IMPLEMENTATION_SLOT

@external
@payable
def upgradeToAndCall(new_implementation: address, data: Bytes[65535]):
    self._check_proxy()
    self._authorize_upgrade(new_implementation)
    if not new_implementation.is_contract:
        raise ERC1967InvalidImplementation(implementation=new_implementation)
    uuid: bytes32 = staticcall IERC1822Proxiable(new_implementation).proxiableUUID()
    if uuid != IMPLEMENTATION_SLOT:
        raise UUPSUnsupportedProxiableUUID(slot=uuid)
    self._implementation = new_implementation
    log Upgraded(implementation=new_implementation)
    if len(data) != 0:
        raw_call(new_implementation, data, max_outsize=0, is_delegate_call=True)
