# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..utils import LibLabel as labels_lib

MAX_BATCH: constant(uint256) = 256
AVAILABLE: constant(uint8) = 0
RESERVED: constant(uint8) = 1

struct RegistryState:
    status: uint8
    expiry: uint64
    latestOwner: address
    tokenId: uint256
    resource: uint256

interface IPermissionedRegistry:
    def getState(any_id: uint256) -> RegistryState: view
    def register(label: String[255], owner: address, registry: address, resolver: address, role_bitmap: uint256, expiry: uint64) -> uint256: nonpayable
    def renew(any_id: uint256, new_expiry: uint64): nonpayable

_ETH_REGISTRY: immutable(address)
_OWNER: immutable(address)

error InputLengthMismatch:
    pass

error OwnableUnauthorizedAccount:
    account: address

@deploy
def __init__(eth_registry: address, owner_: address):
    _ETH_REGISTRY = eth_registry
    _OWNER = owner_

@external
@view
def ETH_REGISTRY() -> address:
    return _ETH_REGISTRY

@external
@view
def owner() -> address:
    return _OWNER

@external
def batchRegister(
    registry: address,
    resolver: address,
    labels: DynArray[String[255], MAX_BATCH],
    expires: DynArray[uint64, MAX_BATCH],
):
    if msg.sender != _OWNER:
        raise OwnableUnauthorizedAccount(account=msg.sender)
    if len(labels) != len(expires):
        raise InputLengthMismatch()

    for i: uint256 in range(MAX_BATCH):
        if i >= len(labels):
            break
        state: RegistryState = staticcall IPermissionedRegistry(_ETH_REGISTRY).getState(labels_lib.id(labels[i]))
        if state.status == AVAILABLE:
            extcall IPermissionedRegistry(_ETH_REGISTRY).register(
                labels[i],
                empty(address),
                registry,
                resolver,
                0,
                expires[i],
            )
        elif state.status == RESERVED and expires[i] > state.expiry:
            extcall IPermissionedRegistry(_ETH_REGISTRY).renew(state.tokenId, expires[i])
