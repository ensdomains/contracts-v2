// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {CCIPReader} from "@ens/contracts/ccipRead/CCIPBatcher.sol";
import {ICompositeResolver} from "@ens/contracts/resolvers/profiles/ICompositeResolver.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {LibRegistry} from "./libraries/LibRegistry.sol";

contract CompositeHelper is DelegatedContractNamer, CCIPReader {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct Component {
        address resolver;
        bool offchain;
        bytes err;
    }

    struct State {
        bytes name;
        address resolver;
        bool offchain;
        Component[] comps;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The root registry.
    /// @param contractNamer Delegated contract namer.
    constructor(IPermissionedRegistry rootRegistry, IContractNamer contractNamer)
        CCIPReader(DEFAULT_UNSAFE_CALL_GAS)
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function getResolvers(bytes calldata name) external view returns (Component[] memory) {
        (, address resolver, , ) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0);
        return _getResolvers(State(name, resolver, false, new Component[](0)));
    }

    function getResolversCallback(bytes calldata response, bytes calldata extraData)
        external
        view
        returns (Component[] memory)
    {
        State memory state = abi.decode(extraData, (State));
        (state.resolver, state.offchain) = abi.decode(response, (address, bool));
        return _getResolvers(state);
    }

    function getResolversCallbackError(bytes calldata response, bytes calldata extraData)
        external
        pure
        returns (Component[] memory)
    {
        State memory state = abi.decode(extraData, (State));
        state.comps[state.comps.length - 1].err = response;
        return state.comps;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    function _getResolvers(State memory state) internal view returns (Component[] memory) {
        uint256 n = state.comps.length;
        Component[] memory v = new Component[](n + 1);
        for (uint256 i; i < n; ++i) {
            v[i] = state.comps[i];
        }
        v[n] = Component(state.resolver, state.offchain, "");
        if (!ERC165Checker.supportsInterface(state.resolver, type(ICompositeResolver).interfaceId)) {
            return v;
        }
        state.comps = v;
        ccipRead(
            state.resolver,
            abi.encodeCall(ICompositeResolver.getResolver, (state.name)),
            this.getResolversCallback.selector,
            this.getResolversCallbackError.selector,
            abi.encode(state)
        );
    }
}
