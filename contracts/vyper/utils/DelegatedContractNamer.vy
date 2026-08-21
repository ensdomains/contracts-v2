# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

interface IContractNamer:
    def isContractNamer(namer: address) -> bool: view

_CONTRACT_NAMER: immutable(address)

@deploy
def __init__(contract_namer: address):
    _CONTRACT_NAMER = contract_namer

@external
@view
def CONTRACT_NAMER() -> address:
    return _CONTRACT_NAMER

@external
@view
def supportsInterface(interface_id: bytes4) -> bool:
    return interface_id == convert(method_id("isContractNamer(address)"), bytes4) or interface_id == 0x01ffc9a7

@external
@view
def isContractNamer(namer: address) -> bool:
    return staticcall IContractNamer(_CONTRACT_NAMER).isContractNamer(namer)
