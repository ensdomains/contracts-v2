// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {
    AbstractETHRegistrar,
    IHCAFactoryBasic,
    IETHRenewer,
    IRentPriceOracle,
    IPermissionedRegistry,
    Ownable
} from "~src/registrar/AbstractETHRegistrar.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";

contract AbstractETHRegistrarTest is MigrationControllerFixture, StandardRentPriceOracleFixture {
    MockRegistrar ethRegistrar;

    function setUp() external {
        deployMigrationControllerFixture();
        deployStandardRentPriceOracleFixture();

        ethRegistrar = new MockRegistrar(
            address(this),
            hcaFactory,
            ethRegistry,
            beneficiary,
            rentPriceOracle
        );
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(address(ethRegistrar), type(IETHRenewer).interfaceId),
            "IETHRenewer"
        );
    }

    function test_constructor() external view {
        assertEq(ethRegistrar.owner(), address(this), "owner");
        assertEq(address(ethRegistrar.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
        assertEq(address(ethRegistrar.BENEFICIARY()), address(beneficiary), "BENFICIARY");
        assertEq(
            address(ethRegistrar.rentPriceOracle()),
            address(rentPriceOracle),
            "rentPriceOracle"
        );
    }

    function test_setRentPriceOracle() external {
        IRentPriceOracle oracle = IRentPriceOracle(makeAddr("oracle"));
        vm.expectEmit();
        emit AbstractETHRegistrar.RentPriceOracleUpdated(oracle);
        ethRegistrar.setRentPriceOracle(oracle);
        assertEq(address(ethRegistrar.rentPriceOracle()), address(oracle));
    }

    function test_setRentPriceOracle_notAuthorized() external {
        address actor = makeAddr("actor");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        vm.prank(actor);
        ethRegistrar.setRentPriceOracle(IRentPriceOracle(address(1)));
    }
}

contract MockRegistrar is AbstractETHRegistrar {
    uint64 public constant GRACE_PERIOD = 0;
    constructor(
        address owner_,
        IHCAFactoryBasic hcaFactory,
        IPermissionedRegistry ethRegistry,
        address beneficiary,
        IRentPriceOracle oracle
    ) AbstractETHRegistrar(owner_, hcaFactory, ethRegistry, beneficiary, oracle) {}
    function _isRenewable(
        IPermissionedRegistry.State memory
    ) internal pure override returns (bool) {
        return false;
    }
    function getRemainingGracePeriod(string calldata) external pure returns (uint64) {
        return 0;
    }
}
