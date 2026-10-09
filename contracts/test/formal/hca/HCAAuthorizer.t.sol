// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {HCAAuthorizer} from "~src/hca/HCAAuthorizer.sol";
import {StandaloneHCAFactory} from "~src/hca/StandaloneHCAFactory.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IStandaloneHCAFactory} from "~src/hca/interfaces/IStandaloneHCAFactory.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

import {HCAAccountFixture, HCAFormalOwnerRegistry} from "./account/HCAAccountFixture.sol";

import {Execution} from "nexus/types/DataTypes.sol";

/// @notice Exposes the production authorizer's internal entry points without replacing their logic.
contract HCAFormalAuthorizer is HCAAuthorizer {
    address public lastAuthorized;

    constructor(IStandaloneHCAFactory factory_) HCAAuthorizer(factory_) {}

    function resolve() external view returns (address) {
        return _hcaOwner();
    }

    function requireOwner(address expected) external view returns (address) {
        return _requireHCAForAccount(expected);
    }

    function recordForOwner(address expected) external {
        lastAuthorized = _requireHCAForAccount(expected);
    }
}


/// @notice Universal caller/certificate equality and rejection rules at the factory-response boundary.
/// @dev The mocked registry supplies arbitrary certificates; real certificate creation is proved
///      separately, and the integration suite below connects the production factory to this consumer.
contract HCAAuthorizerTest is Test {
    HCAFormalOwnerRegistry internal registry;
    HCAFormalAuthorizer internal authorizer;

    function setUp() public {
        registry = new HCAFormalOwnerRegistry(new VerifiableFactory());
        authorizer = new HCAFormalAuthorizer(IStandaloneHCAFactory(address(registry)));
    }

    function check_resolveRequiresNonzeroCallerCertificate(address caller, address certified)
        public
    {
        registry.certify(caller, certified);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(authorizer).staticcall(abi.encodeCall(authorizer.resolve, ()));
        if (certified == address(0)) {
            assert(!ok);
            assert(
                keccak256(data) ==
                keccak256(
                    abi.encodeWithSelector(HCAAuthorizer.HCADeploymentNotTrusted.selector, caller)
                )
            );
        } else {
            assert(ok);
            assert(abi.decode(data, (address)) == certified);
        }
    }

    function check_ownerRequirementTruthTable(address caller, address certified, address claimed)
        public
    {
        registry.certify(caller, certified);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(authorizer).staticcall(abi.encodeCall(authorizer.requireOwner, (claimed)));
        if (certified == address(0)) {
            assert(!ok);
            assert(
                keccak256(data) ==
                keccak256(
                    abi.encodeWithSelector(HCAAuthorizer.HCADeploymentNotTrusted.selector, caller)
                )
            );
        } else if (certified != claimed) {
            assert(!ok);
            assert(
                keccak256(data) ==
                keccak256(
                    abi.encodeWithSelector(
                        HCAAuthorizer.HCAOwnerMismatch.selector,
                        claimed,
                        certified
                    )
                )
            );
        } else {
            assert(ok);
            assert(abi.decode(data, (address)) == certified);
        }
    }

    function check_certificateCannotBeBorrowedByOtherCaller(
        address hca,
        address caller,
        address certified
    )
        public
    {
        vm.assume(hca != caller);
        vm.assume(certified != address(0));
        registry.certify(hca, certified);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(authorizer).staticcall(abi.encodeCall(authorizer.requireOwner, (certified)));
        assert(!ok);
        assert(
            keccak256(data) ==
            keccak256(abi.encodeWithSelector(HCAAuthorizer.HCADeploymentNotTrusted.selector, caller))
        );
    }

    function check_originDoesNotGrantAuthorization(address caller, address origin, address certified)
        public
    {
        vm.assume(origin != caller);
        vm.assume(certified != address(0));
        registry.certify(origin, certified);
        vm.prank(caller, origin);
        (bool ok, ) =
            address(authorizer).staticcall(abi.encodeCall(authorizer.requireOwner, (certified)));
        assert(!ok);
    }

    function check_certificateUpdatesForOtherAccountDoNotChangeCaller(
        address caller,
        address other,
        address certified,
        address otherOwner
    )
        public
    {
        vm.assume(caller != other);
        vm.assume(certified != address(0));
        registry.certify(caller, certified);
        registry.certify(other, otherOwner);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(authorizer).staticcall(abi.encodeCall(authorizer.requireOwner, (certified)));
        assert(ok);
        assert(abi.decode(data, (address)) == certified);
    }
}


/// @notice End-to-end owner transaction, real HCA execution, and factory-certified authorization traces.
contract HCAAuthorizerIntegrationTest is HCAAccountFixture {
    StandaloneHCAFactory internal factory;
    HCAFormalAuthorizer internal authorizer;
    StandaloneSingleOwnerHCA internal certified;

    function setUp() public override {
        super.setUp();
        factory = new StandaloneHCAFactory(proxyFactory, address(this));
        StandaloneSingleOwnerHCA initial =
            _implementation(IStandaloneHCAFactory(address(factory)), IAddressSet(address(0)));
        factory.setImplementationApproval(address(initial), true);
        certified = StandaloneSingleOwnerHCA(
            payable(factory.deploy(INITIAL_OWNER, address(initial), 0))
        );
        authorizer = new HCAFormalAuthorizer(factory);
    }

    function check_hcaExecutionAuthorizesExactlyCertifiedOwner(address claimed, uint96 nonce)
        public
    {
        vm.store(address(certified), OWNER_NONCE_SLOT, bytes32(uint256(nonce) << 160));
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution(
            address(authorizer),
            0,
            abi.encodeCall(authorizer.recordForOwner, (claimed))
        );
        vm.prank(INITIAL_OWNER);
        (bool ok, bytes memory data) =
            address(certified).call(abi.encodeCall(certified.executeByOwner, (calls)));
        if (claimed == INITIAL_OWNER) {
            assert(ok);
            assert(authorizer.lastAuthorized() == INITIAL_OWNER);
        } else {
            _assertRevert(ok, data, HCAAuthorizer.HCAOwnerMismatch.selector);
            assert(authorizer.lastAuthorized() == address(0));
        }
        (, uint96 afterNonce) = certified.ownerAndSessionNonce();
        assert(afterNonce == nonce);
    }

    function check_uncertifiedAccountCannotClaimSameOwner() public {
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution(
            address(authorizer),
            0,
            abi.encodeCall(authorizer.recordForOwner, (INITIAL_OWNER))
        );
        vm.prank(INITIAL_OWNER);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        _assertRevert(ok, data, HCAAuthorizer.HCADeploymentNotTrusted.selector);
        assert(authorizer.lastAuthorized() == address(0));
        assert(account.owner() == certified.owner());
    }

    function check_revocationDoesNotRevokeImmutableOwnerCertificate(uint96 nonce) public {
        vm.store(address(certified), OWNER_NONCE_SLOT, bytes32(uint256(nonce) << 160));
        vm.prank(INITIAL_OWNER);
        (bool revoked, ) = address(certified).call(abi.encodeCall(certified.revokeSessions, ()));
        assert(revoked);
        vm.prank(address(certified));
        (bool ok, bytes memory data) =
            address(authorizer).staticcall(abi.encodeCall(authorizer.requireOwner, (INITIAL_OWNER)));
        assert(ok);
        assert(abi.decode(data, (address)) == INITIAL_OWNER);
        assert(factory.authorizedOwnerOf(address(certified)) == INITIAL_OWNER);
    }
}
