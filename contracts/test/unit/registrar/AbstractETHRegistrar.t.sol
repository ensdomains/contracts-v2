// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {AbstractETHRegistrar} from "~src/registrar/AbstractETHRegistrar.sol";
import {IETHRenewer} from "~src/registrar/interfaces/IETHRenewer.sol";
import {IRentPriceOracle} from "~src/registrar/interfaces/IRentPriceOracle.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {HCAFixture} from "~test/fixtures/HCAFixture.sol";

contract AbstractETHRegistrarTest is
    MigrationControllerFixture,
    StandardRentPriceOracleFixture,
    HCAFixture
{
    MockRegistrar ethRegistrar;

    function setUp() external {
        deployMigrationControllerFixture();
        deployStandardRentPriceOracleFixture();
        deployHCAFixture();

        ethRegistrar = new MockRegistrar(
            address(this),
            ethRegistry,
            beneficiary,
            rentPriceOracle,
            verifiableFactory,
            trustedHCASet
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
        assertEq(
            address(ethRegistrar.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "VERIFIABlE_FACTORY"
        );
        assertEq(address(ethRegistrar.TRUSTED_HCA_SET()), address(trustedHCASet), "TRUSTED_HCA_SET");
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
        IPermissionedRegistry ethRegistry,
        address beneficiary,
        IRentPriceOracle oracle,
        IVerifiableFactory verifiableFactory,
        IAddressSet trustedHCASet
    )
        AbstractETHRegistrar(
            owner_,
            ethRegistry,
            beneficiary,
            oracle,
            verifiableFactory,
            trustedHCASet
        )
    {}
    function _isRenewable(IPermissionedRegistry.State memory) internal pure override returns (bool) {
        return false;
    }
    function getRemainingGracePeriod(string calldata) external pure returns (uint64) {
        return 0;
    }
}
