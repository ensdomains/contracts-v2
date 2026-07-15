// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable private-vars-leading-underscore, func-name-mixedcase, gas-custom-errors

import {IUUPSProxy} from "@ensdomains/verifiable-factory/IUUPSProxy.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {Test} from "forge-std/Test.sol";

import {
    MockExecutorModule,
    MockStandaloneHCA,
    MockValidatorModule
} from "../../mocks/MockStandaloneHCAStack.sol";

import {
    OwnerBoundRegistrationSessionValidator
} from "~src/hca/OwnerBoundRegistrationSessionValidator.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {ApprovedUpgradeGate} from "~src/registry/ApprovedUpgradeGate.sol";

contract StandaloneSingleOwnerHCATest is Test {
    bytes4 constant ERC1271_MAGICVALUE = 0x1626ba7e;

    bytes4 constant COMMIT_SELECTOR = 0xf14fcbc8;
    bytes4 constant REGISTER_SELECTOR = 0xcff3e7c2;
    bytes4 constant RENEW_SELECTOR = 0x89d779c3;
    bytes4 constant APPROVE_SELECTOR = 0x095ea7b3;
    bytes4 constant DEPLOY_PROXY_SELECTOR = 0x5d84121a;
    bytes4 constant SET_NAME_WITH_HCA_SELECTOR = 0xab863445;
    bytes4 constant SET_ADDR_SELECTOR = 0xd5fa2b00;
    bytes4 constant SET_TEXT_SELECTOR = 0x10f13a8c;
    bytes4 constant SET_NAME_SELECTOR = 0x77372213;
    bytes4 constant MULTICALL_SELECTOR = 0xac9650d8;
    bytes4 constant MULTICALL_WITH_NODE_CHECK_SELECTOR = 0xe32954eb;
    bytes4 constant AUTHORIZE_NAME_ROLES_SELECTOR = 0xbbd9abb5;

    uint256 ownerKey = 0xA11CE;
    uint256 sessionKey = 0x5E5510;
    uint256 badKey = 0xBAD;

    address owner = vm.addr(ownerKey);
    address sessionSigner = vm.addr(sessionKey);
    address defaultReverseRegistrarHCAAdapter = makeAddr("default-reverse-adapter");
    address permittedResolverImpl = makeAddr("resolver-impl");
    address ethRegistrar = makeAddr("eth-registrar");
    address verifiableFactory = makeAddr("verifiable-factory");
    address usdc = makeAddr("usdc");
    address dai = makeAddr("dai");
    address resolver = makeAddr("resolver");
    address otherResolver = makeAddr("other-resolver");
    address subregistry = makeAddr("subregistry");
    address entryPoint = makeAddr("entry-point");
    address intentExecutor = makeAddr("intent-executor");

    address gateOwner = makeAddr("gate-owner");

    OwnerBoundRegistrationSessionValidator validator;
    OwnerBoundRegistrationSessionValidatorHarness validatorHarness;
    MockStandaloneHCA hca;
    ApprovedUpgradeGate upgradeGate;

    function setUp() public {
        upgradeGate = new ApprovedUpgradeGate(gateOwner);
        validator = new OwnerBoundRegistrationSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            usdc,
            dai,
            intentExecutor
        );
        validatorHarness = new OwnerBoundRegistrationSessionValidatorHarness(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            usdc,
            dai,
            intentExecutor
        );
        hca = new MockStandaloneHCA(owner);
    }

    function test_standaloneSingleOwnerHCA_initializesOwner() public {
        StandaloneSingleOwnerHCA account = _newAccount();

        account.initializeAccount(abi.encode(owner));

        assertEq(account.owner(), owner);
        assertEq(account.accountId(), "ens-standalone-hca.1.1.0");
    }

    function test_standaloneSingleOwnerHCA_rejectsInvalidLifecycleActions() public {
        StandaloneSingleOwnerHCA account = _newAccount();

        vm.expectRevert(StandaloneSingleOwnerHCA.OwnerCannotBeZero.selector);
        account.initializeAccount(abi.encode(address(0)));

        account.initializeAccount(abi.encode(owner));

        vm.expectRevert(StandaloneSingleOwnerHCA.StandaloneHCAAlreadyInitialized.selector);
        account.initializeAccount(abi.encode(owner));

        vm.expectRevert(StandaloneSingleOwnerHCA.NoModuleChangeAllowed.selector);
        account.installModule(1, address(validator), "");

        vm.expectRevert(StandaloneSingleOwnerHCA.NoModuleChangeAllowed.selector);
        account.uninstallModule(1, address(validator), "");

        StandaloneSingleOwnerHCAHarness accountHarness = _newAccountHarness();
        accountHarness.initializeAccount(abi.encode(owner));
        address target = address(0xBEEF);

        vm.expectRevert(StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        accountHarness.authorizeUpgradeHarness(target);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                StandaloneSingleOwnerHCA.UpgradeTargetNotApproved.selector,
                target
            )
        );
        accountHarness.authorizeUpgradeHarness(target);

        vm.prank(gateOwner);
        upgradeGate.setImplementationApproval(target, true);

        vm.prank(owner);
        accountHarness.authorizeUpgradeHarness(target);

        assertTrue(accountHarness.canUpgradeFrom(address(0)));
    }

    function test_standaloneSingleOwnerHCA_upgradesThroughVerifiableFactoryProxy() public {
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneSingleOwnerHCA implementation = _newAccount();
        StandaloneSingleOwnerHCA nextImplementation = _newAccount();

        address proxy =
            factory.deployProxy(
                address(implementation),
                1,
                abi.encodeCall(StandaloneSingleOwnerHCA.initializeAccount, (abi.encode(owner)))
            );
        assertEq(StandaloneSingleOwnerHCA(payable(proxy)).owner(), owner);

        vm.prank(gateOwner);
        upgradeGate.setImplementationApproval(address(nextImplementation), true);

        vm.expectRevert(StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(address(nextImplementation), "");

        vm.prank(owner);
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(address(nextImplementation), "");

        (, address currentImplementation) = IUUPSProxy(proxy).getVerifiableProxyData();
        assertEq(currentImplementation, address(nextImplementation));
        assertEq(StandaloneSingleOwnerHCA(payable(proxy)).owner(), owner);
    }

    function test_standaloneSingleOwnerHCA_revokeSessionsBumpsNonce() public {
        StandaloneSingleOwnerHCA account = _newAccount();
        account.initializeAccount(abi.encode(owner));

        (address owner_, uint96 nonce) = account.ownerAndSessionNonce();
        assertEq(owner_, owner);
        assertEq(nonce, 0);

        vm.expectRevert(StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        account.revokeSessions();

        vm.prank(owner);
        account.revokeSessions();

        (, nonce) = account.ownerAndSessionNonce();
        assertEq(nonce, 1);
    }

    function test_standaloneSingleOwnerHCA_executesWalletPaidBatchAtomically() public {
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneSingleOwnerHCA implementation = _newAccount();
        StandaloneSingleOwnerHCA account =
            StandaloneSingleOwnerHCA(
                payable(
                    factory.deployProxy(
                        address(implementation),
                        2,
                        abi.encodeCall(
                            StandaloneSingleOwnerHCA.initializeAccount,
                            (abi.encode(owner))
                        )
                    )
                )
            );
        WalletPaidTarget firstTarget = new WalletPaidTarget();
        WalletPaidTarget secondTarget = new WalletPaidTarget();
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution({target: address(firstTarget), value: 0, callData: abi.encodeCall(
            WalletPaidTarget.setValue,
            (7)
        )});
        executions[1] = Execution({target: address(secondTarget), value: 0, callData: abi.encodeCall(
            WalletPaidTarget.setValue,
            (9)
        )});

        vm.expectRevert(StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        account.executeByOwner(executions);

        vm.prank(owner);
        account.executeByOwner(executions);
        assertEq(firstTarget.value(), 7);
        assertEq(secondTarget.value(), 9);

        executions[0].callData = abi.encodeCall(WalletPaidTarget.setValue, (11));
        executions[1].callData = abi.encodeCall(WalletPaidTarget.fail, ());

        vm.prank(owner);
        vm.expectRevert(WalletPaidTarget.Failed.selector);
        account.executeByOwner(executions);
        assertEq(firstTarget.value(), 7);
    }

    function test_standaloneSingleOwnerHCA_rejectsNftReceivers() public {
        StandaloneSingleOwnerHCA account = _newAccount();

        vm.expectRevert(StandaloneSingleOwnerHCA.NoNFTAllowed.selector);
        IERC721Receiver(address(account)).onERC721Received(address(this), owner, 1, "");

        vm.expectRevert(StandaloneSingleOwnerHCA.NoNFTAllowed.selector);
        IERC1155Receiver(address(account)).onERC1155Received(address(this), owner, 1, 1, "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1;
        amounts[0] = 1;

        vm.expectRevert(StandaloneSingleOwnerHCA.NoNFTAllowed.selector);
        IERC1155Receiver(address(account)).onERC1155BatchReceived(
            address(this),
            owner,
            ids,
            amounts,
            ""
        );

        (bool success, ) = address(account).call(hex"deadbeef");
        success;
    }

    function test_validator_acceptsExistingOwnerSignatureFormats() public view {
        bytes32 digest = keccak256("owner intent");
        assertEq(hca.validate(validator, digest, _sign(ownerKey, digest)), ERC1271_MAGICVALUE);
        assertEq(
            hca.validate(validator, digest, _signRhinestoneMessage(ownerKey, digest)),
            ERC1271_MAGICVALUE
        );
        assertEq(hca.validate(validator, digest, _signV01(ownerKey, digest)), ERC1271_MAGICVALUE);
    }

    function test_validator_rejectsInvalidOwnerAuthorization() public {
        bytes32 digest = keccak256("owner intent");

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.CallerNotIntentExecutor.selector);
        validator.isValidSignatureWithSender(address(this), digest, _sign(ownerKey, digest));

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.OwnerUnavailable.selector);
        validator.isValidSignatureWithSender(intentExecutor, digest, _sign(ownerKey, digest));

        MockStandaloneHCA zeroOwnerHCA = new MockStandaloneHCA(address(0));
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.OwnerUnavailable.selector);
        zeroOwnerHCA.validate(validator, digest, _sign(ownerKey, digest));

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, _sign(badKey, digest));

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, hex"1234");
    }

    function test_validator_usesPreEnabledRhinestoneSession() public {
        bytes32 permissionId = keccak256("registration session");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);
        assertTrue(validator.isPermissionEnabled(address(hca), permissionId));

        bytes memory registrationData = _registrationOperationData(owner, resolver);
        assertEq(
            _verifySession(permissionId, sessionKey, registrationData),
            validator.verifyExecution.selector
        );

        bytes memory laterData =
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(SET_NAME_WITH_HCA_SELECTOR, owner, "later.eth")
            );
        assertEq(
            _verifySession(permissionId, sessionKey, laterData),
            validator.verifyExecution.selector
        );
    }

    function test_validator_sessionExpiryAndNonceRevocation() public {
        bytes32 permissionId = keccak256("registration session");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);

        bytes memory operationData = _commitOperationData();
        hca.setSessionNonce(1);
        assertFalse(validator.isPermissionEnabled(address(hca), permissionId));
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        _verifySession(permissionId, sessionKey, operationData);

        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);
        assertTrue(validator.isPermissionEnabled(address(hca), permissionId));

        vm.warp(validUntil + 1);
        assertFalse(validator.isPermissionEnabled(address(hca), permissionId));
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.SessionExpired.selector);
        _verifySession(permissionId, sessionKey, operationData);
    }

    function test_validator_rejectsInvalidSessionAuthorization() public {
        bytes32 permissionId = keccak256("registration session");
        uint48 validUntil = uint48(block.timestamp + 1 days);

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.OwnerUnavailable.selector);
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);
        vm.prank(address(hca));
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        validator.enableSession(permissionId, address(0), validUntil, resolver);
        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);

        bytes memory operationData = _commitOperationData();
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        _verifySession(permissionId, badKey, operationData);

        OwnerBoundRegistrationSessionValidator.Operation memory operation =
            OwnerBoundRegistrationSessionValidator.Operation({data: operationData});
        bytes memory validData = _sessionUse(permissionId, sessionKey, keccak256(operationData));
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.CallerNotIntentExecutor.selector);
        validator.verifyExecution(address(hca), keccak256(operationData), validData, operation);

        vm.prank(intentExecutor);
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSessionData.selector);
        validator.verifyExecution(address(hca), keccak256(operationData), hex"01", operation);
    }

    function test_validator_allowsResolverRoleGrantsToOwnerOnly() public {
        bytes memory grantToOwner =
            abi.encodeWithSelector(AUTHORIZE_NAME_ROLES_SELECTOR, bytes(""), uint256(1), owner, true);
        bytes memory operationData = _singleOperationData(resolver, 0, grantToOwner);
        validatorHarness.checkRegistrationPolicyHarness(owner, resolver, operationData);

        bytes[] memory calls = new bytes[](1);
        calls[0] = grantToOwner;
        bytes memory multicallData =
            _singleOperationData(resolver, 0, abi.encodeWithSelector(MULTICALL_SELECTOR, calls));
        validatorHarness.checkRegistrationPolicyHarness(owner, resolver, multicallData);

        bytes memory grantToOther =
            abi.encodeWithSelector(
                AUTHORIZE_NAME_ROLES_SELECTOR,
                bytes(""),
                uint256(1),
                sessionSigner,
                true
            );
        _expectValidationRevert(
            _singleOperationData(resolver, 0, grantToOther),
            resolver,
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsPolicyViolations() public {
        bytes memory operationData = _registrationOperationData(owner, otherResolver);
        _expectValidationRevert(
            operationData,
            resolver,
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );

        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](1);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 1, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        operationData = _operationData(executions);
        _expectValidationRevert(
            operationData,
            address(0),
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsRegistrationPolicyArgumentFailures() public {
        _expectValidationRevert(
            _registrationOperationData(vm.addr(badKey), resolver),
            resolver,
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );

        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](2);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            resolver
        )});
        executions[1] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            otherResolver
        )});

        _expectValidationRevert(
            _operationData(executions),
            address(0),
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );

        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            address(0)
        )});
        executions[1] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            resolver
        )});

        _expectValidationRevert(
            _operationData(executions),
            address(0),
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );

        _expectValidationRevert(
            _registrationOperationDataWithDefaultReverseName(owner, resolver, "bob.eth"),
            resolver,
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsTargetPolicyFailures() public {
        _expectValidationRevert(
            _singleOperationData(
                ethRegistrar,
                0,
                abi.encodeWithSelector(SET_ADDR_SELECTOR, bytes32("node"), owner)
            ),
            address(0),
            OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32("commitment"))
            ),
            resolver,
            OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(SET_NAME_WITH_HCA_SELECTOR, owner, "alice.eth")
            ),
            address(0),
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(SET_NAME_WITH_HCA_SELECTOR, vm.addr(badKey), "alice.eth")
            ),
            resolver,
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(usdc, 0, abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))),
            address(0),
            OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                dai,
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, defaultReverseRegistrarHCAAdapter, 1 ether)
            ),
            address(0),
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                verifiableFactory,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))
            ),
            address(0),
            OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                verifiableFactory,
                0,
                abi.encodeWithSelector(DEPLOY_PROXY_SELECTOR, otherResolver, 123, "")
            ),
            address(0),
            OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                makeAddr("unknown-target"),
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))
            ),
            address(0),
            OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(resolver, 0, abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))),
            resolver,
            OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector
        );
    }

    function test_validator_rejectsMalformedPolicyCalldata() public {
        _expectValidationRevert(
            _singleOperationData(ethRegistrar, 0, hex"1234"),
            address(0),
            OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector
        );
        _expectValidationRevert(
            _singleOperationData(usdc, 0, abi.encodePacked(APPROVE_SELECTOR)),
            address(0),
            OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodePacked(SET_NAME_WITH_HCA_SELECTOR, bytes32(uint256(uint160(owner))))
            ),
            resolver,
            OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector
        );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.callArgsHarness(hex"1234");
    }

    function test_validator_rejectsInvalidOperationEncoding() public {
        _expectValidationRevert(
            hex"0200",
            address(0),
            OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector
        );
        _expectValidationRevert(
            abi.encodePacked(bytes32(uint256(0x0205) << 240), abi.encode(new Execution[](0))),
            address(0),
            OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector
        );
    }

    function test_validator_moduleSurface() public view {
        PackedUserOperation memory userOp;

        assertTrue(validator.isModuleType(1));
        assertFalse(validator.isModuleType(2));
        assertTrue(validator.isInitialized(address(hca)));
        assertEq(validator.validateUserOp(userOp, bytes32(0)), 1);
    }

    function test_validator_installHooksAreNoops() public view {
        validator.onInstall("");
        validator.onUninstall("");
    }

    function _newAccount() internal returns (StandaloneSingleOwnerHCA) {
        MockValidatorModule defaultValidator = new MockValidatorModule();
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        return
            new StandaloneSingleOwnerHCA(
                entryPoint,
                address(defaultValidator),
                address(defaultExecutor),
                "",
                upgradeGate
            );
    }

    function _newAccountHarness() internal returns (StandaloneSingleOwnerHCAHarness) {
        MockValidatorModule defaultValidator = new MockValidatorModule();
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        return
            new StandaloneSingleOwnerHCAHarness(
                entryPoint,
                address(defaultValidator),
                address(defaultExecutor),
                "",
                upgradeGate
            );
    }

    function _registrationOperationData(address registrant, address registrationResolver)
        internal
        view
        returns (bytes memory)
    {
        return
            _registrationOperationDataWithDefaultReverseName(
                registrant,
                registrationResolver,
                "alice.eth"
            );
    }

    function _registrationOperationDataWithDefaultReverseName(
        address registrant,
        address registrationResolver,
        string memory defaultReverseName
    )
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory resolverCalls = new bytes[](2);
        resolverCalls[0] = abi.encodeWithSelector(
            SET_TEXT_SELECTOR,
            bytes32("node"),
            "avatar",
            "ipfs://avatar"
        );
        resolverCalls[1] = abi.encodeWithSelector(SET_NAME_SELECTOR, bytes32("node"), "alice.eth");

        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](7);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            registrant,
            registrationResolver
        )});
        executions[1] = OwnerBoundRegistrationSessionValidator.Execution({target: registrationResolver, value: 0, callData: abi.encodeWithSelector(
            SET_ADDR_SELECTOR,
            bytes32("node"),
            registrant
        )});
        executions[2] = OwnerBoundRegistrationSessionValidator.Execution({target: registrationResolver, value: 0, callData: abi.encodeWithSelector(
            MULTICALL_SELECTOR,
            resolverCalls
        )});
        executions[3] = OwnerBoundRegistrationSessionValidator.Execution({target: registrationResolver, value: 0, callData: abi.encodeWithSelector(
            MULTICALL_WITH_NODE_CHECK_SELECTOR,
            bytes32("node"),
            resolverCalls
        )});
        executions[4] = OwnerBoundRegistrationSessionValidator.Execution({target: usdc, value: 0, callData: abi.encodeWithSelector(
            APPROVE_SELECTOR,
            ethRegistrar,
            1 ether
        )});
        executions[5] = OwnerBoundRegistrationSessionValidator.Execution({target: verifiableFactory, value: 0, callData: abi.encodeWithSelector(
            DEPLOY_PROXY_SELECTOR,
            permittedResolverImpl,
            123,
            ""
        )});
        executions[6] = OwnerBoundRegistrationSessionValidator.Execution({target: defaultReverseRegistrarHCAAdapter, value: 0, callData: abi.encodeWithSelector(
            SET_NAME_WITH_HCA_SELECTOR,
            registrant,
            defaultReverseName
        )});

        return _operationData(executions);
    }

    function _registerCallData(address registrant, address registrationResolver)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(
                REGISTER_SELECTOR,
                "alice",
                registrant,
                bytes32("secret"),
                subregistry,
                registrationResolver,
                uint64(365 days),
                usdc,
                bytes32(0)
            );
    }

    function _commitOperationData() internal view returns (bytes memory) {
        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](1);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        return _operationData(executions);
    }

    function _commitAndRenewOperationData() internal view returns (bytes memory) {
        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](2);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        executions[1] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            RENEW_SELECTOR,
            "alice",
            uint64(365 days),
            usdc,
            bytes32(0)
        )});
        return _operationData(executions);
    }

    function _singleOperationData(address target, uint256 value, bytes memory callData)
        internal
        view
        returns (bytes memory)
    {
        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](1);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: target, value: value, callData: callData});
        return _operationData(executions);
    }

    function _operationData(OwnerBoundRegistrationSessionValidator.Execution[] memory executions)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodePacked(validator.ERC7579_EMISSARY_EXECUTION_MODE(), abi.encode(executions));
    }

    function _expectValidationRevert(
        bytes memory operationData,
        address allowedResolver,
        bytes4 selector
    )
        internal
    {
        if (selector == OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector) {
            vm.expectPartialRevert(selector);
        } else {
            vm.expectRevert(selector);
        }
        validatorHarness.checkRegistrationPolicyHarness(owner, allowedResolver, operationData);
    }

    function _verifySession(bytes32 permissionId, uint256 signerKey, bytes memory operationData)
        internal
        returns (bytes4)
    {
        bytes32 digest = keccak256(operationData);
        OwnerBoundRegistrationSessionValidator.Operation memory operation =
            OwnerBoundRegistrationSessionValidator.Operation({data: operationData});
        vm.prank(intentExecutor);
        return
            validator.verifyExecution(
                address(hca),
                digest,
                _sessionUse(permissionId, signerKey, digest),
                operation
            );
    }

    function _sessionUse(bytes32 permissionId, uint256 signerKey, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes1(0), permissionId, _signRhinestoneMessage(signerKey, digest));
    }

    function _signRhinestoneMessage(uint256 privateKey, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v + 4);
    }

    function _toEthSignedMessageHash(bytes32 digest) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signV01(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v - 27);
    }
}


contract OwnerBoundRegistrationSessionValidatorHarness is OwnerBoundRegistrationSessionValidator {
    constructor(
        address defaultReverseRegistrarHCAAdapter,
        address permittedResolverImpl,
        address ethRegistrar,
        address verifiableFactory,
        address paymentToken,
        address secondaryPaymentToken,
        address intentExecutor
    )
        OwnerBoundRegistrationSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            paymentToken,
            secondaryPaymentToken,
            intentExecutor
        )
    {}

    function callArgsHarness(bytes memory callData) external pure returns (bytes memory) {
        return _callArgs(callData);
    }

    function checkRegistrationPolicyHarness(
        address owner,
        address resolver,
        bytes calldata operationData
    )
        external
        view
    {
        _checkRegistrationPolicy(owner, resolver, operationData);
    }
}


contract StandaloneSingleOwnerHCAHarness is StandaloneSingleOwnerHCA {
    constructor(
        address entryPoint,
        address defaultValidator,
        address defaultExecutor,
        bytes memory validatorInitData,
        ApprovedUpgradeGate upgradeGate
    )
        StandaloneSingleOwnerHCA(
            entryPoint,
            defaultValidator,
            defaultExecutor,
            validatorInitData,
            upgradeGate
        )
    {}

    function authorizeUpgradeHarness(address newImplementation) external view {
        _authorizeUpgrade(newImplementation);
    }
}


interface IUUPSProxyUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}


interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}


interface IERC1155Receiver {
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        external
        returns (bytes4);

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )
        external
        returns (bytes4);
}


contract WalletPaidTarget {
    error Failed();

    uint256 public value;

    function setValue(uint256 value_) external {
        value = value_;
    }

    function fail() external pure {
        revert Failed();
    }
}
