# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..common import OwnableUpgradeable as Ownable
from ..common import UUPSUpgradeable as UUPS

initializes: Ownable
initializes: UUPS
exports: (
    Ownable.owner,
    Ownable.transferOwnership,
    Ownable.renounceOwnership,
    UUPS.proxiableUUID,
    UUPS.upgradeToAndCall,
)

@deploy
def __init__():
    UUPS.__init__()

@override(UUPS)
def _authorize_upgrade(new_implementation: address):
    Ownable._check_owner()

@external
def initialize(owner_: address):
    Ownable._initialize_owner(owner_)

@external
@view
def supportsInterface(interface_id: bytes4) -> bool:
    return interface_id == convert(method_id("isContractNamer(address)"), bytes4) or interface_id == 0x01ffc9a7

@external
@view
def isContractNamer(namer: address) -> bool:
    return Ownable._owner_value() == namer
