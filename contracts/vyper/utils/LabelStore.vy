# pragma version ~=0.4.3
# SPDX-License-Identifier: MIT

interface IContractNamer:
    def isContractNamer(namer: address) -> bool: view

event Label:
    labelHash: indexed(bytes32)
    label: String[255]

_CONTRACT_NAMER: immutable(address)
_labels: HashMap[uint256, String[255]]

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
    return interface_id == 0x0d48fe93 or interface_id == method_id("isContractNamer(address)") or interface_id == 0x01ffc9a7

@external
@view
def isContractNamer(namer: address) -> bool:
    return staticcall IContractNamer(_CONTRACT_NAMER).isContractNamer(namer)

@internal
@pure
def _storage_id(any_id: uint256) -> uint256:
    return any_id ^ (any_id & 0xffffffff)

@external
def setLabel(label: String[1024]):
    n: uint256 = len(label)
    if n == 0:
        raw_revert(method_id("LabelIsEmpty()"))
    if n > 255:
        raw_revert(abi_encode(label, method_id=method_id("LabelIsTooLong(string)")))

    stored_label: String[255] = convert(label, String[255])
    label_id: uint256 = convert(keccak256(stored_label), uint256)
    storage_id: uint256 = self._storage_id(label_id)
    if len(self._labels[storage_id]) == 0:
        self._labels[storage_id] = stored_label
        log Label(convert(label_id, bytes32), stored_label)

@external
@view
def getLabel(any_id: uint256) -> String[255]:
    return self._labels[self._storage_id(any_id)]
