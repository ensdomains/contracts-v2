# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..reverse_registrar.libraries import ChainIdsBuilderLib as builder

initializes: builder

@external
def addChainIds(chain_ids: DynArray[uint256, 256]):
    builder.add_chain_ids(chain_ids)

@external
@view
def getChainIds() -> DynArray[uint256, 256]:
    return builder.get_chain_ids()
