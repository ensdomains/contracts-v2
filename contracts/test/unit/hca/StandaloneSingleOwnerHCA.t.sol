// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable private-vars-leading-underscore, func-name-mixedcase, gas-custom-errors

import {IUUPSProxy} from "@ensdomains/verifiable-factory/IUUPSProxy.sol";
import {CloneProxyBytecode} from "@ensdomains/verifiable-factory/CloneProxyBytecode.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {TestPaymasterAcceptAll} from "account-abstraction/test/TestPaymasterAcceptAll.sol";
import {Nexus} from "nexus/Nexus.sol";
import {ExecLib} from "nexus/lib/ExecLib.sol";
import {ModeLib} from "nexus/lib/ModeLib.sol";
import {Execution} from "nexus/types/DataTypes.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Test} from "forge-std/Test.sol";

import {
    MockExecutorModule,
    MockStandaloneHCA,
    MockValidatorModule
} from "../../mocks/MockStandaloneHCAStack.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {StandaloneHCAFactory} from "~src/hca/StandaloneHCAFactory.sol";
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
    address gasRefundPaymaster = makeAddr("gas-refund-paymaster");

    address gateOwner = makeAddr("gate-owner");

    HCAOwnerAndSessionValidator validator;
    HCAOwnerAndSessionValidatorHarness validatorHarness;
    MockStandaloneHCA hca;
    ApprovedUpgradeGate upgradeGate;

    function setUp() public {
        upgradeGate = new ApprovedUpgradeGate(gateOwner);
        validator = new HCAOwnerAndSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            usdc,
            dai,
            intentExecutor,
            gasRefundPaymaster
        );
        validatorHarness = new HCAOwnerAndSessionValidatorHarness(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            usdc,
            dai,
            intentExecutor,
            gasRefundPaymaster
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

        vm.expectRevert(
            abi.encodeWithSelector(
                StandaloneSingleOwnerHCA.UpgradeTargetNotApproved.selector,
                target
            )
        );
        vm.prank(owner);
        accountHarness.authorizeUpgradeHarness(target);

        vm.prank(gateOwner);
        upgradeGate.setImplementationApproval(target, true);

        vm.prank(owner);
        accountHarness.authorizeUpgradeHarness(target);

        assertFalse(accountHarness.canUpgradeFrom(target));
    }

    function test_standaloneSingleOwnerHCA_upgradesThroughVerifiableFactoryProxy() public {
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneSingleOwnerHCA implementation = _newAccount();
        ApprovedUpgradeGate predecessorUpgradeGate = new ApprovedUpgradeGate(gateOwner);
        StandaloneSingleOwnerHCA nextImplementation = _newAccount(predecessorUpgradeGate);

        address proxy =
            factory.deployProxy(
                address(implementation),
                1,
                abi.encodeCall(StandaloneSingleOwnerHCA.initializeAccount, (abi.encode(owner)))
            );
        assertEq(StandaloneSingleOwnerHCA(payable(proxy)).owner(), owner);

        vm.prank(gateOwner);
        upgradeGate.setImplementationApproval(address(nextImplementation), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUUPSProxy.InvalidUpgradeTarget.selector,
                address(implementation),
                address(nextImplementation)
            )
        );
        vm.prank(owner);
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(address(nextImplementation), "");

        vm.prank(gateOwner);
        predecessorUpgradeGate.setImplementationApproval(address(implementation), true);

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

        vm.expectRevert(HCAOwnerAndSessionValidator.CallerNotIntentExecutor.selector);
        validator.isValidSignatureWithSender(address(this), digest, _sign(ownerKey, digest));

        vm.expectRevert(HCAOwnerAndSessionValidator.OwnerUnavailable.selector);
        validator.isValidSignatureWithSender(intentExecutor, digest, _sign(ownerKey, digest));

        MockStandaloneHCA zeroOwnerHCA = new MockStandaloneHCA(address(0));
        vm.expectRevert(HCAOwnerAndSessionValidator.OwnerUnavailable.selector);
        zeroOwnerHCA.validate(validator, digest, _sign(ownerKey, digest));

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, _sign(badKey, digest));

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, abi.encodePacked(bytes32(0), bytes32(0), uint8(29)));

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        validatorHarness.recoverHarness(digest, hex"1234");

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
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

    function test_validator_usesPreEnabledSessionThroughERC1271() public {
        bytes32 permissionId = keccak256("registration session");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        bytes memory operationData = _erc1271OperationData(executions);
        uint256 nonce = 123;
        bytes32 digest =
            validatorHarness.singleChainDigestHarness(address(hca), nonce, operationData);

        assertEq(
            hca.validate(
                validator,
                digest,
                _fixedSessionEnvelope(permissionId, nonce, operationData, sessionKey, digest)
            ),
            ERC1271_MAGICVALUE
        );

        executions[0].callData = abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("different commitment")
        );
        bytes memory differentOperation = _erc1271OperationData(executions);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionEnvelope(permissionId, nonce, differentOperation, sessionKey, digest)
        );
    }

    function test_validator_usesRefundAwareSessionThroughERC1271() public {
        bytes32 permissionId = keccak256("refund registration session");
        uint96 maxExchangeRate = 10_000_000_000;
        uint48 maxGasOverhead = 100_000;
        uint96 maxRefundAmount = 25_000_000;
        vm.prank(address(hca));
        validator.enableSessionWithRefund(
            permissionId,
            sessionSigner,
            uint48(block.timestamp + 1 days),
            resolver,
            usdc,
            maxExchangeRate,
            maxGasOverhead,
            maxRefundAmount
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: usdc, value: 0, callData: abi.encodeWithSelector(
            APPROVE_SELECTOR,
            gasRefundPaymaster,
            maxRefundAmount
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        bytes memory operationData = _erc1271OperationData(executions);
        uint256 packedOverhead = (uint256(maxRefundAmount) << 128) | maxGasOverhead;
        HCAOwnerAndSessionValidator.GasRefund memory gasRefund =
            HCAOwnerAndSessionValidator.GasRefund({token: usdc, exchangeRate: maxExchangeRate, overhead: packedOverhead});
        uint256 nonce = 321;
        bytes32 digest =
            validatorHarness.singleChainDigestWithRefundHarness(
                address(hca),
                nonce,
                operationData,
                gasRefund
            );

        assertEq(
            hca.validate(
                validator,
                digest,
                _fixedSessionRefundEnvelope(
                    permissionId,
                    nonce,
                    gasRefund,
                    operationData,
                    sessionKey,
                    digest
                )
            ),
            ERC1271_MAGICVALUE
        );

        executions[0].callData = abi.encodeWithSelector(
            APPROVE_SELECTOR,
            gasRefundPaymaster,
            maxRefundAmount - 1
        );
        operationData = _erc1271OperationData(executions);
        digest = validatorHarness.singleChainDigestWithRefundHarness(
            address(hca),
            nonce,
            operationData,
            gasRefund
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );

        executions[0].callData = abi.encodeWithSelector(
            APPROVE_SELECTOR,
            gasRefundPaymaster,
            maxRefundAmount
        );
        operationData = _erc1271OperationData(executions);

        gasRefund.exchangeRate = maxExchangeRate + 1;
        digest = validatorHarness.singleChainDigestWithRefundHarness(
            address(hca),
            nonce,
            operationData,
            gasRefund
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );

        gasRefund.exchangeRate = maxExchangeRate;
        gasRefund.overhead = (uint256(maxRefundAmount + 1) << 128) | maxGasOverhead;
        digest = validatorHarness.singleChainDigestWithRefundHarness(
            address(hca),
            nonce,
            operationData,
            gasRefund
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );

        gasRefund.overhead = (uint256(maxRefundAmount) << 128) | uint256(maxGasOverhead + 1);
        digest = validatorHarness.singleChainDigestWithRefundHarness(
            address(hca),
            nonce,
            operationData,
            gasRefund
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );

        gasRefund = HCAOwnerAndSessionValidator.GasRefund({token: dai, exchangeRate: maxExchangeRate, overhead: packedOverhead});
        digest = validatorHarness.singleChainDigestWithRefundHarness(
            address(hca),
            nonce,
            operationData,
            gasRefund
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );
    }

    function test_validator_noRefundSessionRejectsExecutorRefund() public {
        bytes32 permissionId = keccak256("no-refund registration session");
        vm.prank(address(hca));
        validator.enableSession(
            permissionId,
            sessionSigner,
            uint48(block.timestamp + 1 days),
            resolver
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        bytes memory operationData = _erc1271OperationData(executions);
        HCAOwnerAndSessionValidator.GasRefund memory gasRefund =
            HCAOwnerAndSessionValidator.GasRefund({token: usdc, exchangeRate: 1, overhead: 0});
        uint256 nonce = 654;
        bytes32 digest =
            validatorHarness.singleChainDigestWithRefundHarness(
                address(hca),
                nonce,
                operationData,
                gasRefund
            );

        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );

        gasRefund = HCAOwnerAndSessionValidator.GasRefund({token: address(0), exchangeRate: 1, overhead: 0});
        digest = validatorHarness.singleChainDigestWithRefundHarness(
            address(hca),
            nonce,
            operationData,
            gasRefund
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionRefundEnvelope(
                permissionId,
                nonce,
                gasRefund,
                operationData,
                sessionKey,
                digest
            )
        );
    }

    function test_validator_matchesRhinestoneSingleChainDigest() public {
        HCAOwnerAndSessionValidatorHarness vectorValidator =
            new HCAOwnerAndSessionValidatorHarness(
                defaultReverseRegistrarHCAAdapter,
                permittedResolverImpl,
                ethRegistrar,
                verifiableFactory,
                usdc,
                dai,
                address(0x5678),
                gasRefundPaymaster
            );
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: address(0x9aBc), value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111))
        )});
        bytes memory operationData =
            abi.encodePacked(vectorValidator.ERC7579_ERC1271_MODE(), abi.encode(executions));

        assertEq(
            vectorValidator.singleChainDigestHarness(address(0x1234), 123, operationData),
            0xf6f3d7bdea733a1628607600e6a4e40c52ba9edce5de6f9303852f4ed613e012
        );
    }

    function test_validator_appliesFixedPolicyThroughERC1271() public {
        bytes32 permissionId = keccak256("registration session");
        vm.prank(address(hca));
        validator.enableSession(
            permissionId,
            sessionSigner,
            uint48(block.timestamp + 1 days),
            resolver
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: makeAddr("forbidden"), value: 0, callData: hex"12345678"});
        bytes memory operationData = _erc1271OperationData(executions);
        uint256 nonce = 456;
        bytes32 digest =
            validatorHarness.singleChainDigestHarness(address(hca), nonce, operationData);

        vm.expectPartialRevert(HCAOwnerAndSessionValidator.ActionNotAllowed.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionEnvelope(permissionId, nonce, operationData, sessionKey, digest)
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
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        _verifySession(permissionId, sessionKey, operationData);

        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);
        assertTrue(validator.isPermissionEnabled(address(hca), permissionId));

        vm.warp(validUntil + 1);
        assertFalse(validator.isPermissionEnabled(address(hca), permissionId));
        vm.expectRevert(HCAOwnerAndSessionValidator.SessionExpired.selector);
        _verifySession(permissionId, sessionKey, operationData);
    }

    function test_validator_rejectsInvalidFixedSessionAuthorization() public {
        bytes32 permissionId = keccak256("registration session");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);

        bytes memory operationData = _erc1271CommitOperationData();
        uint256 nonce = 123;
        bytes32 digest =
            validatorHarness.singleChainDigestHarness(address(hca), nonce, operationData);

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionEnvelope(permissionId, nonce, operationData, badKey, digest)
        );

        hca.setSessionNonce(1);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionEnvelope(permissionId, nonce, operationData, sessionKey, digest)
        );

        hca.setSessionNonce(0);
        vm.warp(validUntil + 1);
        vm.expectRevert(HCAOwnerAndSessionValidator.SessionExpired.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionEnvelope(permissionId, nonce, operationData, sessionKey, digest)
        );
    }

    function test_validator_rejectsMalformedFixedSessionEnvelope() public {
        bytes memory shortRefundEnvelope = new bytes(130);
        shortRefundEnvelope[0] = 0x02;
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        hca.validate(validator, bytes32(0), shortRefundEnvelope);

        bytes memory unknownModeEnvelope = new bytes(130);
        unknownModeEnvelope[0] = 0x03;
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        hca.validate(validator, bytes32(0), unknownModeEnvelope);

        bytes memory operationData = _erc1271CommitOperationData();
        uint256 nonce = 123;
        bytes32 digest =
            validatorHarness.singleChainDigestHarness(address(hca), nonce, operationData);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            digest,
            _fixedSessionEnvelope(
                keccak256("missing session"),
                nonce,
                operationData,
                sessionKey,
                digest
            )
        );
    }

    function test_validator_rejectsInvalidSessionAuthorization() public {
        bytes32 permissionId = keccak256("registration session");
        uint48 validUntil = uint48(block.timestamp + 1 days);

        vm.expectRevert(HCAOwnerAndSessionValidator.OwnerUnavailable.selector);
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);
        vm.prank(address(hca));
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        validator.enableSession(permissionId, address(0), validUntil, resolver);

        vm.warp(block.timestamp + 1);
        vm.prank(address(hca));
        vm.expectRevert(HCAOwnerAndSessionValidator.SessionExpired.selector);
        validator.enableSession(permissionId, sessionSigner, uint48(block.timestamp - 1), resolver);

        vm.prank(address(hca));
        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        validator.enableSessionWithRefund(
            permissionId,
            sessionSigner,
            validUntil,
            resolver,
            makeAddr("unsupported-refund-token"),
            1,
            0,
            1
        );

        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, validUntil, resolver);

        bytes memory operationData = _commitOperationData();
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        _verifySession(permissionId, badKey, operationData);

        HCAOwnerAndSessionValidator.Operation memory operation =
            HCAOwnerAndSessionValidator.Operation({data: operationData});
        bytes memory validData = _sessionUse(permissionId, sessionKey, keccak256(operationData));
        vm.expectRevert(HCAOwnerAndSessionValidator.CallerNotIntentExecutor.selector);
        validator.verifyExecution(address(hca), keccak256(operationData), validData, operation);

        vm.prank(intentExecutor);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        validator.verifyExecution(address(hca), keccak256(operationData), hex"01", operation);

        vm.prank(intentExecutor);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        validator.verifyExecution(
            address(hca),
            keccak256(operationData),
            _sessionUse(keccak256("missing session"), sessionKey, keccak256(operationData)),
            operation
        );

        vm.mockCallRevert(
            address(hca),
            abi.encodeWithSignature("ownerAndSessionNonce()"),
            abi.encode("owner unavailable")
        );
        assertFalse(validator.isPermissionEnabled(address(hca), permissionId));
        vm.clearMockedCalls();
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
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_allowsSessionChosenRegistrationAndPrimaryNames() public view {
        validatorHarness.checkRegistrationPolicyHarness(
            owner,
            resolver,
            _registrationOperationDataWithDefaultReverseName(owner, resolver, "bob.eth")
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallDataForLabel(
            "alice",
            owner,
            resolver
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallDataForLabel(
            "bob",
            owner,
            resolver
        )});
        validatorHarness.checkRegistrationPolicyHarness(owner, resolver, _operationData(executions));
    }

    function test_validator_rejectsPolicyViolations() public {
        bytes memory operationData = _registrationOperationData(owner, otherResolver);
        _expectValidationRevert(
            operationData,
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 1, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        operationData = _operationData(executions);
        _expectValidationRevert(
            operationData,
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsRegistrationPolicyArgumentFailures() public {
        _expectValidationRevert(
            _registrationOperationData(vm.addr(badKey), resolver),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _registrationOperationData(owner, address(0)),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _registrationOperationData(owner, resolver),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            resolver
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            otherResolver
        )});

        _expectValidationRevert(
            _operationData(executions),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );

        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            address(0)
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            resolver
        )});

        _expectValidationRevert(
            _operationData(executions),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
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
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                ethRegistrar,
                0,
                abi.encodeWithSelector(RENEW_SELECTOR, "alice", uint64(365 days), usdc, bytes32(0))
            ),
            address(0),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32("commitment"))
            ),
            resolver,
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(SET_NAME_WITH_HCA_SELECTOR, owner, "alice.eth")
            ),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                defaultReverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(SET_NAME_WITH_HCA_SELECTOR, vm.addr(badKey), "alice.eth")
            ),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(usdc, 0, abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))),
            address(0),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                dai,
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, defaultReverseRegistrarHCAAdapter, 1 ether)
            ),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                verifiableFactory,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))
            ),
            address(0),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                verifiableFactory,
                0,
                abi.encodeWithSelector(DEPLOY_PROXY_SELECTOR, otherResolver, 123, "")
            ),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                makeAddr("unknown-target"),
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))
            ),
            address(0),
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(resolver, 0, abi.encodeWithSelector(COMMIT_SELECTOR, bytes32(0))),
            resolver,
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
    }

    function test_validator_rejectsMalformedPolicyCalldata() public {
        _expectValidationRevert(
            _singleOperationData(ethRegistrar, 0, hex"1234"),
            address(0),
            HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector
        );
        _expectValidationRevert(
            _singleOperationData(usdc, 0, abi.encodePacked(APPROVE_SELECTOR)),
            address(0),
            HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.callArgsHarness(hex"1234");
    }

    function test_validator_rejectsInvalidOperationEncoding() public {
        _expectValidationRevert(
            hex"0200",
            address(0),
            HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector
        );
        _expectValidationRevert(
            abi.encodePacked(bytes32(uint256(0x0205) << 240), abi.encode(new Execution[](0))),
            address(0),
            HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector
        );

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.singleChainDigestHarness(address(hca), 0, hex"");
    }

    function test_validator_moduleSurface() public view {
        assertTrue(validator.isModuleType(1));
        assertFalse(validator.isModuleType(2));
        assertTrue(validator.isInitialized(address(hca)));
    }

    function test_validator_validatesOwnerUserOperations() public {
        bytes32 userOpHash = keccak256("owner user operation");
        PackedUserOperation memory userOp;
        userOp.sender = address(hca);
        userOp.signature = _sign(ownerKey, userOpHash);

        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 0);

        userOp.signature = _signPersonal(ownerKey, userOpHash);
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 0);

        userOp.signature = _signRhinestoneMessage(ownerKey, userOpHash);
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 0);

        userOp.signature = _signV01(ownerKey, userOpHash);
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 0);

        userOp.signature = hex"1234";
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 1);

        userOp.signature = abi.encodePacked(bytes32(0), bytes32(0), uint8(29));
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 1);

        userOp.signature = _sign(badKey, userOpHash);
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 1);

        userOp.sender = makeAddr("other-account");
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(userOp, userOpHash), 1);
    }

    function test_standaloneSingleOwnerHCA_deploysAndExecutesPaymasterSponsoredOwnerUserOp() public {
        EntryPoint userOpEntryPoint = new EntryPoint();
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA implementation =
            new StandaloneSingleOwnerHCA(
                address(userOpEntryPoint),
                address(validator),
                address(defaultExecutor),
                "",
                upgradeGate,
                ApprovedUpgradeGate(address(0))
            );
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneHCAFactory deployer = new StandaloneHCAFactory(factory);
        uint256 userSalt = 4337;
        uint256 deploymentSalt = deployer.deploymentSalt(owner, address(implementation), userSalt);
        bytes32 outerSalt = keccak256(abi.encode(address(deployer), deploymentSalt));
        address account =
            Create2.computeAddress(
                outerSalt,
                keccak256(CloneProxyBytecode.creationCode(factory.proxyLogic(), outerSalt)),
                address(factory)
            );
        assertEq(account.code.length, 0);

        TestPaymasterAcceptAll paymaster =
            new TestPaymasterAcceptAll(IEntryPoint(address(userOpEntryPoint)));
        vm.deal(address(this), 1 ether);
        paymaster.deposit{value: 1 ether}();

        WalletPaidTarget target = new WalletPaidTarget();
        PackedUserOperation memory userOp;
        userOp.sender = account;
        userOp.nonce = userOpEntryPoint.getNonce(account, uint192(0x123456) << 168);
        userOp.initCode = abi.encodePacked(
            address(deployer),
            abi.encodeCall(StandaloneHCAFactory.deploy, (owner, address(implementation), userSalt))
        );
        userOp.callData = abi.encodeCall(
            Nexus.execute,
            (
                ModeLib.encodeSimpleSingle(),
                ExecLib.encodeSingle(
                    address(target),
                    0,
                    abi.encodeCall(WalletPaidTarget.setValue, (4337))
                )
            )
        );
        userOp.accountGasLimits = bytes32((uint256(500_000) << 128) | uint256(1_000_000));
        userOp.preVerificationGas = 100_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(500_000),
            uint128(100_000)
        );
        userOp.signature = _signPersonal(ownerKey, userOpEntryPoint.getUserOpHash(userOp));

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        uint256 paymasterDepositBefore = userOpEntryPoint.balanceOf(address(paymaster));

        vm.txGasPrice(1 gwei);
        userOpEntryPoint.handleOps(userOps, payable(makeAddr("bundler")));

        assertEq(target.value(), 4337);
        assertEq(StandaloneSingleOwnerHCA(payable(account)).owner(), owner);
        assertEq(factory.verifyContract(account), address(implementation));
        assertEq(account.balance, 0);
        assertLt(userOpEntryPoint.balanceOf(address(paymaster)), paymasterDepositBefore);
    }

    function test_validator_installHooksAreNoops() public view {
        validator.onInstall("");
        validator.onUninstall("");
    }

    function _newAccount() internal returns (StandaloneSingleOwnerHCA) {
        return _newAccount(ApprovedUpgradeGate(address(0)));
    }

    function _newAccount(ApprovedUpgradeGate predecessorUpgradeGate)
        internal
        returns (StandaloneSingleOwnerHCA)
    {
        MockValidatorModule defaultValidator = new MockValidatorModule();
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        return
            new StandaloneSingleOwnerHCA(
                entryPoint,
                address(defaultValidator),
                address(defaultExecutor),
                "",
                upgradeGate,
                predecessorUpgradeGate
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
                upgradeGate,
                ApprovedUpgradeGate(address(0))
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

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](7);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            registrant,
            registrationResolver
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: registrationResolver, value: 0, callData: abi.encodeWithSelector(
            SET_ADDR_SELECTOR,
            bytes32("node"),
            registrant
        )});
        executions[2] = HCAOwnerAndSessionValidator.Execution({target: registrationResolver, value: 0, callData: abi.encodeWithSelector(
            MULTICALL_SELECTOR,
            resolverCalls
        )});
        executions[3] = HCAOwnerAndSessionValidator.Execution({target: registrationResolver, value: 0, callData: abi.encodeWithSelector(
            MULTICALL_WITH_NODE_CHECK_SELECTOR,
            bytes32("node"),
            resolverCalls
        )});
        executions[4] = HCAOwnerAndSessionValidator.Execution({target: usdc, value: 0, callData: abi.encodeWithSelector(
            APPROVE_SELECTOR,
            ethRegistrar,
            1 ether
        )});
        executions[5] = HCAOwnerAndSessionValidator.Execution({target: verifiableFactory, value: 0, callData: abi.encodeWithSelector(
            DEPLOY_PROXY_SELECTOR,
            permittedResolverImpl,
            123,
            ""
        )});
        executions[6] = HCAOwnerAndSessionValidator.Execution({target: defaultReverseRegistrarHCAAdapter, value: 0, callData: abi.encodeWithSelector(
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
        return _registerCallDataForLabel("alice", registrant, registrationResolver);
    }

    function _registerCallDataForLabel(
        string memory label,
        address registrant,
        address registrationResolver
    )
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(
                REGISTER_SELECTOR,
                label,
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
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        return _operationData(executions);
    }

    function _singleOperationData(address target, uint256 value, bytes memory callData)
        internal
        view
        returns (bytes memory)
    {
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: target, value: value, callData: callData});
        return _operationData(executions);
    }

    function _operationData(HCAOwnerAndSessionValidator.Execution[] memory executions)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodePacked(validator.ERC7579_EMISSARY_EXECUTION_MODE(), abi.encode(executions));
    }

    function _erc1271OperationData(HCAOwnerAndSessionValidator.Execution[] memory executions)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(validator.ERC7579_ERC1271_MODE(), abi.encode(executions));
    }

    function _erc1271CommitOperationData() internal view returns (bytes memory) {
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        return _erc1271OperationData(executions);
    }

    function _expectValidationRevert(
        bytes memory operationData,
        address allowedResolver,
        bytes4 selector
    )
        internal
    {
        if (selector == HCAOwnerAndSessionValidator.ActionNotAllowed.selector) {
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
        HCAOwnerAndSessionValidator.Operation memory operation =
            HCAOwnerAndSessionValidator.Operation({data: operationData});
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

    function _fixedSessionEnvelope(
        bytes32 permissionId,
        uint256 nonce,
        bytes memory operationData,
        uint256 signerKey,
        bytes32 digest
    )
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                bytes1(uint8(1)),
                permissionId,
                nonce,
                operationData,
                _sign(signerKey, digest)
            );
    }

    function _fixedSessionRefundEnvelope(
        bytes32 permissionId,
        uint256 nonce,
        HCAOwnerAndSessionValidator.GasRefund memory gasRefund,
        bytes memory operationData,
        uint256 signerKey,
        bytes32 digest
    )
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                bytes1(uint8(2)),
                permissionId,
                nonce,
                gasRefund.token,
                gasRefund.exchangeRate,
                gasRefund.overhead,
                operationData,
                _sign(signerKey, digest)
            );
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

    function _signPersonal(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function _signV01(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v - 27);
    }
}


contract HCAOwnerAndSessionValidatorHarness is HCAOwnerAndSessionValidator {
    constructor(
        address defaultReverseRegistrarHCAAdapter,
        address permittedResolverImpl,
        address ethRegistrar,
        address verifiableFactory,
        address paymentToken,
        address secondaryPaymentToken,
        address intentExecutor,
        address gasRefundPaymaster
    )
        HCAOwnerAndSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            paymentToken,
            secondaryPaymentToken,
            intentExecutor,
            gasRefundPaymaster
        )
    {}

    function callArgsHarness(bytes memory callData) external pure returns (bytes memory) {
        return _callArgs(callData);
    }

    function recoverHarness(bytes32 digest, bytes calldata signature)
        external
        pure
        returns (address)
    {
        return _recover(digest, signature);
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

    function singleChainDigestHarness(address account, uint256 nonce, bytes calldata operationData)
        external
        view
        returns (bytes32)
    {
        return _singleChainDigest(account, nonce, operationData);
    }

    function singleChainDigestWithRefundHarness(
        address account,
        uint256 nonce,
        bytes calldata operationData,
        GasRefund calldata gasRefund
    )
        external
        view
        returns (bytes32)
    {
        return _singleChainDigest(account, nonce, operationData, gasRefund);
    }
}


contract StandaloneSingleOwnerHCAHarness is StandaloneSingleOwnerHCA {
    constructor(
        address entryPoint,
        address defaultValidator,
        address defaultExecutor,
        bytes memory validatorInitData,
        ApprovedUpgradeGate upgradeGate,
        ApprovedUpgradeGate predecessorUpgradeGate
    )
        StandaloneSingleOwnerHCA(
            entryPoint,
            defaultValidator,
            defaultExecutor,
            validatorInitData,
            upgradeGate,
            predecessorUpgradeGate
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
