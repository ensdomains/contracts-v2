# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

MAX_CHAIN_IDS: constant(uint256) = 256
_chain_ids: DynArray[uint256, MAX_CHAIN_IDS]

error ChainIdsLengthOverflow:
    pass

@internal
def add_chain_ids(chain_ids: DynArray[uint256, MAX_CHAIN_IDS]):
    if len(self._chain_ids) + len(chain_ids) > MAX_CHAIN_IDS:
        raise ChainIdsLengthOverflow()
    for i: uint256 in range(MAX_CHAIN_IDS):
        if i >= len(chain_ids):
            break
        self._chain_ids.append(chain_ids[i])

@internal
@view
def get_chain_ids() -> DynArray[uint256, MAX_CHAIN_IDS]:
    return self._chain_ids
