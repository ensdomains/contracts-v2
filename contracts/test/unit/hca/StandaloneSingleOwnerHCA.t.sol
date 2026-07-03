// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable private-vars-leading-underscore, func-name-mixedcase, gas-custom-errors

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {Test} from "forge-std/Test.sol";

import {
    MockExecutorModule,
    MockRegistrationCommitter,
    MockStandaloneHCA,
    MockValidatorModule,
    MockVerifiableFactory
} from "../../mocks/MockStandaloneHCAStack.sol";
import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {RegistrationBootstrapper} from "~src/hca/RegistrationBootstrapper.sol";
import {
    OwnerBoundRegistrationSessionValidator
} from "~src/hca/OwnerBoundRegistrationSessionValidator.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";

contract StandaloneSingleOwnerHCATest is Test {
    struct Permit2Fields {
        uint256 sourceChainId;
        address permit2Contract;
        address arbiter;
        uint256 nonce;
        uint256 expires;
    }

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

    bytes32 constant SESSION_GRANT_TYPEHASH =
        keccak256(
            "RegistrationSessionGrant(uint256 chainId,address hca,address owner,address sessionKey,uint48 validUntil,address resolver)"
        );
    bytes32 constant PERMIT2_SESSION_GRANT_TYPEHASH =
        keccak256(
            "RegistrationPermit2SessionGrant(uint256 destinationChainId,address hca,address owner,address sessionKey,uint48 validUntil,address resolver)"
        );
    bytes32 constant PERMIT2_DOMAIN_TYPEHASH =
        0x8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866;
    bytes32 constant PERMIT2_NAME_HASH =
        0x9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a;
    bytes32 constant PERMIT2_JIT_TYPEHASH =
        0x1b355fbc76f14a5aefe5c85df793a0f876f90d66f457273501c13ac311b5f3f8;
    bytes32 constant PERMIT2_MANDATE_TYPEHASH =
        0xc988b4da10503879cf4b893fed09620229f5ade301ef5e4af6124b22823627dc;
    bytes32 constant EMPTY_ARRAY_HASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    bytes32 constant NO_OPS_HASH =
        0x0c7bea50822ae8a3846eccbda4961a80e1e08aa92f2bf046be0011514ad2ddf1;

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

    OwnerBoundRegistrationSessionValidator validator;
    OwnerBoundRegistrationSessionValidatorHarness validatorHarness;
    MockStandaloneHCA hca;

    function setUp() public {
        validator = new OwnerBoundRegistrationSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            usdc,
            dai
        );
        validatorHarness = new OwnerBoundRegistrationSessionValidatorHarness(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            usdc,
            dai
        );
        hca = new MockStandaloneHCA(owner);
    }

    function test_registrationBootstrapper_deploysAndCommits() public {
        RegistrationBootstrapper bootstrapper = new RegistrationBootstrapper();
        MockVerifiableFactory factory = new MockVerifiableFactory();
        MockRegistrationCommitter registrar = new MockRegistrationCommitter();
        bytes memory initData = abi.encode(owner);
        bytes32 commitment = keccak256("commitment");

        address deployed =
            bootstrapper.deployAndCommit(
                IVerifiableFactory(address(factory)),
                address(0x1234),
                123,
                initData,
                IETHRegistrar(address(registrar)),
                commitment
            );

        assertEq(deployed, factory.proxy());
        assertEq(factory.implementation(), address(0x1234));
        assertEq(factory.salt(), 123);
        assertEq(keccak256(factory.initData()), keccak256(initData));
        assertEq(registrar.commitment(), commitment);
    }

    function test_standaloneSingleOwnerHCA_initializesOwner() public {
        StandaloneSingleOwnerHCA account = _newAccount();

        account.initializeAccount(abi.encode(owner));

        assertEq(account.owner(), owner);
        assertEq(account.accountId(), "ens-standalone-hca.1.0.0");
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

        vm.expectRevert(StandaloneSingleOwnerHCA.HCAUpgradeDisabled.selector);
        accountHarness.authorizeUpgradeHarness(address(0xBEEF));
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

    function test_validator_acceptsDirectOwnerRegistrationPolicy() public view {
        bytes memory operationData = _registrationOperationData(owner, resolver);
        bytes32 operationHash = keccak256(operationData);

        bytes memory signature =
            _signatureData(
                owner,
                address(0),
                0,
                resolver,
                _sign(ownerKey, operationHash),
                "",
                operationData
            );

        assertEq(hca.validate(validator, operationHash, signature), ERC1271_MAGICVALUE);
    }

    function test_validator_acceptsLegacySessionGrant() public view {
        bytes memory operationData = _registrationOperationData(owner, resolver);
        bytes32 operationHash = keccak256(operationData);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes32 grantHash =
            keccak256(
                abi.encode(
                    SESSION_GRANT_TYPEHASH,
                    block.chainid,
                    address(hca),
                    owner,
                    sessionSigner,
                    validUntil,
                    resolver
                )
            );

        bytes memory signature =
            _signatureData(
                owner,
                sessionSigner,
                validUntil,
                resolver,
                _sign(ownerKey, _toEthSignedMessageHash(grantHash)),
                _sign(sessionKey, operationHash),
                operationData
            );

        assertEq(hca.validate(validator, operationHash, signature), ERC1271_MAGICVALUE);
    }

    function test_validator_acceptsPermit2SessionGrant() public {
        bytes memory operationData = _registrationOperationData(owner, resolver);
        bytes32 operationHash = keccak256(operationData);
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = _permit2SignatureData(operationHash, operationData, validUntil);

        assertEq(hca.validate(validator, operationHash, signature), ERC1271_MAGICVALUE);
    }

    function test_validator_acceptsDirectOwnerSignatureWithV01() public view {
        bytes memory operationData = _commitAndRenewOperationData();
        bytes32 operationHash = keccak256(operationData);
        bytes memory signature =
            _signatureData(
                owner,
                address(0),
                0,
                address(0),
                _signV01(ownerKey, operationHash),
                "",
                operationData
            );

        assertEq(hca.validate(validator, operationHash, signature), ERC1271_MAGICVALUE);
    }

    function test_validator_rejectsOwnerAvailabilityAndDirectSignerFailures() public {
        bytes memory operationData = _commitOperationData();
        bytes32 operationHash = keccak256(operationData);
        bytes memory signature = _directSignature(operationData, address(0), ownerKey);

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.OwnerUnavailable.selector);
        validator.isValidSignatureWithSender(address(this), operationHash, signature);

        MockStandaloneHCA zeroOwnerHCA = new MockStandaloneHCA(address(0));
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.OwnerUnavailable.selector);
        zeroOwnerHCA.validate(validator, operationHash, signature);

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(validator, operationHash, _directSignature(operationData, address(0), badKey));

        bytes memory shortSignature =
            _signatureData(owner, address(0), 0, address(0), hex"1234", "", operationData);
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(validator, operationHash, shortSignature);

        bytes memory zeroSignature =
            _signatureData(
                owner,
                address(0),
                0,
                address(0),
                abi.encodePacked(bytes32(0), bytes32(0), uint8(27)),
                "",
                operationData
            );
        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(validator, operationHash, zeroSignature);
    }

    function test_validator_rejectsSessionSignerFailures() public {
        bytes memory operationData = _commitOperationData();
        bytes32 operationHash = keccak256(operationData);
        uint48 validUntil = uint48(block.timestamp + 1 days);

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            operationHash,
            _legacySessionSignature(operationHash, operationData, validUntil, badKey, sessionKey)
        );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            operationHash,
            _legacySessionSignature(operationHash, operationData, validUntil, ownerKey, badKey)
        );
    }

    function test_validator_rejectsPermit2SessionFailures() public {
        bytes memory operationData = _commitOperationData();
        bytes32 operationHash = keccak256(operationData);
        uint48 validUntil = uint48(block.timestamp + 1 days);

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.SessionExpired.selector);
        hca.validate(
            validator,
            operationHash,
            _permit2SignatureData(
                operationHash,
                operationData,
                validUntil,
                block.timestamp - 1,
                ownerKey,
                sessionKey
            )
        );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            operationHash,
            _permit2SignatureData(
                operationHash,
                operationData,
                validUntil,
                block.timestamp + 2 days,
                badKey,
                sessionKey
            )
        );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(
            validator,
            operationHash,
            _permit2SignatureData(
                operationHash,
                operationData,
                validUntil,
                block.timestamp + 2 days,
                ownerKey,
                badKey
            )
        );
    }

    function test_validator_rejectsWrongOwnerAndExpiredSession() public {
        bytes memory operationData = _commitOperationData();
        bytes32 operationHash = keccak256(operationData);
        bytes memory directSignature =
            _signatureData(
                vm.addr(badKey),
                address(0),
                0,
                address(0),
                _sign(badKey, operationHash),
                "",
                operationData
            );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidSigner.selector);
        hca.validate(validator, operationHash, directSignature);

        bytes memory expiredSession =
            _signatureData(
                owner,
                sessionSigner,
                uint48(block.timestamp - 1),
                resolver,
                _sign(ownerKey, operationHash),
                _sign(sessionKey, operationHash),
                operationData
            );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.SessionExpired.selector);
        hca.validate(validator, operationHash, expiredSession);
    }

    function test_validator_rejectsPolicyViolations() public {
        bytes memory operationData = _registrationOperationData(owner, otherResolver);
        bytes32 operationHash = keccak256(operationData);
        bytes memory signature =
            _signatureData(
                owner,
                address(0),
                0,
                resolver,
                _sign(ownerKey, operationHash),
                "",
                operationData
            );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector);
        hca.validate(validator, operationHash, signature);

        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](1);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: ethRegistrar, value: 1, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("commitment")
        )});
        operationData = _operationData(executions);
        operationHash = keccak256(operationData);
        signature = _signatureData(
            owner,
            address(0),
            0,
            address(0),
            _sign(ownerKey, operationHash),
            "",
            operationData
        );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.PolicyRuleFailed.selector);
        hca.validate(validator, operationHash, signature);
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
                abi.encodeWithSelector(SET_NAME_WITH_HCA_SELECTOR, owner, "alice.eth")
            ),
            resolver,
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

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.callArgsHarness(hex"1234");
    }

    function test_validator_rejectsInvalidOperationEncoding() public {
        bytes memory operationData = hex"0200";
        bytes32 operationHash = keccak256(operationData);
        bytes memory signature =
            _signatureData(
                owner,
                address(0),
                0,
                address(0),
                _sign(ownerKey, operationHash),
                "",
                operationData
            );

        vm.expectRevert(OwnerBoundRegistrationSessionValidator.InvalidOperationEncoding.selector);
        hca.validate(validator, operationHash, signature);
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
                ""
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
                ""
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
        pure
        returns (bytes memory)
    {
        OwnerBoundRegistrationSessionValidator.Execution[] memory executions =
            new OwnerBoundRegistrationSessionValidator.Execution[](1);
        executions[0] = OwnerBoundRegistrationSessionValidator.Execution({target: target, value: value, callData: callData});
        return _operationData(executions);
    }

    function _operationData(OwnerBoundRegistrationSessionValidator.Execution[] memory executions)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes1(uint8(2)), bytes1(uint8(1)), abi.encode(executions));
    }

    function _expectValidationRevert(
        bytes memory operationData,
        address allowedResolver,
        bytes4 selector
    )
        internal
    {
        bytes32 operationHash = keccak256(operationData);
        if (selector == OwnerBoundRegistrationSessionValidator.ActionNotAllowed.selector) {
            vm.expectPartialRevert(selector);
        } else {
            vm.expectRevert(selector);
        }
        hca.validate(
            validator,
            operationHash,
            _directSignature(operationData, allowedResolver, ownerKey)
        );
    }

    function _directSignature(bytes memory operationData, address allowedResolver, uint256 signerKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 operationHash = keccak256(operationData);
        return
            _signatureData(
                owner,
                address(0),
                0,
                allowedResolver,
                _sign(signerKey, operationHash),
                "",
                operationData
            );
    }

    function _legacySessionSignature(
        bytes32 operationHash,
        bytes memory operationData,
        uint48 validUntil,
        uint256 grantSignerKey,
        uint256 operationSignerKey
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 grantHash =
            keccak256(
                abi.encode(
                    SESSION_GRANT_TYPEHASH,
                    block.chainid,
                    address(hca),
                    owner,
                    sessionSigner,
                    validUntil,
                    resolver
                )
            );

        return
            _signatureData(
                owner,
                sessionSigner,
                validUntil,
                resolver,
                _sign(grantSignerKey, _toEthSignedMessageHash(grantHash)),
                _sign(operationSignerKey, operationHash),
                operationData
            );
    }

    function _signatureData(
        address signer,
        address session,
        uint48 validUntil,
        address allowedResolver,
        bytes memory ownerSignature,
        bytes memory sessionSignature,
        bytes memory operationData
    )
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encode(
                signer,
                session,
                validUntil,
                allowedResolver,
                uint256(0),
                address(0),
                address(0),
                uint256(0),
                uint256(0),
                ownerSignature,
                sessionSignature,
                operationData
            );
    }

    function _permit2SignatureData(
        bytes32 operationHash,
        bytes memory operationData,
        uint48 validUntil
    )
        internal
        returns (bytes memory)
    {
        return
            _permit2SignatureData(
                operationHash,
                operationData,
                validUntil,
                block.timestamp + 2 days,
                ownerKey,
                sessionKey
            );
    }

    function _permit2SignatureData(
        bytes32 operationHash,
        bytes memory operationData,
        uint48 validUntil,
        uint256 expires,
        uint256 grantSignerKey,
        uint256 operationSignerKey
    )
        internal
        returns (bytes memory)
    {
        Permit2Fields memory permit2 =
            Permit2Fields({sourceChainId: 10, permit2Contract: makeAddr("permit2"), arbiter: makeAddr(
                "arbiter"
            ), nonce: 99, expires: expires});
        bytes32 permit2Digest =
            _permit2SessionDigest(address(hca), owner, sessionSigner, validUntil, resolver, permit2);

        OwnerBoundRegistrationSessionValidator.SignatureData memory sigData;
        sigData.owner = owner;
        sigData.sessionKey = sessionSigner;
        sigData.validUntil = validUntil;
        sigData.resolver = resolver;
        sigData.permit2SourceChainId = permit2.sourceChainId;
        sigData.permit2Contract = permit2.permit2Contract;
        sigData.permit2Arbiter = permit2.arbiter;
        sigData.permit2Nonce = permit2.nonce;
        sigData.permit2Expires = permit2.expires;
        sigData.ownerSignature = _sign(grantSignerKey, permit2Digest);
        sigData.sessionSignature = _sign(operationSignerKey, operationHash);
        sigData.operationData = operationData;

        return
            abi.encode(
                sigData.owner,
                sigData.sessionKey,
                sigData.validUntil,
                sigData.resolver,
                sigData.permit2SourceChainId,
                sigData.permit2Contract,
                sigData.permit2Arbiter,
                sigData.permit2Nonce,
                sigData.permit2Expires,
                sigData.ownerSignature,
                sigData.sessionSignature,
                sigData.operationData
            );
    }

    function _permit2SessionDigest(
        address account,
        address signer,
        address session,
        uint48 validUntil,
        address allowedResolver,
        Permit2Fields memory permit2
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 grantHash =
            keccak256(
                abi.encode(
                    PERMIT2_SESSION_GRANT_TYPEHASH,
                    block.chainid,
                    account,
                    signer,
                    session,
                    validUntil,
                    allowedResolver
                )
            );
        bytes32 mandate =
            keccak256(
                abi.encode(
                    PERMIT2_MANDATE_TYPEHASH,
                    bytes32(0),
                    uint128(0),
                    grantHash,
                    NO_OPS_HASH,
                    bytes32(0)
                )
            );
        bytes32 permit2Hash =
            keccak256(
                abi.encode(
                    PERMIT2_JIT_TYPEHASH,
                    EMPTY_ARRAY_HASH,
                    permit2.arbiter,
                    permit2.nonce,
                    permit2.expires,
                    mandate
                )
            );
        bytes32 domainSeparator =
            keccak256(
                abi.encode(
                    PERMIT2_DOMAIN_TYPEHASH,
                    PERMIT2_NAME_HASH,
                    permit2.sourceChainId,
                    permit2.permit2Contract
                )
            );

        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, permit2Hash));
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
        address secondaryPaymentToken
    )
        OwnerBoundRegistrationSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistrar,
            verifiableFactory,
            paymentToken,
            secondaryPaymentToken
        )
    {}

    function callArgsHarness(bytes memory callData) external pure returns (bytes memory) {
        return _callArgs(callData);
    }
}


contract StandaloneSingleOwnerHCAHarness is StandaloneSingleOwnerHCA {
    constructor(
        address entryPoint,
        address defaultValidator,
        address defaultExecutor,
        bytes memory validatorInitData
    )
        StandaloneSingleOwnerHCA(entryPoint, defaultValidator, defaultExecutor, validatorInitData)
    {}

    function authorizeUpgradeHarness(address newImplementation) external pure {
        _authorizeUpgrade(newImplementation);
    }
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
