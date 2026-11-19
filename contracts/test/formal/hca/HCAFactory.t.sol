// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAAccountFixture} from "./account/HCAAccountFixture.sol";

import {StandaloneHCAFactory} from "~src/hca/StandaloneHCAFactory.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IStandaloneHCAFactory} from "~src/hca/interfaces/IStandaloneHCAFactory.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Approved implementation with a deliberately wrong owner response.
contract HCAFormalWrongOwner {
    function initializeAccount(bytes calldata) external pure {}

    function owner() external pure returns (address) {
        return address(0);
    }
}


/// @notice Approved implementation whose owner query deliberately reverts.
contract HCAFormalUnavailableOwner {
    error OwnerQueryUnavailable();

    function initializeAccount(bytes calldata) external pure {}

    function owner() external pure returns (address) {
        revert OwnerQueryUnavailable();
    }
}


/// @notice Approved implementation that deliberately changes the proxy implementation during initialization.
contract HCAFormalUnexpectedImplementation {
    function initializeAccount(bytes calldata) external {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assembly ("memory-safe") {
            sstore(slot, 0)
        }
    }
}


/// @notice Factory certification, governance, deterministic deployment, and reuse proofs.
/// @dev Uses the production factory, HCA, VerifiableFactory, clone, and UUPSProxyLogic.
///      CREATE2/Keccak address reasoning inherits Halmos's collision-free hash abstraction.
contract HCAFactoryTest is HCAAccountFixture {
    StandaloneHCAFactory internal factory;
    StandaloneSingleOwnerHCA internal initial;
    HCAFormalWrongOwner internal wrongOwner;
    HCAFormalUnavailableOwner internal unavailableOwner;
    HCAFormalUnexpectedImplementation internal unexpectedImplementation;

    function setUp() public override {
        super.setUp();
        factory = new StandaloneHCAFactory(proxyFactory, address(this));
        initial = _implementation(IStandaloneHCAFactory(address(factory)), IAddressSet(address(0)));
        wrongOwner = new HCAFormalWrongOwner();
        unavailableOwner = new HCAFormalUnavailableOwner();
        unexpectedImplementation = new HCAFormalUnexpectedImplementation();
    }

    function check_approvedDeploymentCertifiesSymbolicOwner(
        address owner_,
        address relayer,
        uint256 salt
    )
        public
    {
        vm.assume(owner_ != address(0));
        factory.setImplementationApproval(address(initial), true);
        address predicted = _predicted(owner_, address(initial), salt);
        vm.prank(relayer);
        (bool ok, bytes memory data) =
            address(factory).call(abi.encodeCall(factory.deploy, (owner_, address(initial), salt)));
        assert(ok);
        address deployed = abi.decode(data, (address));
        assert(deployed == predicted);
        _assertCertificate(deployed, owner_);
        assert(_implementationOf(deployed) == address(initial));
        (address reported, uint96 nonce) =
            StandaloneSingleOwnerHCA(payable(deployed)).ownerAndSessionNonce();
        assert(reported == owner_);
        assert(nonce == 0);
    }

    function check_deploymentApprovalTruthTable(address relayer, bool approved) public {
        factory.setImplementationApproval(address(initial), approved);
        address predicted = _predicted(INITIAL_OWNER, address(initial), 0);
        vm.prank(relayer);
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.deploy, (INITIAL_OWNER, address(initial), 0))
            );
        if (approved) {
            assert(ok);
            assert(abi.decode(data, (address)) == predicted);
            _assertCertificate(predicted, INITIAL_OWNER);
        } else {
            _assertRevert(ok, data, StandaloneHCAFactory.HCAImplementationNotApproved.selector);
            _assertCertificate(predicted, address(0));
            assert(predicted.code.length == 0);
        }
    }

    function check_differentOwnersCannotOverwriteCertificates(
        address first,
        address second,
        uint256 salt
    )
        public
    {
        vm.assume(first != address(0) && second != address(0) && first != second);
        factory.setImplementationApproval(address(initial), true);
        address firstAccount = factory.deploy(first, address(initial), salt);
        address secondAccount = factory.deploy(second, address(initial), salt);
        assert(firstAccount != secondAccount);
        _assertCertificate(firstAccount, first);
        _assertCertificate(secondAccount, second);
        assert(StandaloneSingleOwnerHCA(payable(firstAccount)).owner() == first);
        assert(StandaloneSingleOwnerHCA(payable(secondAccount)).owner() == second);
    }

    function check_differentNamespacesPreserveExistingAccount(
        address owner_,
        uint256 first,
        uint256 second
    )
        public
    {
        vm.assume(owner_ != address(0) && first != second);
        factory.setImplementationApproval(address(initial), true);
        address firstAccount = factory.deploy(owner_, address(initial), first);
        address secondAccount = factory.deploy(owner_, address(initial), second);
        assert(firstAccount != secondAccount);
        _assertCertificate(firstAccount, owner_);
        _assertCertificate(secondAccount, owner_);
    }

    function check_zeroOwnerRejected(address candidate, uint256 salt) public {
        (bool ok, bytes memory data) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(0), candidate, salt)));
        _assertRevert(ok, data, StandaloneHCAFactory.OwnerCannotBeZero.selector);
    }

    function check_zeroImplementationRejected(address owner_, uint256 salt) public {
        vm.assume(owner_ != address(0));
        (bool ok, bytes memory data) =
            address(factory).call(abi.encodeCall(factory.deploy, (owner_, address(0), salt)));
        _assertRevert(ok, data, StandaloneHCAFactory.HCAImplementationCannotBeZero.selector);
    }

    function check_unapprovedImplementationCannotCertify(
        address owner_,
        address candidate,
        uint256 salt
    )
        public
    {
        vm.assume(owner_ != address(0));
        vm.assume(candidate != address(0));
        address predicted = _predicted(owner_, candidate, salt);
        (bool ok, bytes memory data) =
            address(factory).call(abi.encodeCall(factory.deploy, (owner_, candidate, salt)));
        _assertRevert(ok, data, StandaloneHCAFactory.HCAImplementationNotApproved.selector);
        _assertCertificate(predicted, address(0));
    }

    function check_governanceApprovalAuthorization(
        address governor,
        address caller,
        address candidate,
        bool wasApproved,
        bool approved
    )
        public
    {
        vm.assume(governor != address(0));
        vm.assume(candidate != address(0));
        factory.setImplementationApproval(candidate, wasApproved);
        _seedGovernor(governor);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.setImplementationApproval, (candidate, approved))
            );
        if (caller == governor) {
            assert(ok);
            assert(factory.approvedImplementations(candidate) == approved);
        } else {
            _assertRevert(ok, data, Ownable.OwnableUnauthorizedAccount.selector);
            assert(factory.approvedImplementations(candidate) == wasApproved);
        }
        assert(factory.owner() == governor);
    }

    function check_approvalChangePreservesOtherImplementation(
        address first,
        address other,
        bool oldOther,
        bool approved
    )
        public
    {
        vm.assume(first != address(0));
        vm.assume(other != address(0) && first != other);
        factory.setImplementationApproval(other, oldOther);
        factory.setImplementationApproval(first, approved);
        assert(factory.approvedImplementations(first) == approved);
        assert(factory.approvedImplementations(other) == oldOther);
    }

    function check_zeroImplementationCannotBeApproved(bool approved) public {
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.setImplementationApproval, (address(0), approved))
            );
        _assertRevert(ok, data, StandaloneHCAFactory.HCAImplementationCannotBeZero.selector);
        assert(!factory.approvedImplementations(address(0)));
    }

    function check_governanceTransferAuthorization(
        address governor,
        address caller,
        address successor
    )
        public
    {
        vm.assume(governor != address(0));
        _seedGovernor(governor);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(factory).call(abi.encodeCall(factory.transferOwnership, (successor)));
        if (caller != governor) {
            _assertRevert(ok, data, Ownable.OwnableUnauthorizedAccount.selector);
            assert(factory.owner() == governor);
        } else if (successor == address(0)) {
            _assertRevert(ok, data, Ownable.OwnableInvalidOwner.selector);
            assert(factory.owner() == governor);
        } else {
            assert(ok);
            assert(factory.owner() == successor);
        }
    }

    function check_oldGovernorLosesApprovalAccess(address successor) public {
        vm.assume(successor != address(0) && successor != address(this));
        factory.transferOwnership(successor);
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.setImplementationApproval, (address(initial), true))
            );
        _assertRevert(ok, data, Ownable.OwnableUnauthorizedAccount.selector);
        vm.prank(successor);
        (bool granted, ) =
            address(factory).call(
                abi.encodeCall(factory.setImplementationApproval, (address(initial), true))
            );
        assert(granted);
        assert(factory.approvedImplementations(address(initial)));
    }

    function check_renouncedGovernanceRejectsNonzeroCallers(address caller) public {
        vm.assume(caller != address(0));
        factory.renounceOwnership();
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.setImplementationApproval, (address(initial), true))
            );
        _assertRevert(ok, data, Ownable.OwnableUnauthorizedAccount.selector);
        assert(factory.owner() == address(0));
    }

    function check_saltBindsOwnerImplementationAndNamespace(
        address owner_,
        address candidate,
        uint256 salt
    )
        public
        view
    {
        assert(
            factory.deploymentSalt(owner_, candidate, salt) ==
            uint256(keccak256(abi.encode(salt, owner_, candidate)))
        );
    }

    function check_unknownAccountHasNoCertificate(address unknown) public view {
        assert(factory.authorizedOwnerOf(unknown) == address(0));
        assert(factory.hcaOwners(unknown) == address(0));
    }

    function check_wrongOwnerRollsBackCertification(address owner_, uint256 salt) public {
        vm.assume(owner_ != address(0));
        _assertRejectedDeployment(
            owner_,
            address(wrongOwner),
            salt,
            StandaloneHCAFactory.UnexpectedHCAOwner.selector
        );
    }

    function check_unavailableOwnerRollsBackCertification(address owner_, uint256 salt) public {
        vm.assume(owner_ != address(0));
        _assertRejectedDeployment(
            owner_,
            address(unavailableOwner),
            salt,
            StandaloneHCAFactory.HCAOwnerUnavailable.selector
        );
    }

    function check_initializerCannotSubstituteImplementation(address owner_, uint256 salt) public {
        vm.assume(owner_ != address(0));
        _assertRejectedDeployment(
            owner_,
            address(unexpectedImplementation),
            salt,
            StandaloneHCAFactory.UnexpectedHCAImplementation.selector
        );
    }

    function _assertRejectedDeployment(
        address owner_,
        address candidate,
        uint256 salt,
        bytes4 expectedError
    )
        internal
    {
        factory.setImplementationApproval(candidate, true);
        address predicted = _predicted(owner_, candidate, salt);
        (bool ok, bytes memory data) =
            address(factory).call(abi.encodeCall(factory.deploy, (owner_, candidate, salt)));
        _assertRevert(ok, data, expectedError);
        _assertCertificate(predicted, address(0));
        assert(predicted.code.length == 0);
        assert(factory.approvedImplementations(candidate));
    }

    function _seedGovernor(address governor) internal {
        vm.store(address(factory), bytes32(uint256(0)), bytes32(uint256(uint160(governor))));
        assert(factory.owner() == governor);
    }

    function _assertCertificate(address deployed, address owner_) internal view {
        assert(factory.hcaOwners(deployed) == owner_);
        assert(factory.authorizedOwnerOf(deployed) == owner_);
    }

    function _predicted(address owner_, address candidate, uint256 salt)
        internal
        view
        returns (address)
    {
        return
            proxyFactory.predictProxyAddress(
                address(factory),
                factory.deploymentSalt(owner_, candidate, salt)
            );
    }
}


/// @notice Lifecycle traces after a real owner certificate has been created.
contract HCAFactoryReuseTest is HCAAccountFixture {
    StandaloneHCAFactory internal factory;
    StandaloneSingleOwnerHCA internal initial;
    StandaloneSingleOwnerHCA internal certified;

    function setUp() public override {
        super.setUp();
        factory = new StandaloneHCAFactory(proxyFactory, address(this));
        initial = _implementation(IStandaloneHCAFactory(address(factory)), IAddressSet(address(0)));
        factory.setImplementationApproval(address(initial), true);
        certified = StandaloneSingleOwnerHCA(
            payable(factory.deploy(INITIAL_OWNER, address(initial), 0))
        );
    }

    function check_deployIsIdempotentAcrossRelayersAndApprovalChanges(
        address caller,
        bool approved,
        uint96 nonce
    )
        public
    {
        vm.store(address(certified), OWNER_NONCE_SLOT, bytes32(uint256(nonce) << 160));
        factory.setImplementationApproval(address(initial), approved);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.deploy, (INITIAL_OWNER, address(initial), 0))
            );
        assert(ok);
        assert(abi.decode(data, (address)) == address(certified));
        _assertCertifiedState(nonce, address(initial));
    }

    function check_reuseAfterUpgradePreservesCurrentImplementation(address caller, uint96 nonce)
        public
    {
        vm.store(address(certified), OWNER_NONCE_SLOT, bytes32(uint256(nonce) << 160));
        StandaloneSingleOwnerHCA next =
            _implementation(IStandaloneHCAFactory(address(factory)), predecessorSet);
        targetSet.set(address(next), true);
        predecessorSet.set(address(initial), true);
        vm.prank(INITIAL_OWNER);
        (bool upgraded, ) =
            address(certified).call(abi.encodeCall(certified.upgradeToAndCall, (address(next), "")));
        assert(upgraded);
        factory.setImplementationApproval(address(initial), false);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(factory).call(
                abi.encodeCall(factory.deploy, (INITIAL_OWNER, address(initial), 0))
            );
        assert(ok);
        assert(abi.decode(data, (address)) == address(certified));
        _assertCertifiedState(nonce, address(next));
    }

    function check_approvalChangesCannotRewriteCertificate(address candidate, bool approved) public {
        vm.assume(candidate != address(0));
        factory.setImplementationApproval(candidate, approved);
        _assertCertifiedState(0, address(initial));
    }

    function check_governanceTransferCannotRewriteCertificate(address governor) public {
        vm.assume(governor != address(0));
        factory.transferOwnership(governor);
        _assertCertifiedState(0, address(initial));
    }

    function check_certifiedAccountCannotBeReinitializedByOutsider(address caller, address proposed)
        public
    {
        vm.assume(caller != address(proxyFactory));
        vm.assume(proposed != address(0));
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(certified).call(
                abi.encodeCall(certified.initializeAccount, (abi.encode(proposed)))
            );
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.StandaloneHCAAlreadyInitialized.selector);
        _assertCertifiedState(0, address(initial));
    }

    function check_deployerInitializationCannotRewriteCertificate(address proposed) public {
        vm.assume(proposed != address(0));
        vm.prank(address(proxyFactory));
        (bool ok, ) =
            address(certified).call(
                abi.encodeCall(certified.initializeAccount, (abi.encode(proposed)))
            );
        assert(ok);
        _assertCertifiedState(0, address(initial));
    }

    function _assertCertifiedState(uint96 nonce, address currentImplementation) internal view {
        assert(factory.hcaOwners(address(certified)) == INITIAL_OWNER);
        assert(factory.authorizedOwnerOf(address(certified)) == INITIAL_OWNER);
        (address owner_, uint96 actualNonce) = certified.ownerAndSessionNonce();
        assert(owner_ == INITIAL_OWNER);
        assert(actualNonce == nonce);
        assert(_implementationOf(address(certified)) == currentImplementation);
    }
}
