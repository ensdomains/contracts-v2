// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {CloneProxyBytecode} from "@ensdomains/verifiable-factory/CloneProxyBytecode.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {Grant} from "~src/access-control/interfaces/IEACGrantInitializable.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IPermissionedResolver} from "~src/resolver/interfaces/IPermissionedResolver.sol";
import {
    IPermissionedResolverInitializable
} from "~src/resolver/interfaces/IPermissionedResolverInitializable.sol";

import {OwnerSessionFixture} from "./owner/OwnerSessionFixture.sol";

/// @title HCA Owner Session Resolver Deployment Policy Proofs
/// @notice Verifies complete signed sessions that request counterfactual resolver deployment.
/// @dev These are policy-admission proofs through the exact production validator, not execution of
///      the factory or resolver initializer. A pending resolver is explicitly assumed nonzero and
///      code-free. CREATE2 is independently reconstructed using the factory bytecode definition.
///      Batches contain at most two actions, grants at most three, and initializer calls at most two
///      children with two multicall levels. Salts, grantees, roles, and record words are symbolic.
contract HCAOwnerSessionDeployment is OwnerSessionFixture {
    /// @notice A canonical pending deployment with HCA and owner full-access grants is admitted.
    function check_canonicalDeployment(uint256 salt) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        _accept(_deploymentEnvelope(proof, _deployment(salt, _grants(), new bytes[](0))));
    }

    /// @notice The requested implementation must be the constructor-bound permitted implementation.
    function check_deploymentImplementation(uint256 salt, address implementation) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        bytes memory initData =
            abi.encodeCall(
                IPermissionedResolverInitializable.initialize,
                (_grants(), new bytes[](0))
            );
        bytes memory deployment =
            abi.encodeCall(IVerifiableFactory.deployProxy, (implementation, salt, initData));
        Envelope memory envelope = _deploymentEnvelope(proof, deployment);
        if (implementation == RESOLVER_IMPLEMENTATION)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Only the exact permissioned-resolver initialization selector is admitted.
    function check_initializerSelector(uint256 salt, bytes4 selector) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        bytes memory initData = abi.encodePacked(selector, abi.encode(_grants(), new bytes[](0)));
        Envelope memory envelope =
            _deploymentEnvelope(
                proof,
                abi.encodeCall(
                    IVerifiableFactory.deployProxy,
                    (RESOLVER_IMPLEMENTATION, salt, initData)
                )
            );
        if (selector == IPermissionedResolverInitializable.initialize.selector)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice The first grant must name the account that will call the factory.
    function check_accountGrantBinding(uint256 salt, address grantee) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Grant[] memory grants = _grants();
        grants[0].account = grantee;
        Envelope memory envelope =
            _deploymentEnvelope(proof, _deployment(salt, grants, new bytes[](0)));
        if (grantee == address(account))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice The second grant must name the current account owner, including all address aliases.
    function check_ownerGrantBinding(uint256 salt, address grantee) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Grant[] memory grants = _grants();
        grants[1].account = grantee;
        Envelope memory envelope =
            _deploymentEnvelope(proof, _deployment(salt, grants, new bytes[](0)));
        if (grantee == owner)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Both grants require the exact full-role bitmap rather than a subset or extra role encoding.
    function check_grantRoleBitmaps(uint256 salt, uint256 roles, bool ownerGrant) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Grant[] memory grants = _grants();
        grants[ownerGrant ? 1 : 0].roleBitmap = roles;
        Envelope memory envelope =
            _deploymentEnvelope(proof, _deployment(salt, grants, new bytes[](0)));
        if (roles == EACBaseRolesLib.ALL_ROLES)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Zero, one, and three grants are rejected; exactly the two prescribed grants are admitted.
    /// @dev The symbolic count is explicitly bounded to zero through three.
    function check_exactGrantCount(uint256 salt, uint8 count, address extraGrantee) public {
        vm.assume(count <= 3);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Grant[] memory grants;
        if (count == 0)
            grants = new Grant[](0);
        else if (count == 1)
            grants = new Grant[](1);
        else if (count == 2)
            grants = new Grant[](2);
        else
            grants = new Grant[](3);
        if (count > 0)
            grants[0] = Grant(address(account), EACBaseRolesLib.ALL_ROLES);
        if (count > 1)
            grants[1] = Grant(owner, EACBaseRolesLib.ALL_ROLES);
        if (count > 2)
            grants[2] = Grant(extraGrantee, EACBaseRolesLib.ALL_ROLES);
        Envelope memory envelope =
            _deploymentEnvelope(proof, _deployment(salt, grants, new bytes[](0)));
        if (count == 2)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice An added duplicate grant is rejected even when it grants no new principal access.
    function check_duplicateGrantRejected(uint256 salt, bool duplicateOwner) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Grant[] memory grants = new Grant[](3);
        grants[0] = Grant(address(account), EACBaseRolesLib.ALL_ROLES);
        grants[1] = Grant(owner, EACBaseRolesLib.ALL_ROLES);
        grants[2] = grants[duplicateOwner ? 1 : 0];
        _reject(
            _deploymentEnvelope(proof, _deployment(salt, grants, new bytes[](0))),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Deployment binds the signed resolver to the account, salt, factory, and proxy bytecode.
    function check_predictedResolverBinding(uint256 salt, address claimedResolver) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        address predicted = proof.resolver;
        proof.resolver = claimedResolver;
        Envelope memory envelope =
            _deploymentEnvelope(proof, _deployment(salt, _grants(), new bytes[](0)));
        if (claimedResolver == predicted)
            _accept(envelope);
        else if (claimedResolver == address(factory))
            _reject(envelope, HCAOwnerAndSessionValidator.ActionNotAllowed.selector);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A permitted deployment must appear before a registration that names its resolver.
    function check_deploymentBeforeRegister(uint256 salt, bytes32 label, bool deploymentFirst)
        public
    {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Execution[] memory executions = new Execution[](2);
        executions[deploymentFirst ? 0 : 1] = Execution(
            address(factory),
            0,
            _deployment(salt, _grants(), new bytes[](0))
        );
        executions[deploymentFirst ? 1 : 0] = Execution(
            address(registrar),
            0,
            abi.encodeCall(
                IETHRegistrar.register,
                (
                    string(abi.encodePacked(label)),
                    owner,
                    bytes32(0),
                    IRegistry(address(0)),
                    proof.resolver,
                    uint64(0),
                    IERC20(PAYMENT_TOKEN),
                    bytes32(0)
                )
            )
        );
        Envelope memory envelope = _envelope(proof, executions, 0, _noRefund());
        if (deploymentFirst)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A permitted deployment must appear before a direct record call to its resolver.
    function check_deploymentBeforeRecord(
        uint256 salt,
        bytes32 name,
        uint256 resource,
        bool deploymentFirst
    )
        public
    {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Execution[] memory executions = new Execution[](2);
        executions[deploymentFirst ? 0 : 1] = Execution(
            address(factory),
            0,
            _deployment(salt, _grants(), new bytes[](0))
        );
        executions[deploymentFirst ? 1 : 0] = Execution(
            proof.resolver,
            0,
            abi.encodeCall(IPermissionedResolver.linkToRecord, (abi.encodePacked(name), resource))
        );
        Envelope memory envelope = _envelope(proof, executions, 0, _noRefund());
        if (deploymentFirst)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice The same pending resolver cannot be deployed twice in one admitted batch.
    function check_duplicateDeploymentRejected(uint256 salt) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution(address(factory), 0, _deployment(salt, _grants(), new bytes[](0)));
        executions[1] = executions[0];
        _reject(
            _envelope(proof, executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice An otherwise exact deployment cannot redeploy a resolver that already has code.
    /// @dev The one-byte runtime models code presence only and is never executed by the validator.
    function check_existingResolverCannotBeDeployed(uint256 salt) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        vm.etch(proof.resolver, hex"00");
        _reject(
            _deploymentEnvelope(proof, _deployment(salt, _grants(), new bytes[](0))),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Supported nested record calls may be included in the canonical initialization calldata.
    function check_nestedInitializerRecords(uint256 salt, bytes32 name, uint256 resource) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        bytes[] memory child = new bytes[](1);
        child[0] = abi.encodeCall(
            IPermissionedResolver.linkToRecord,
            (abi.encodePacked(name), resource)
        );
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IMulticallable.multicall, (child));
        _accept(_deploymentEnvelope(proof, _deployment(salt, _grants(), calls)));
    }

    /// @notice Initializer multicalls cannot hide an additional permission grant at either child index.
    function check_initializerPermissionEscalation(
        uint256 salt,
        address grantee,
        bool forbiddenFirst
    )
        public
    {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        bytes[] memory child = new bytes[](2);
        child[forbiddenFirst ? 0 : 1] = abi.encodeCall(
            IPermissionedResolver.grantSetterRoles,
            (bytes(""), grantee)
        );
        child[forbiddenFirst ? 1 : 0] = abi.encodeCall(
            IPermissionedResolver.linkToRecord,
            (bytes(""), uint256(0))
        );
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IMulticallable.multicall, (child));
        _reject(
            _deploymentEnvelope(proof, _deployment(salt, _grants(), calls)),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    /// @notice Trailing bytes in a factory deployment cannot bypass canonical calldata equality.
    function check_deploymentTrailingBytes(uint256 salt, bytes1 suffix) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        _reject(
            _deploymentEnvelope(
                proof,
                bytes.concat(_deployment(salt, _grants(), new bytes[](0)), suffix)
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Trailing bytes inside initialization are rejected even with a canonical outer factory call.
    function check_initializerTrailingBytes(uint256 salt, bytes1 suffix) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _pendingProof(salt);
        bytes memory initData =
            bytes.concat(
                abi.encodeCall(
                    IPermissionedResolverInitializable.initialize,
                    (_grants(), new bytes[](0))
                ),
                suffix
            );
        _reject(
            _deploymentEnvelope(
                proof,
                abi.encodeCall(
                    IVerifiableFactory.deployProxy,
                    (RESOLVER_IMPLEMENTATION, salt, initData)
                )
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @dev Constructs a nonzero, code-free resolver from the independent CREATE2 formula.
    function _pendingProof(uint256 salt)
        private
        view
        returns (HCAOwnerAndSessionValidator.SessionEnableProof memory proof)
    {
        proof = _proof();
        bytes32 callerSalt = keccak256(abi.encode(address(account), salt));
        bytes32 creationHash =
            keccak256(CloneProxyBytecode.creationCode(factory.proxyLogic(), callerSalt));
        proof.resolver = Create2.computeAddress(callerSalt, creationHash, address(factory));
        vm.assume(proof.resolver != address(0));
        vm.assume(proof.resolver.code.length == 0);
    }

    /// @dev Builds the two exact grants required by the source policy.
    function _grants() private view returns (Grant[] memory grants) {
        grants = new Grant[](2);
        grants[0] = Grant(address(account), EACBaseRolesLib.ALL_ROLES);
        grants[1] = Grant(owner, EACBaseRolesLib.ALL_ROLES);
    }

    /// @dev Encodes a factory request with a canonical resolver initializer.
    function _deployment(uint256 salt, Grant[] memory grants, bytes[] memory calls)
        private
        pure
        returns (bytes memory)
    {
        bytes memory initData =
            abi.encodeCall(IPermissionedResolverInitializable.initialize, (grants, calls));
        return
            abi.encodeCall(IVerifiableFactory.deployProxy, (RESOLVER_IMPLEMENTATION, salt, initData));
    }

    /// @dev Constructs a full public-entry-point envelope around one factory request.
    function _deploymentEnvelope(
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof,
        bytes memory deployment
    )
        private
        view
        returns (Envelope memory)
    {
        return _envelope(proof, _one(address(factory), deployment), 0, _noRefund());
    }
}
