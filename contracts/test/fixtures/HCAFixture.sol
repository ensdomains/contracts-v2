// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {IStandaloneHCAOwner} from "~src/hca/interfaces/IStandaloneHCAOwner.sol";

/// @title HCA Test Fixture
/// @notice Provides factory-certified and uncertified HCAs for adapter tests.
abstract contract HCAFixture is Test {
    MockHCA trustedHCAImpl;
    MockHCA untrustedHCAImpl;
    MockRevertingHCA revertingHCAImpl;
    MockHCADeploymentRegistry standaloneHCAFactory;

    uint256 private nextSalt = 1;

    function deployHCAFixture() public {
        trustedHCAImpl = new MockHCA();
        untrustedHCAImpl = new MockHCA();
        revertingHCAImpl = new MockRevertingHCA();
        standaloneHCAFactory = new MockHCADeploymentRegistry();
    }

    function test_factoryCertificationFixture() external view {
        assertEq(standaloneHCAFactory.authorizedOwnerOf(address(trustedHCAImpl)), address(0));
    }

    function _deployHCA(IVerifiableFactory verifiableFactory, address hcaOwner, address hcaImpl)
        internal
        returns (address)
    {
        bytes memory data = abi.encodeCall(MockHCA.initialize, (hcaOwner));
        address hca = verifiableFactory.deployProxy(hcaImpl, nextSalt++, data);
        standaloneHCAFactory.recordDeployment(hca, hcaOwner);
        return hca;
    }
}


/// @title Mock HCA Deployment Registry
/// @notice Records immutable owner bindings treated as factory certifications by adapter tests.
contract MockHCADeploymentRegistry {
    mapping(address hca => address owner) public hcaOwners;

    /// @notice Records an owner binding for a fixture HCA.
    /// @param hca The fixture HCA.
    /// @param owner The owner to bind to the HCA.
    function recordDeployment(address hca, address owner) external {
        hcaOwners[hca] = owner;
    }

    /// @notice Returns the certified owner for a fixture HCA.
    /// @param hca The fixture HCA.
    /// @return owner The recorded owner, or zero for an unknown HCA.
    function authorizedOwnerOf(address hca) external view returns (address owner) {
        return hcaOwners[hca];
    }
}


/// @title Mock HCA
/// @notice Stores an initialized owner and exposes the standalone HCA ownership interface.
contract MockHCA is IStandaloneHCAOwner {
    address internal _owner;

    /// @notice Initializes the fixture owner.
    /// @param owner_ The owner to store.
    function initialize(address owner_) external {
        _owner = owner_;
    }

    /// @inheritdoc IStandaloneHCAOwner
    function owner() external view virtual returns (address) {
        return _owner;
    }

    /// @inheritdoc IStandaloneHCAOwner
    function ownerAndSessionNonce() external view returns (address, uint96) {
        return (_owner, 0);
    }
}


/// @title Reverting Mock HCA
/// @notice Models an HCA implementation whose owner cannot be queried at runtime.
contract MockRevertingHCA is MockHCA {
    error OwnerUnavailable();

    /// @notice Reverts instead of returning the stored owner.
    function owner() external pure override returns (address) {
        revert OwnerUnavailable();
    }
}
