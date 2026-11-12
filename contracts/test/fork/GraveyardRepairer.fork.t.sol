// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {
    BaseRegistrarImplementation
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {ETHRenewerV1} from "~src/registrar/ETHRenewerV1.sol";
import {Graveyard} from "~src/migration/Graveyard.sol";
import {GraveyardRepairer} from "~src/migration/GraveyardRepairer.sol";

/// @dev Runs the repairer against the live mainnet contracts on a fork: the deployed
///      `Graveyard`, the solc 0.5 `BaseRegistrar` and the `ENSRegistryWithFallback`.
///      Skipped unless `MAINNET_RPC_URL` is set.
///
///      MAINNET_RPC_URL=<url> forge test --match-path test/fork/GraveyardRepairer.fork.t.sol -vv
contract GraveyardRepairerForkTest is Test {
    /// @dev A block at which `their.eth` has lapsed past its grace period while its
    ///      previous holder still owns the registry node.
    uint256 constant FORK_BLOCK = 26_298_296;

    Graveyard constant GRAVEYARD = Graveyard(0xDa021A2C1C2F99574D861Ef8c6fA745851BEB7F6);
    ETHRenewerV1 constant RENEWER = ETHRenewerV1(0x56c447F308F463A01121C41E72b0E7e7557fCb68);
    ENS constant REGISTRY = ENS(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e);
    BaseRegistrarImplementation constant BASE_REGISTRAR =
        BaseRegistrarImplementation(0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85);

    string constant LABEL = "their";
    address constant HOLDER = 0xbB49c781bd22C93c392a9B1e290501252b598AC3;

    GraveyardRepairer repairer;
    address evilResolver = makeAddr("evilResolver");

    function setUp() external {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        repairer = new GraveyardRepairer(GRAVEYARD);
    }

    function test_daoProposal_keepsRenewerWorking() external {
        _grantController();

        assertEq(BASE_REGISTRAR.owner(), address(RENEWER), "registrar owner");
        assertTrue(BASE_REGISTRAR.controllers(address(repairer)), "repairer");
        assertTrue(BASE_REGISTRAR.controllers(address(GRAVEYARD)), "graveyard");
        // reverts unless the renewer owns the registrar
        RENEWER.syncWrapper(new string[](0));
    }

    function test_repair_poisonedName() external {
        _grantController();
        bytes memory name = NameCoder.ethName(LABEL);
        bytes32 node = NameCoder.namehash(name, 0);
        uint256 tokenId = uint256(keccak256(bytes(LABEL)));

        assertEq(REGISTRY.owner(node), HOLDER, "holder");
        assertTrue(BASE_REGISTRAR.available(tokenId), "available");

        vm.prank(HOLDER);
        REGISTRY.setRecord(node, address(GRAVEYARD), evilResolver, 0);

        bytes[] memory names = new bytes[](1);
        names[0] = name;
        GRAVEYARD.clear(names);
        assertEq(REGISTRY.resolver(node), evilResolver, "graveyard skips");

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        assertEq(repairer.repair(ids), 1, "repaired");

        assertEq(REGISTRY.owner(node), address(GRAVEYARD), "owner");
        assertEq(REGISTRY.resolver(node), address(0), "resolver");
        assertEq(BASE_REGISTRAR.ownerOf(tokenId), address(GRAVEYARD), "token");
        assertFalse(BASE_REGISTRAR.available(tokenId), "registered");
        assertFalse(repairer.isRepairable(tokenId), "repairable");

        GRAVEYARD.clear(names);
    }

    /// @dev The DAO proposal: take the registrar from the renewer, add the controller,
    ///      and hand the registrar back, in one execution.
    function _grantController() internal {
        address dao = RENEWER.owner();
        vm.startPrank(dao);
        RENEWER.transferRegistrarOwnership(dao);
        BASE_REGISTRAR.addController(address(repairer));
        BASE_REGISTRAR.transferOwnership(address(RENEWER));
        vm.stopPrank();
    }
}
