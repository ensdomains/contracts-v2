// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {IETHRenewer, RenewData} from "~src/registrar/interfaces/IETHRenewer.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {
    IDefaultReverseRegistrarAdapter
} from "~src/reverse-registrar/interfaces/IDefaultReverseRegistrarAdapter.sol";
import {
    IReverseRegistrarAdapter
} from "~src/reverse-registrar/interfaces/IReverseRegistrarAdapter.sol";
import {IPermissionedResolver} from "~src/resolver/interfaces/IPermissionedResolver.sol";
import {IABISetter} from "~src/resolver/interfaces/setters/IABISetter.sol";
import {IAddressSetter} from "~src/resolver/interfaces/setters/IAddressSetter.sol";
import {IContenthashSetter} from "~src/resolver/interfaces/setters/IContenthashSetter.sol";
import {IDataSetter} from "~src/resolver/interfaces/setters/IDataSetter.sol";
import {IInterfaceSetter} from "~src/resolver/interfaces/setters/IInterfaceSetter.sol";
import {INameSetter} from "~src/resolver/interfaces/setters/INameSetter.sol";
import {ITextSetter} from "~src/resolver/interfaces/setters/ITextSetter.sol";

import {OwnerSessionFixture} from "./owner/OwnerSessionFixture.sol";

/// @title HCA Owner Session Registration Policy Proofs
/// @notice Checks admission and rejection of symbolic registration, resolver, reverse, and payment actions.
/// @dev Every policy assertion passes through a complete signed envelope and the unmodified validator.
///      Target execution is outside scope: the suite proves policy admission, not registration success.
///      Operations have at most three executions; nested resolver multicalls have at most two children
///      and two nesting levels. Names and record payloads use fixed-length symbolic words.
///      Registry, oracle, and factory responses use the independent interface models in the fixture.
contract HCAOwnerSessionPolicy is OwnerSessionFixture {
    /// @notice Registrar authorization does not extend the fixed session policy to renewal actions.
    function check_renewIsOutsideSessionPolicy(bytes32 label, uint64 duration) public {
        RenewData memory renewal = RenewData(string(abi.encodePacked(label)), duration, bytes32(0));
        _reject(
            _envelope(
                _proof(),
                _one(
                    address(registrar),
                    abi.encodeCall(IETHRenewer.renew, (renewal, IERC20(PAYMENT_TOKEN)))
                ),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    /// @notice A commit is permitted exactly when its target has the modeled registrar role.
    function check_commitRegistrarAuthorization(bool authorized, bytes32 commitment) public {
        registry.setAuthorized(address(registrar), authorized);
        Envelope memory envelope = _envelope(_proof(), _commit(commitment), 0, _noRefund());
        if (authorized)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.ActionNotAllowed.selector);
    }

    /// @notice Every registrar action in a batch must use the first selected registrar, including aliases.
    function check_batchUsesOneRegistrar(address secondTarget, bytes32 first, bytes32 second)
        public
    {
        registry.setAuthorized(secondTarget, true);
        Execution[] memory executions = new Execution[](2);
        executions[0] = _commit(first)[0];
        executions[1] = Execution(secondTarget, 0, abi.encodeCall(IETHRegistrar.commit, (second)));
        Envelope memory envelope = _envelope(_proof(), executions, 0, _noRefund());
        if (secondTarget == address(registrar))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.ActionNotAllowed.selector);
    }

    /// @notice Zero cannot become the selected registrar even if a role response is configured for it.
    function check_zeroRegistrarRejected(bytes32 commitment) public {
        registry.setAuthorized(address(0), true);
        _reject(
            _envelope(
                _proof(),
                _one(address(0), abi.encodeCall(IETHRegistrar.commit, (commitment))),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    /// @notice Registration admission requires the owner, no subregistry, and the exact session resolver.
    function check_registrationOwnershipFields(
        address registrant,
        address subregistry,
        address registrationResolver,
        bytes32 label
    )
        public
    {
        bytes memory data = _registration(registrant, subregistry, registrationResolver, label);
        Envelope memory envelope =
            _envelope(_proof(), _one(address(registrar), data), 0, _noRefund());
        if (
            registrant == owner &&
            subregistry == address(0) &&
            registrationResolver == address(resolver)
        ) {
            _accept(envelope);
        } else {
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        }
    }

    /// @notice Unauthorized registrars cannot register even with otherwise correct policy arguments.
    function check_registerRequiresRegistrarRole(bytes32 label) public {
        registry.setAuthorized(address(registrar), false);
        _reject(
            _envelope(
                _proof(),
                _one(address(registrar), _registration(owner, address(0), address(resolver), label)),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    /// @notice Commit-only sessions do not require a deployed or nonzero resolver.
    function check_commitWithoutResolver(bytes32 commitment) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.resolver = address(0);
        _accept(_envelope(proof, _commit(commitment), 0, _noRefund()));
    }

    /// @notice Registration cannot use an absent resolver without a preceding exact deployment.
    function check_registerNeedsResolverDeployment(bytes32 label) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.resolver = PAYMENT_TOKEN;
        _reject(
            _envelope(
                proof,
                _one(address(registrar), _registration(owner, address(0), PAYMENT_TOKEN, label)),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice A deployed resolver must verify to the exact permitted implementation.
    function check_resolverImplementationBinding(address verifiedImplementation, bytes32 label)
        public
    {
        factory.configure(address(resolver), verifiedImplementation, false);
        Envelope memory envelope =
            _envelope(
                _proof(),
                _one(address(registrar), _registration(owner, address(0), address(resolver), label)),
                0,
                _noRefund()
            );
        if (verifiedImplementation == RESOLVER_IMPLEMENTATION)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Factory verification failures cannot admit a used resolver.
    function check_resolverVerificationFailsClosed(bytes32 label) public {
        factory.configure(address(resolver), RESOLVER_IMPLEMENTATION, true);
        _reject(
            _envelope(
                _proof(),
                _one(address(registrar), _registration(owner, address(0), address(resolver), label)),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Plain token transfers are forbidden for every possible target, including reserved aliases.
    function check_unrestrictedTransferForbidden(address target, address recipient, uint256 amount)
        public
    {
        _reject(
            _envelope(
                _proof(),
                _one(target, abi.encodeCall(IERC20.transfer, (recipient, amount))),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    /// @notice Resolver admission is confined to the production record-selector set.
    /// @dev The fixed-word arguments are deliberately opaque: resolver argument validity is not claimed.
    function check_resolverSelectorAllowlist(bytes4 selector, bytes32 opaqueArgument) public {
        vm.assume(selector != IMulticallable.multicall.selector);
        Envelope memory envelope =
            _envelope(
                _proof(),
                _one(address(resolver), abi.encodePacked(selector, opaqueArgument)),
                0,
                _noRefund()
            );
        if (_recordSelector(selector))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.ActionNotAllowed.selector);
    }

    /// @notice A supported record write can occur in a nested multicall without relaxing its selector policy.
    function check_nestedResolverRecordCall(bytes32 name, uint256 coinType, address addressValue)
        public
    {
        bytes[] memory child = new bytes[](1);
        child[0] = abi.encodeCall(
            IAddressSetter.setAddress,
            (abi.encodePacked(name), coinType, abi.encodePacked(addressValue))
        );
        bytes[] memory parent = new bytes[](1);
        parent[0] = abi.encodeCall(IMulticallable.multicall, (child));
        _accept(
            _envelope(
                _proof(),
                _one(address(resolver), abi.encodeCall(IMulticallable.multicall, (parent))),
                0,
                _noRefund()
            )
        );
    }

    /// @notice Nesting cannot hide a forbidden resolver permission grant among accepted record writes.
    function check_nestedResolverPermissionEscalation(address grantee, bool forbiddenFirst) public {
        bytes[] memory child = new bytes[](2);
        bytes memory permitted =
            abi.encodeCall(IPermissionedResolver.linkToRecord, (bytes(""), uint256(0)));
        bytes memory forbidden =
            abi.encodeCall(IPermissionedResolver.grantSetterRoles, (bytes(""), grantee));
        child[0] = forbiddenFirst ? forbidden : permitted;
        child[1] = forbiddenFirst ? permitted : forbidden;
        bytes[] memory parent = new bytes[](1);
        parent[0] = abi.encodeCall(IMulticallable.multicall, (child));
        _reject(
            _envelope(
                _proof(),
                _one(address(resolver), abi.encodeCall(IMulticallable.multicall, (parent))),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    /// @notice Default-primary-name sessions may name only the account owner.
    function check_defaultReverseOwnerBinding(address namedAccount, bytes32 name) public {
        Envelope memory envelope =
            _envelope(
                _proof(),
                _one(
                    DEFAULT_REVERSE_ADAPTER,
                    abi.encodeCall(
                        IDefaultReverseRegistrarAdapter.setNameWithHCA,
                        (namedAccount, string(abi.encodePacked(name)))
                    )
                ),
                0,
                _noRefund()
            );
        if (namedAccount == owner)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Default-primary-name setup requires a nonzero resolver in the owner's authorization.
    function check_defaultReverseRequiresResolver(bytes32 name) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.resolver = address(0);
        _reject(
            _envelope(
                proof,
                _one(
                    DEFAULT_REVERSE_ADAPTER,
                    abi.encodeCall(
                        IDefaultReverseRegistrarAdapter.setNameWithHCA,
                        (owner, string(abi.encodePacked(name)))
                    )
                ),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Reverse claims are confined to the owner and either no resolver or the signed resolver.
    function check_reverseClaimOwnerAndResolver(address claimedAccount, address claimedResolver)
        public
    {
        Envelope memory envelope =
            _envelope(
                _proof(),
                _one(
                    REVERSE_ADAPTER,
                    abi.encodeCall(
                        IReverseRegistrarAdapter.claimWithHCA,
                        (claimedAccount, claimedResolver)
                    )
                ),
                0,
                _noRefund()
            );
        if (
            claimedAccount == owner &&
            (claimedResolver == address(0) || claimedResolver == address(resolver))
        )
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A resolver-free reverse claim is permitted without requiring a resolver deployment.
    function check_reverseClaimWithoutResolver() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.resolver = address(0);
        _accept(
            _envelope(
                proof,
                _one(
                    REVERSE_ADAPTER,
                    abi.encodeCall(IReverseRegistrarAdapter.claimWithHCA, (owner, address(0)))
                ),
                0,
                _noRefund()
            )
        );
    }

    /// @notice Registrar payment approvals depend on oracle token support and retain reserved-target handling.
    function check_registrarApprovalTokenSupport(address token, bool supported, uint256 amount)
        public
    {
        oracle.configure(token, supported, false);
        Envelope memory envelope =
            _envelope(
                _proof(),
                _one(token, abi.encodeCall(IERC20.approve, (address(registrar), amount))),
                0,
                _noRefund()
            );
        if (
            token == address(resolver) ||
            token == DEFAULT_REVERSE_ADAPTER ||
            token == REVERSE_ADAPTER ||
            token == address(factory)
        ) {
            _reject(envelope, HCAOwnerAndSessionValidator.ActionNotAllowed.selector);
        } else if (supported) {
            _accept(envelope);
        } else {
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        }
    }

    /// @notice A payment approval cannot switch a batch to another authorized registrar.
    function check_approvalCannotSwitchRegistrar(uint256 amount) public {
        Execution[] memory executions = new Execution[](2);
        executions[0] = _commit(0)[0];
        executions[1] = Execution(
            PAYMENT_TOKEN,
            0,
            abi.encodeCall(IERC20.approve, (address(secondRegistrar), amount))
        );
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice An unavailable rent oracle cannot authorize a token approval.
    function check_oracleRevertFailsClosed(uint256 amount) public {
        oracle.configure(PAYMENT_TOKEN, true, true);
        _reject(
            _envelope(
                _proof(),
                _one(PAYMENT_TOKEN, abi.encodeCall(IERC20.approve, (address(registrar), amount))),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Oracle discovery failure cannot authorize a token approval.
    function check_registrarOracleDiscoveryFailsClosed(uint256 amount) public {
        registrar.configure(address(oracle), true);
        _reject(
            _envelope(
                _proof(),
                _one(PAYMENT_TOKEN, abi.encodeCall(IERC20.approve, (address(registrar), amount))),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice A code-free oracle address cannot authorize a token approval.
    function check_missingOracleCodeFailsClosed(uint256 amount) public {
        registrar.configure(PAYMENT_TOKEN, false);
        _reject(
            _envelope(
                _proof(),
                _one(PAYMENT_TOKEN, abi.encodeCall(IERC20.approve, (address(registrar), amount))),
                0,
                _noRefund()
            ),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Executor reimbursement approval must exactly match the signed refund amount.
    function check_refundApprovalAmount(uint96 refundAmount, uint256 approvedAmount) public {
        vm.assume(refundAmount != 0);
        HCAOwnerAndSessionValidator.GasRefund memory refund =
            HCAOwnerAndSessionValidator.GasRefund(PAYMENT_TOKEN, 1, uint256(refundAmount) << 128);
        Envelope memory envelope =
            _envelope(
                _proof(),
                _one(PAYMENT_TOKEN, abi.encodeCall(IERC20.approve, (PAYMASTER, approvedAmount))),
                0,
                refund
            );
        if (approvedAmount == refundAmount)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice An adjacent, equal-amount owner permit and pull is admitted before a real session action.
    function check_fundingPairAccepted(
        uint256 amount,
        uint256 deadline,
        bytes32 r,
        bytes32 s,
        uint8 v
    )
        public
    {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        executions[0].callData = abi.encodeCall(
            IERC20Permit.permit,
            (owner, address(account), amount, deadline, v, r, s)
        );
        _accept(_envelope(_proof(), executions, 0, _noRefund()));
    }

    /// @notice Funding transfers may only pull from the owner into this account.
    function check_fundingTransferEndpoints(address from, address to, uint256 amount) public {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        executions[1].callData = abi.encodeCall(IERC20.transferFrom, (from, to, amount));
        Envelope memory envelope = _envelope(_proof(), executions, 0, _noRefund());
        if (from == owner && to == address(account))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Permit authority is confined to the owner and this account as spender.
    function check_fundingPermitEndpoints(address permitOwner, address spender, uint256 amount)
        public
    {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        executions[0].callData = abi.encodeCall(
            IERC20Permit.permit,
            (permitOwner, spender, amount, uint256(0), uint8(0), bytes32(0), bytes32(0))
        );
        Envelope memory envelope = _envelope(_proof(), executions, 0, _noRefund());
        if (permitOwner == owner && spender == address(account))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice The funding pull must consume exactly the newly permitted nonzero amount.
    function check_fundingAmountBinding(uint256 permittedAmount, uint256 transferredAmount) public {
        Execution[] memory executions = _fundingPair(permittedAmount);
        executions[1].callData = abi.encodeCall(
            IERC20.transferFrom,
            (owner, address(account), transferredAmount)
        );
        Envelope memory envelope = _envelope(_proof(), executions, 0, _noRefund());
        if (permittedAmount != 0 && transferredAmount == permittedAmount)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A permit and transfer cannot authorize a session with no actual policy action.
    function check_fundingPairNeedsAction(uint256 amount) public {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        assembly ("memory-safe") { mstore(executions, 2) }
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Funding transfers must immediately follow the matching permit in this validator's policy.
    function check_fundingAdjacency(uint256 amount) public {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        Execution memory transfer = executions[1];
        executions[1] = executions[2];
        executions[2] = transfer;
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice A funding permit cannot remain unconsumed after an otherwise authorized action.
    function check_unpairedFundingPermit(uint256 amount) public {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        executions[1] = executions[2];
        assembly ("memory-safe") { mstore(executions, 2) }
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice An owner-funded pull cannot precede its matching permit.
    function check_fundingTransferBeforePermit(uint256 amount) public {
        Execution[] memory executions = _fundingPair(amount);
        Execution memory permit = executions[0];
        executions[0] = executions[1];
        executions[1] = permit;
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice A second permit cannot overwrite the first funding allowance within a batch.
    function check_duplicateFundingPermit(uint256 amount) public {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        executions[1] = executions[0];
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Extra trailing bytes cannot be smuggled into a funding permit's canonical calldata.
    function check_fundingPermitLength(uint256 amount, bytes1 trailing) public {
        vm.assume(amount != 0);
        Execution[] memory executions = _fundingPair(amount);
        executions[0].callData = bytes.concat(executions[0].callData, trailing);
        _reject(
            _envelope(_proof(), executions, 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @dev Builds an ABI-canonical registration with fixed-length symbolic label bytes.
    function _registration(
        address registrant,
        address subregistry,
        address registrationResolver,
        bytes32 label
    )
        private
        pure
        returns (bytes memory)
    {
        return
            abi.encodeCall(
                IETHRegistrar.register,
                (
                    string(abi.encodePacked(label)),
                    registrant,
                    bytes32(0),
                    IRegistry(subregistry),
                    registrationResolver,
                    uint64(0),
                    IERC20(PAYMENT_TOKEN),
                    bytes32(0)
                )
            );
    }

    /// @dev Lists admitted record selectors independently from the library's control flow.
    function _recordSelector(bytes4 selector) private pure returns (bool) {
        return
            selector == IPermissionedResolver.linkToRecord.selector ||
            selector == IPermissionedResolver.linkToNode.selector ||
            selector == IABISetter.setABI.selector ||
            selector == IAddressSetter.setAddress.selector ||
            selector == IContenthashSetter.setContenthash.selector ||
            selector == IDataSetter.setData.selector ||
            selector == IInterfaceSetter.setInterface.selector ||
            selector == INameSetter.setName.selector ||
            selector == ITextSetter.setText.selector;
    }

    /// @dev Builds a permit, its matching pull, and an authorized commit action.
    function _fundingPair(uint256 amount) private view returns (Execution[] memory executions) {
        executions = new Execution[](3);
        executions[0] = Execution(
            PAYMENT_TOKEN,
            0,
            abi.encodeCall(
                IERC20Permit.permit,
                (owner, address(account), amount, uint256(0), uint8(0), bytes32(0), bytes32(0))
            )
        );
        executions[1] = Execution(
            PAYMENT_TOKEN,
            0,
            abi.encodeCall(IERC20.transferFrom, (owner, address(account), amount))
        );
        executions[2] = _commit(0)[0];
    }
}
