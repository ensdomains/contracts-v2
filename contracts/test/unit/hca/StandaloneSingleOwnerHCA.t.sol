// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable private-vars-leading-underscore, func-name-mixedcase, gas-custom-errors

import {IUUPSProxy} from "@ensdomains/verifiable-factory/IUUPSProxy.sol";
import {CloneProxyBytecode} from "@ensdomains/verifiable-factory/CloneProxyBytecode.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {TestPaymasterAcceptAll} from "account-abstraction/test/TestPaymasterAcceptAll.sol";
import {
    IModuleManagerEventsAndErrors
} from "nexus/interfaces/base/IModuleManagerEventsAndErrors.sol";
import {Nexus} from "nexus/Nexus.sol";
import {ExecLib} from "nexus/lib/ExecLib.sol";
import {
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    MODE_DEFAULT,
    ModeLib,
    ModePayload
} from "nexus/lib/ModeLib.sol";
import {Execution} from "nexus/types/DataTypes.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {Test} from "forge-std/Test.sol";

import {
    MockExecutorModule,
    MockStandaloneHCA,
    MockValidatorModule
} from "../../mocks/MockStandaloneHCAStack.sol";

import {Grant} from "~src/access-control/interfaces/IEACGrantInitializable.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {StandaloneHCAFactory} from "~src/hca/StandaloneHCAFactory.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IStandaloneHCAOwner} from "~src/hca/interfaces/IStandaloneHCAOwner.sol";
import {IRentPriceOracle} from "~src/registrar/interfaces/IRentPriceOracle.sol";
import {IRentPriceOracleProvider} from "~src/registrar/interfaces/IRentPriceOracleProvider.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {
    IPermissionedResolverInitializable
} from "~src/resolver/interfaces/IPermissionedResolverInitializable.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

/// @title Standalone Single-Owner HCA Tests
/// @notice Exercises account ownership, sessions, execution, and upgrade authorization.
contract StandaloneSingleOwnerHCATest is Test {
    string internal constant PERMISSIONED_ADDRESS_SET_ARTIFACT =
        "src/utils/PermissionedAddressSet.sol:PermissionedAddressSet";
    string internal constant PERMISSIONED_RESOLVER_ARTIFACT =
        "src/resolver/PermissionedResolver.sol:PermissionedResolver";
    string internal constant PERMISSIONED_REGISTRY_ARTIFACT =
        "src/registry/PermissionedRegistry.sol:PermissionedRegistry";
    string internal constant STANDARD_RENT_PRICE_ORACLE_ARTIFACT =
        "src/registrar/StandardRentPriceOracle.sol:StandardRentPriceOracle";
    string internal constant ETH_REGISTRAR_ARTIFACT = "src/registrar/ETHRegistrar.sol:ETHRegistrar";

    /// @dev Layout mirror of `StandardRentPriceOracle`'s `DiscountPoint` constructor argument.
    struct OracleDiscountPoint {
        uint64 duration;
        uint128 numer;
    }

    /// @dev Layout mirror of `StandardRentPriceOracle`'s `PaymentRatio` constructor argument.
    struct OraclePaymentRatio {
        address paymentToken;
        uint128 numer;
        uint128 denom;
    }

    bytes4 constant ERC1271_MAGICVALUE = 0x1626ba7e;

    bytes4 constant COMMIT_SELECTOR = 0xf14fcbc8;
    bytes4 constant REGISTER_SELECTOR = 0xcff3e7c2;
    bytes4 constant RENEW_SELECTOR = 0x89d779c3;
    bytes4 constant APPROVE_SELECTOR = 0x095ea7b3;
    bytes4 constant DEPLOY_PROXY_SELECTOR = 0x5d84121a;
    bytes4 constant SET_NAME_WITH_HCA_SELECTOR = 0xab863445;
    bytes4 constant CLAIM_WITH_HCA_SELECTOR = 0xc90695df;
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
    address reverseRegistrarHCAAdapter = makeAddr("addr-reverse-adapter");
    address permittedResolverImpl = makeAddr("resolver-impl");
    address ethRegistrar;
    address verifiableFactory = makeAddr("verifiable-factory");
    address usdc = makeAddr("usdc");
    address dai = makeAddr("dai");
    address resolver = makeAddr("resolver");
    address otherResolver = makeAddr("other-resolver");
    address subregistry = makeAddr("subregistry");
    address entryPoint = makeAddr("entry-point");
    address intentExecutor = makeAddr("intent-executor");
    address gasRefundPaymaster = makeAddr("gas-refund-paymaster");

    uint256 resolverSalt = 123;
    uint256 counterfactualResolverSalt = 456;
    address counterfactualResolver;

    address upgradeSetAdmin = makeAddr("upgrade-set-admin");

    HCAOwnerAndSessionValidator validator;
    HCAOwnerAndSessionValidatorHarness validatorHarness;
    IPermissionedRegistry ethRegistry;
    MockStandaloneHCA hca;
    IAddressSetApproval upgradeSet;

    function setUp() public {
        upgradeSet = _deployPermissionedAddressSet(upgradeSetAdmin);
        hca = new MockStandaloneHCA(owner);
        ethRegistry = IPermissionedRegistry(
            deployCode(
                PERMISSIONED_REGISTRY_ARTIFACT,
                abi.encode(address(0), address(this), RegistryRolesLib.ROLE_REGISTRAR_ADMIN)
            )
        );
        ethRegistrar = _deployRegistrarWithOracle(_defaultPaymentTokens());
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, ethRegistrar);

        VerifiableFactory factory = new VerifiableFactory();
        verifiableFactory = address(factory);
        permittedResolverImpl = _deployPermissionedResolver(makeAddr("resolver-namer"));
        bytes[] memory setters = new bytes[](0);
        vm.prank(address(hca));
        resolver = factory.deployProxy(
            permittedResolverImpl,
            resolverSalt,
            _resolverInitData(address(hca), EACBaseRolesLib.ALL_ROLES, setters)
        );
        counterfactualResolver = _resolverAddress(factory, address(hca), counterfactualResolverSalt);

        validator = new HCAOwnerAndSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            reverseRegistrarHCAAdapter,
            permittedResolverImpl,
            address(ethRegistry),
            verifiableFactory,
            intentExecutor,
            gasRefundPaymaster
        );
        validatorHarness = new HCAOwnerAndSessionValidatorHarness(
            defaultReverseRegistrarHCAAdapter,
            reverseRegistrarHCAAdapter,
            permittedResolverImpl,
            address(ethRegistry),
            verifiableFactory,
            intentExecutor,
            gasRefundPaymaster
        );
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

        vm.prank(upgradeSetAdmin);
        upgradeSet.approve(target, true);

        vm.prank(owner);
        accountHarness.authorizeUpgradeHarness(target);

        assertFalse(accountHarness.canUpgradeFrom(target));
    }

    function test_standaloneSingleOwnerHCA_upgradesThroughVerifiableFactoryProxy() public {
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneSingleOwnerHCA implementation = _newAccount();
        IAddressSetApproval predecessorUpgradeSet = _deployPermissionedAddressSet(upgradeSetAdmin);
        StandaloneSingleOwnerHCA nextImplementation = _newAccount(predecessorUpgradeSet);

        address proxy =
            factory.deployProxy(
                address(implementation),
                1,
                abi.encodeCall(StandaloneSingleOwnerHCA.initializeAccount, (abi.encode(owner)))
            );
        assertEq(StandaloneSingleOwnerHCA(payable(proxy)).owner(), owner);

        vm.prank(upgradeSetAdmin);
        upgradeSet.approve(address(nextImplementation), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUUPSProxy.InvalidUpgradeTarget.selector,
                address(implementation),
                address(nextImplementation)
            )
        );
        vm.prank(owner);
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(address(nextImplementation), "");

        vm.prank(upgradeSetAdmin);
        predecessorUpgradeSet.approve(address(implementation), true);

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

        vm.expectRevert(WalletPaidTarget.Failed.selector);
        vm.prank(owner);
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
                reverseRegistrarHCAAdapter,
                permittedResolverImpl,
                address(ethRegistry),
                verifiableFactory,
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
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        vm.prank(address(hca));
        validator.enableSession(permissionId, address(0), validUntil, resolver);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(HCAOwnerAndSessionValidator.SessionExpired.selector);
        vm.prank(address(hca));
        validator.enableSession(permissionId, sessionSigner, uint48(block.timestamp - 1), resolver);

        vm.expectRevert(HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
        vm.prank(address(hca));
        validator.enableSessionWithRefund(
            permissionId,
            sessionSigner,
            validUntil,
            resolver,
            address(0),
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

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        vm.prank(intentExecutor);
        validator.verifyExecution(address(hca), keccak256(operationData), hex"01", operation);

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        vm.prank(intentExecutor);
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

    function test_validator_allowsExactResolverRoleGrantToOwner() public {
        bytes memory grantToOwner =
            _resolverRoleCall(hex"00", EACBaseRolesLib.ALL_ROLES, owner, true);
        bytes memory operationData = _singleOperationData(resolver, 0, grantToOwner);
        validatorHarness.checkRegistrationPolicyHarness(address(hca), owner, resolver, operationData);

        bytes[] memory calls = new bytes[](1);
        calls[0] = grantToOwner;
        bytes memory multicallData =
            _singleOperationData(resolver, 0, abi.encodeWithSelector(MULTICALL_SELECTOR, calls));
        validatorHarness.checkRegistrationPolicyHarness(address(hca), owner, resolver, multicallData);

        bytes memory grantToOther =
            _resolverRoleCall(hex"00", EACBaseRolesLib.ALL_ROLES, sessionSigner, true);
        _expectValidationRevert(
            _singleOperationData(resolver, 0, grantToOther),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsInvalidResolverRoleGrantArguments() public {
        _expectValidationRevert(
            _singleOperationData(
                resolver,
                0,
                _resolverRoleCall(hex"05616c69636500", EACBaseRolesLib.ALL_ROLES, owner, true)
            ),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(resolver, 0, _resolverRoleCall(hex"00", 1, owner, true)),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                resolver,
                0,
                _resolverRoleCall(hex"00", EACBaseRolesLib.ALL_ROLES, owner, false)
            ),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_allowsExactCounterfactualResolverDeployment() public view {
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            counterfactualResolver,
            _registrationWithResolverDeployment(
                permittedResolverImpl,
                counterfactualResolverSalt,
                _resolverInitData(address(hca), EACBaseRolesLib.ALL_ROLES, new bytes[](0)),
                true
            )
        );
    }

    function test_validator_rejectsDuplicateCounterfactualResolverDeployment() public {
        bytes memory deploymentCall =
            _resolverDeploymentCall(
                permittedResolverImpl,
                counterfactualResolverSalt,
                _resolverInitData(address(hca), EACBaseRolesLib.ALL_ROLES, new bytes[](0))
            );
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](4);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: verifiableFactory, value: 0, callData: deploymentCall});
        executions[1] = executions[0];
        executions[2] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            counterfactualResolver
        )});
        executions[3] = HCAOwnerAndSessionValidator.Execution({target: counterfactualResolver, value: 0, callData: _resolverRoleCall(
            hex"00",
            EACBaseRolesLib.ALL_ROLES,
            owner,
            true
        )});
        bytes memory operationData = _operationData(executions);

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            counterfactualResolver,
            operationData
        );
    }

    function test_validator_internalPolicyGuards() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof;
        HCAOwnerAndSessionValidator.GasRefund memory gasRefund;

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.checkInitialRegistrationPolicyHarness(
            address(hca),
            owner,
            bytes32(0),
            proof,
            "",
            gasRefund
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](0);
        bytes memory operationData = _erc1271OperationData(executions);
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkInitialRegistrationPolicyHarness(
            address(hca),
            owner,
            bytes32(0),
            proof,
            operationData,
            gasRefund
        );

        executions = new HCAOwnerAndSessionValidator.Execution[](2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("first")
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: abi.encodeWithSelector(
            COMMIT_SELECTOR,
            bytes32("second")
        )});
        operationData = _erc1271OperationData(executions);
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkInitialRegistrationPolicyHarness(
            address(hca),
            owner,
            bytes32(0),
            proof,
            operationData,
            gasRefund
        );

        executions = new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: usdc, value: 0, callData: abi.encodePacked(
            validatorHarness.TRANSFER_FROM_SELECTOR()
        )});
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.fundingCallIndexesHarness(executions, address(hca), owner, usdc);

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkResolverBindingHarness(address(0), true, false);

        address undeployedResolver = makeAddr("undeployed-resolver");
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkResolverBindingHarness(undeployedResolver, true, false);

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkResolverBindingHarness(address(hca), true, true);

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkResolverBindingHarness(address(hca), true, false);

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.operationHashHarness(
            abi.encodePacked(bytes32(uint256(0xDEAD)), abi.encode(executions))
        );

        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
        validatorHarness.readUintHarness("", 0);
    }

    function test_validator_rejectsInvalidCounterfactualResolverDeployment() public {
        bytes[] memory setters = new bytes[](0);
        _expectValidationRevert(
            _registrationWithResolverDeployment(
                permittedResolverImpl,
                counterfactualResolverSalt + 1,
                _resolverInitData(address(hca), EACBaseRolesLib.ALL_ROLES, setters),
                true
            ),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _registrationWithResolverDeployment(
                permittedResolverImpl,
                counterfactualResolverSalt,
                _resolverInitData(owner, EACBaseRolesLib.ALL_ROLES, setters),
                true
            ),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _registrationWithResolverDeployment(
                permittedResolverImpl,
                counterfactualResolverSalt,
                _resolverInitData(address(hca), 1, setters),
                true
            ),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );

        setters = new bytes[](1);
        setters[0] = abi.encodeWithSelector(
            SET_TEXT_SELECTOR,
            bytes32("node"),
            "avatar",
            "ipfs://avatar"
        );
        _expectValidationRevert(
            _registrationWithResolverDeployment(
                permittedResolverImpl,
                counterfactualResolverSalt,
                _resolverInitData(address(hca), EACBaseRolesLib.ALL_ROLES, setters),
                true
            ),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _registrationWithResolverDeployment(
                permittedResolverImpl,
                counterfactualResolverSalt,
                abi.encodeWithSelector(SET_ADDR_SELECTOR, bytes32("node"), owner),
                true
            ),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_requiresDeploymentForCounterfactualResolver() public {
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            counterfactualResolver
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: counterfactualResolver, value: 0, callData: _resolverRoleCall(
            hex"00",
            EACBaseRolesLib.ALL_ROLES,
            owner,
            true
        )});

        _expectValidationRevert(
            _operationData(executions),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_requiresCounterfactualResolverDeploymentFirst() public {
        bytes memory deploymentCall =
            _resolverDeploymentCall(
                permittedResolverImpl,
                counterfactualResolverSalt,
                _resolverInitData(address(hca), EACBaseRolesLib.ALL_ROLES, new bytes[](0))
            );
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](3);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            counterfactualResolver
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: verifiableFactory, value: 0, callData: deploymentCall});
        executions[2] = HCAOwnerAndSessionValidator.Execution({target: counterfactualResolver, value: 0, callData: _resolverRoleCall(
            hex"00",
            EACBaseRolesLib.ALL_ROLES,
            owner,
            true
        )});

        _expectValidationRevert(
            _operationData(executions),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );

        executions = new HCAOwnerAndSessionValidator.Execution[](2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: counterfactualResolver, value: 0, callData: abi.encodeWithSelector(
            SET_TEXT_SELECTOR,
            bytes32("node"),
            "avatar",
            "ipfs://avatar"
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: verifiableFactory, value: 0, callData: deploymentCall});

        _expectValidationRevert(
            _operationData(executions),
            counterfactualResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_requiresOwnerResolverGrantForRegistration() public {
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](1);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            resolver
        )});

        _expectValidationRevert(
            _operationData(executions),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsChangedResolverImplementation() public {
        address otherImplementation = _deployPermissionedResolver(makeAddr("other-resolver-namer"));
        vm.prank(address(hca));
        IUUPSProxyUpgrade(resolver).upgradeToAndCall(otherImplementation, "");

        _expectValidationRevert(
            _singleOperationData(
                resolver,
                0,
                abi.encodeWithSelector(SET_TEXT_SELECTOR, bytes32("node"), "avatar", "ipfs://avatar")
            ),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_allowsSessionChosenRegistrationAndPrimaryNames() public view {
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            resolver,
            _registrationOperationDataWithDefaultReverseName(owner, resolver, "bob.eth")
        );

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](3);
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
        executions[2] = HCAOwnerAndSessionValidator.Execution({target: resolver, value: 0, callData: _resolverRoleCall(
            hex"00",
            EACBaseRolesLib.ALL_ROLES,
            owner,
            true
        )});
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            resolver,
            _operationData(executions)
        );
    }

    function test_validator_acceptsMultipleRegistryAuthorizedRegistrars() public {
        address alternateRegistrar = _deployRegistrarWithOracle(_defaultPaymentTokens());
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, alternateRegistrar);

        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](4);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallDataForLabel(
            "alice",
            owner,
            resolver
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: alternateRegistrar, value: 0, callData: _registerCallDataForLabel(
            "bob",
            owner,
            resolver
        )});
        executions[2] = HCAOwnerAndSessionValidator.Execution({target: usdc, value: 0, callData: abi.encodeWithSelector(
            APPROVE_SELECTOR,
            alternateRegistrar,
            1 ether
        )});
        executions[3] = HCAOwnerAndSessionValidator.Execution({target: resolver, value: 0, callData: _resolverRoleCall(
            hex"00",
            EACBaseRolesLib.ALL_ROLES,
            owner,
            true
        )});

        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            resolver,
            _operationData(executions)
        );
    }

    function test_validator_acceptsReverseClaimForOwnerWithSessionResolver() public view {
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            resolver,
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, owner, resolver)
            )
        );
    }

    function test_validator_acceptsReverseClaimWithZeroResolver() public view {
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            resolver,
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, owner, address(0))
            )
        );
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, owner, address(0))
            )
        );
    }

    function test_validator_rejectsReverseClaimWithUndeployedResolver() public {
        address codelessResolver = makeAddr("codeless-resolver");
        _expectValidationRevert(
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, owner, codelessResolver)
            ),
            codelessResolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsReverseClaimPolicyViolations() public {
        _expectValidationRevert(
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32("commitment"))
            ),
            resolver,
            HCAOwnerAndSessionValidator.ActionNotAllowed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, owner, resolver)
            ),
            address(0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, vm.addr(badKey), resolver)
            ),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
        _expectValidationRevert(
            _singleOperationData(
                reverseRegistrarHCAAdapter,
                0,
                abi.encodeWithSelector(CLAIM_WITH_HCA_SELECTOR, owner, permittedResolverImpl)
            ),
            resolver,
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    function test_validator_rejectsRegistrarImmediatelyAfterRoleRevocation() public {
        ethRegistry.revokeRootRoles(RegistryRolesLib.ROLE_REGISTRAR, ethRegistrar);
        bytes memory operationData =
            _singleOperationData(
                ethRegistrar,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32("commitment"))
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAOwnerAndSessionValidator.ActionNotAllowed.selector,
                ethRegistrar,
                COMMIT_SELECTOR
            )
        );
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
    }

    function test_validator_rejectsApprovalAfterRegistrarRoleRevocation() public {
        ethRegistry.revokeRootRoles(RegistryRolesLib.ROLE_REGISTRAR, ethRegistrar);
        bytes memory operationData =
            _singleOperationData(
                usdc,
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, ethRegistrar, 1 ether)
            );

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
    }

    function test_validator_acceptsApprovalOfAnyOracleListedToken() public {
        address newToken = makeAddr("new-payment-token");
        address[] memory tokens = new address[](1);
        tokens[0] = newToken;
        address newRegistrar = _deployRegistrarWithOracle(tokens);
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, newRegistrar);

        bytes memory operationData =
            _singleOperationData(
                newToken,
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, newRegistrar, 1 ether)
            );

        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
    }

    function test_validator_rejectsApprovalOfTokenNotListedByRegistrarOracle() public {
        bytes memory operationData =
            _singleOperationData(
                makeAddr("junk-token"),
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, ethRegistrar, 1 ether)
            );

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
    }

    function test_validator_rejectsApprovalWhenRegistrarExposesNoOracle() public {
        address oracleLessRegistrar = makeAddr("oracle-less-registrar");
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, oracleLessRegistrar);

        bytes memory operationData =
            _singleOperationData(
                usdc,
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, oracleLessRegistrar, 1 ether)
            );

        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
    }

    function test_validator_checksIntentTokenAgainstBatchRegistrarOracles() public {
        bytes memory registerBatch = _registrationOperationData(owner, resolver);
        assertTrue(validatorHarness.isBatchRegistrarPaymentTokenHarness(registerBatch, usdc));
        assertFalse(
            validatorHarness.isBatchRegistrarPaymentTokenHarness(
                registerBatch,
                makeAddr("junk-token")
            )
        );

        bytes memory commitBatch =
            _singleOperationData(
                ethRegistrar,
                0,
                abi.encodeWithSelector(COMMIT_SELECTOR, bytes32("commitment"))
            );
        assertTrue(
            validatorHarness.isBatchRegistrarPaymentTokenHarness(commitBatch, makeAddr("junk-token"))
        );

        assertFalse(validatorHarness.isBatchRegistrarPaymentTokenHarness(hex"", usdc));
    }

    function test_validator_treatsUnresponsiveRegistrarOracleAsUnsupported() public {
        bytes memory operationData =
            _singleOperationData(
                usdc,
                0,
                abi.encodeWithSelector(APPROVE_SELECTOR, ethRegistrar, 1 ether)
            );
        bytes4 oracleGetter = IRentPriceOracleProvider.rentPriceOracle.selector;

        vm.mockCallRevert(ethRegistrar, abi.encodeWithSelector(oracleGetter), "");
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
        vm.clearMockedCalls();

        vm.mockCall(
            ethRegistrar,
            abi.encodeWithSelector(oracleGetter),
            abi.encode(makeAddr("codeless-oracle"))
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
        vm.clearMockedCalls();

        address oracle = address(IRentPriceOracleProvider(ethRegistrar).rentPriceOracle());
        vm.mockCallRevert(
            oracle,
            abi.encodeWithSelector(IRentPriceOracle.isPaymentToken.selector),
            ""
        );
        vm.expectRevert(HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            address(0),
            operationData
        );
        vm.clearMockedCalls();
    }

    function test_validator_rejectsUnapprovedRegistrarTarget() public {
        address unapprovedRegistrar = makeAddr("unapproved-registrar");
        bytes memory operationData =
            _singleOperationData(unapprovedRegistrar, 0, _registerCallData(owner, resolver));

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAOwnerAndSessionValidator.ActionNotAllowed.selector,
                unapprovedRegistrar,
                REGISTER_SELECTOR
            )
        );
        validatorHarness.checkRegistrationPolicyHarness(address(hca), owner, resolver, operationData);
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

    function test_standaloneSingleOwnerHCA_rejectsOwnerDelegatecallUserOp() public {
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA account = _newOwnerValidatedAccount(defaultExecutor);
        OwnerSlotWriter writer = new OwnerSlotWriter();
        bytes memory delegateCallData =
            abi.encodeCall(
                Nexus.execute,
                (
                    ModeLib.encode(
                        CALLTYPE_DELEGATECALL,
                        EXECTYPE_DEFAULT,
                        MODE_DEFAULT,
                        ModePayload.wrap(0)
                    ),
                    abi.encodePacked(
                        address(writer),
                        abi.encodeCall(OwnerSlotWriter.writeOwner, (makeAddr("replacement-owner")))
                    )
                )
            );

        assertEq(_validateOwnerUserOp(account, delegateCallData, 0), 1);
        assertEq(account.owner(), owner);
    }

    function test_standaloneSingleOwnerHCA_rejectsExecuteUserOpDelegatecallIndirection() public {
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA account = _newOwnerValidatedAccount(defaultExecutor);
        OwnerSlotWriter writer = new OwnerSlotWriter();
        bytes memory innerCallData =
            abi.encodeCall(
                Nexus.execute,
                (
                    ModeLib.encode(
                        CALLTYPE_DELEGATECALL,
                        EXECTYPE_DEFAULT,
                        MODE_DEFAULT,
                        ModePayload.wrap(0)
                    ),
                    abi.encodePacked(
                        address(writer),
                        abi.encodeCall(OwnerSlotWriter.writeOwner, (makeAddr("replacement-owner")))
                    )
                )
            );
        bytes memory wrappedCallData = abi.encodePacked(Nexus.executeUserOp.selector, innerCallData);

        assertEq(_validateOwnerUserOp(account, wrappedCallData, 0), 1);
        assertEq(account.owner(), owner);
    }

    function test_standaloneSingleOwnerHCA_handlesOwnerUserOpCallDataShapes() public {
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA account = _newOwnerValidatedAccount(defaultExecutor);

        assertEq(_validateOwnerUserOp(account, hex"", 0), 0);
        assertEq(_validateOwnerUserOp(account, abi.encodePacked(Nexus.executeUserOp.selector), 0), 0);
        assertEq(
            _validateOwnerUserOp(
                account,
                abi.encodePacked(Nexus.executeUserOp.selector, Nexus.executeUserOp.selector),
                0
            ),
            1
        );
        assertEq(_validateOwnerUserOp(account, hex"deadbeef", 0), 0);
        assertEq(_validateOwnerUserOp(account, abi.encodePacked(Nexus.execute.selector), 0), 1);
    }

    function test_standaloneSingleOwnerHCA_rejectsDefaultExecutorDelegatecall() public {
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA account = _newOwnerValidatedAccount(defaultExecutor);
        OwnerSlotWriter writer = new OwnerSlotWriter();

        vm.expectRevert(
            abi.encodeWithSelector(
                IModuleManagerEventsAndErrors.InvalidModule.selector,
                address(this)
            )
        );
        account.executeFromExecutor(ModeLib.encodeSimpleSingle(), "");

        vm.expectRevert(StandaloneSingleOwnerHCA.DelegateCallNotAllowed.selector);
        vm.prank(address(defaultExecutor));
        account.executeFromExecutor(
            ModeLib.encode(
                CALLTYPE_DELEGATECALL,
                EXECTYPE_DEFAULT,
                MODE_DEFAULT,
                ModePayload.wrap(0)
            ),
            abi.encodePacked(
                address(writer),
                abi.encodeCall(OwnerSlotWriter.writeOwner, (makeAddr("replacement-owner")))
            )
        );

        assertEq(account.owner(), owner);
    }

    function test_standaloneSingleOwnerHCA_allowsCallModes() public {
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA account = _newOwnerValidatedAccount(defaultExecutor);
        WalletPaidTarget target = new WalletPaidTarget();

        vm.prank(address(defaultExecutor));
        account.executeFromExecutor(
            ModeLib.encodeSimpleSingle(),
            ExecLib.encodeSingle(address(target), 0, abi.encodeCall(WalletPaidTarget.setValue, (7)))
        );

        assertEq(target.value(), 7);
        assertTrue(account.supportsExecutionMode(ModeLib.encodeSimpleSingle()));
        assertFalse(
            account.supportsExecutionMode(
                ModeLib.encode(
                    CALLTYPE_DELEGATECALL,
                    EXECTYPE_DEFAULT,
                    MODE_DEFAULT,
                    ModePayload.wrap(0)
                )
            )
        );
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
                upgradeSet,
                IAddressSet(address(0))
            );
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneHCAFactory deployer = new StandaloneHCAFactory(factory, address(this));
        deployer.setImplementationApproval(address(implementation), true);
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

    function test_standaloneSingleOwnerHCA_entryPointRejectsOwnerDelegatecallUserOp() public {
        EntryPoint userOpEntryPoint = new EntryPoint();
        MockExecutorModule defaultExecutor = new MockExecutorModule();
        StandaloneSingleOwnerHCA implementation =
            new StandaloneSingleOwnerHCA(
                address(userOpEntryPoint),
                address(validator),
                address(defaultExecutor),
                "",
                upgradeSet,
                IAddressSet(address(0))
            );
        VerifiableFactory factory = new VerifiableFactory();
        StandaloneHCAFactory deployer = new StandaloneHCAFactory(factory, address(this));
        deployer.setImplementationApproval(address(implementation), true);
        StandaloneSingleOwnerHCA account =
            StandaloneSingleOwnerHCA(payable(deployer.deploy(owner, address(implementation), 4338)));
        OwnerSlotWriter writer = new OwnerSlotWriter();

        PackedUserOperation memory userOp;
        userOp.sender = address(account);
        userOp.nonce = userOpEntryPoint.getNonce(address(account), uint192(0x123457) << 168);
        userOp.callData = abi.encodeCall(
            Nexus.execute,
            (
                ModeLib.encode(
                    CALLTYPE_DELEGATECALL,
                    EXECTYPE_DEFAULT,
                    MODE_DEFAULT,
                    ModePayload.wrap(0)
                ),
                abi.encodePacked(
                    address(writer),
                    abi.encodeCall(OwnerSlotWriter.writeOwner, (makeAddr("replacement-owner")))
                )
            )
        );
        userOp.accountGasLimits = bytes32((uint256(500_000) << 128) | uint256(1_000_000));
        userOp.preVerificationGas = 100_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.signature = _signPersonal(ownerKey, userOpEntryPoint.getUserOpHash(userOp));

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        vm.deal(address(this), 1 ether);
        userOpEntryPoint.depositTo{value: 1 ether}(address(account));
        vm.txGasPrice(1 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error")
        );
        userOpEntryPoint.handleOps(userOps, payable(makeAddr("bundler")));

        assertEq(account.owner(), owner);
        assertEq(factory.verifyContract(address(account)), address(implementation));
    }

    function test_poc_legacyStandaloneHCA_delegatecallSpoofsOwnerAndNamesVictim() public {
        EntryPoint userOpEntryPoint = new EntryPoint();
        LegacyDelegatecallHCA implementation =
            new LegacyDelegatecallHCA(address(userOpEntryPoint), address(validator));
        VerifiableFactory factory = new VerifiableFactory();
        IAddressSetApproval trustedHCASet = _deployPermissionedAddressSet(address(this));
        trustedHCASet.approve(address(implementation), true);
        StandaloneHCAFactory deployer = new StandaloneHCAFactory(factory, address(this));
        deployer.setImplementationApproval(address(implementation), true);
        LegacyDelegatecallHCA account =
            LegacyDelegatecallHCA(payable(deployer.deploy(owner, address(implementation), 4339)));
        DefaultReverseRegistrar defaultReverseRegistrar = new DefaultReverseRegistrar();
        ImplementationTrustOnlyDefaultAdapter defaultAdapter =
            new ImplementationTrustOnlyDefaultAdapter(
                defaultReverseRegistrar,
                factory,
                trustedHCASet
            );
        defaultReverseRegistrar.setController(address(defaultAdapter), true);
        OwnerSpoofingPayload payload = new OwnerSpoofingPayload();
        address victim = makeAddr("unrelated-victim");
        string memory attackerChosenName = "attacker.eth";

        PackedUserOperation memory userOp;
        userOp.sender = address(account);
        userOp.nonce = userOpEntryPoint.getNonce(address(account), uint192(0x123458) << 168);
        userOp.callData = abi.encodeCall(
            Nexus.execute,
            (
                ModeLib.encode(
                    CALLTYPE_DELEGATECALL,
                    EXECTYPE_DEFAULT,
                    MODE_DEFAULT,
                    ModePayload.wrap(0)
                ),
                abi.encodePacked(
                    address(payload),
                    abi.encodeCall(
                        OwnerSpoofingPayload.spoofOwnerAndSetName,
                        (ISetNameWithHCA(address(defaultAdapter)), victim, attackerChosenName)
                    )
                )
            )
        );
        userOp.accountGasLimits = bytes32((uint256(500_000) << 128) | uint256(1_000_000));
        userOp.preVerificationGas = 100_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.signature = _signPersonal(ownerKey, userOpEntryPoint.getUserOpHash(userOp));

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        vm.deal(address(this), 1 ether);
        userOpEntryPoint.depositTo{value: 1 ether}(address(account));
        vm.txGasPrice(1 gwei);
        userOpEntryPoint.handleOps(userOps, payable(makeAddr("bundler")));

        assertEq(account.owner(), owner);
        assertEq(defaultReverseRegistrar.nameForAddr(victim), attackerChosenName);
        assertEq(defaultReverseRegistrar.nameForAddr(owner), "");
        assertEq(factory.verifyContract(address(account)), address(implementation));
    }

    function test_validator_installHooksAreNoops() public view {
        validator.onInstall("");
        validator.onUninstall("");
    }

    function _newOwnerValidatedAccount(MockExecutorModule defaultExecutor)
        internal
        returns (StandaloneSingleOwnerHCA account)
    {
        account = new StandaloneSingleOwnerHCA(
            entryPoint,
            address(validator),
            address(defaultExecutor),
            "",
            upgradeSet,
            IAddressSet(address(0))
        );
        account.initializeAccount(abi.encode(owner));
    }

    function _validateOwnerUserOp(
        StandaloneSingleOwnerHCA account,
        bytes memory callData,
        uint256 nonce
    )
        internal
        returns (uint256 validationData)
    {
        bytes32 userOpHash = keccak256(abi.encode(address(account), nonce, keccak256(callData)));
        PackedUserOperation memory userOp;
        userOp.sender = address(account);
        userOp.nonce = nonce;
        userOp.callData = callData;
        userOp.signature = _sign(ownerKey, userOpHash);

        vm.prank(entryPoint);
        return account.validateUserOp(userOp, userOpHash, 0);
    }

    function _newAccount() internal returns (StandaloneSingleOwnerHCA) {
        return _newAccount(IAddressSet(address(0)));
    }

    function _newAccount(IAddressSet predecessorUpgradeSet)
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
                upgradeSet,
                predecessorUpgradeSet
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
                upgradeSet,
                IAddressSet(address(0))
            );
    }

    function _deployPermissionedAddressSet(address rootAccount)
        internal
        returns (IAddressSetApproval)
    {
        return
            IAddressSetApproval(
                deployCode(PERMISSIONED_ADDRESS_SET_ARTIFACT, abi.encode(rootAccount))
            );
    }

    function _deployPermissionedResolver(address namer) internal returns (address) {
        return deployCode(PERMISSIONED_RESOLVER_ARTIFACT, abi.encode(namer));
    }

    function _defaultPaymentTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = dai;
    }

    function _deployRegistrarWithOracle(address[] memory paymentTokens)
        internal
        returns (address registrar)
    {
        OraclePaymentRatio[] memory ratios = new OraclePaymentRatio[](paymentTokens.length);
        for (uint256 i; i < paymentTokens.length; ++i) {
            ratios[i] = OraclePaymentRatio(paymentTokens[i], 1, 1);
        }
        address oracle =
            deployCode(
                STANDARD_RENT_PRICE_ORACLE_ARTIFACT,
                abi.encode(
                    address(this),
                    new uint256[](1),
                    new OracleDiscountPoint[](0),
                    uint128(0),
                    uint256(0),
                    uint64(0),
                    uint64(0),
                    ratios
                )
            );
        return
            deployCode(
                ETH_REGISTRAR_ARTIFACT,
                abi.encode(
                    address(this),
                    address(ethRegistry),
                    address(this),
                    oracle,
                    uint64(90 days),
                    uint64(1 minutes),
                    uint64(1 days),
                    uint64(28 days)
                )
            );
    }

    function _resolverAddress(VerifiableFactory factory, address deployer, uint256 salt)
        internal
        view
        returns (address)
    {
        bytes32 outerSalt = keccak256(abi.encode(deployer, salt));
        return
            Create2.computeAddress(
                outerSalt,
                keccak256(CloneProxyBytecode.creationCode(factory.proxyLogic(), outerSalt)),
                address(factory)
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

    function _registrationWithResolverDeployment(
        address implementation,
        uint256 salt,
        bytes memory initData,
        bool includeOwnerGrant
    )
        internal
        view
        returns (bytes memory)
    {
        HCAOwnerAndSessionValidator.Execution[] memory executions =
            new HCAOwnerAndSessionValidator.Execution[](includeOwnerGrant ? 3 : 2);
        executions[0] = HCAOwnerAndSessionValidator.Execution({target: verifiableFactory, value: 0, callData: _resolverDeploymentCall(
            implementation,
            salt,
            initData
        )});
        executions[1] = HCAOwnerAndSessionValidator.Execution({target: ethRegistrar, value: 0, callData: _registerCallData(
            owner,
            counterfactualResolver
        )});
        if (includeOwnerGrant) {
            executions[2] = HCAOwnerAndSessionValidator.Execution({target: counterfactualResolver, value: 0, callData: _resolverRoleCall(
                hex"00",
                EACBaseRolesLib.ALL_ROLES,
                owner,
                true
            )});
        }
        return _operationData(executions);
    }

    function _resolverDeploymentCall(address implementation, uint256 salt, bytes memory initData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(DEPLOY_PROXY_SELECTOR, implementation, salt, initData);
    }

    function _resolverInitData(address admin, uint256 roleBitmap, bytes[] memory setters)
        internal
        pure
        returns (bytes memory)
    {
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant({account: admin, roleBitmap: roleBitmap});
        return abi.encodeCall(IPermissionedResolverInitializable.initialize, (grants, setters));
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
        executions[5] = HCAOwnerAndSessionValidator.Execution({target: defaultReverseRegistrarHCAAdapter, value: 0, callData: abi.encodeWithSelector(
            SET_NAME_WITH_HCA_SELECTOR,
            registrant,
            defaultReverseName
        )});
        executions[6] = HCAOwnerAndSessionValidator.Execution({target: registrationResolver, value: 0, callData: _resolverRoleCall(
            hex"00",
            EACBaseRolesLib.ALL_ROLES,
            registrant,
            true
        )});

        return _operationData(executions);
    }

    function _resolverRoleCall(bytes memory toName, uint256 roleBitmap, address account, bool grant)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(AUTHORIZE_NAME_ROLES_SELECTOR, toName, roleBitmap, account, grant);
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
        validatorHarness.checkRegistrationPolicyHarness(
            address(hca),
            owner,
            allowedResolver,
            operationData
        );
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


/// @title HCA Owner and Session Validator Harness
/// @notice Exposes internal validator helpers for policy-focused tests.
contract HCAOwnerAndSessionValidatorHarness is HCAOwnerAndSessionValidator {
    constructor(
        address defaultReverseRegistrarHCAAdapter,
        address reverseRegistrarHCAAdapter,
        address permittedResolverImpl,
        address ethRegistry,
        address verifiableFactory,
        address intentExecutor,
        address gasRefundPaymaster
    )
        HCAOwnerAndSessionValidator(
            defaultReverseRegistrarHCAAdapter,
            reverseRegistrarHCAAdapter,
            permittedResolverImpl,
            ethRegistry,
            verifiableFactory,
            intentExecutor,
            gasRefundPaymaster
        )
    {}

    function callArgsHarness(bytes memory callData) external pure returns (bytes memory) {
        return _callArgs(callData);
    }

    function isBatchRegistrarPaymentTokenHarness(bytes calldata operationData, address token)
        external
        view
        returns (bool)
    {
        return _isBatchRegistrarPaymentToken(operationData, token);
    }

    function recoverHarness(bytes32 digest, bytes calldata signature)
        external
        pure
        returns (address)
    {
        return _recover(digest, signature);
    }

    function checkRegistrationPolicyHarness(
        address account,
        address owner,
        address resolver,
        bytes calldata operationData
    )
        external
        view
    {
        _checkRegistrationPolicy(account, owner, resolver, operationData);
    }

    function checkInitialRegistrationPolicyHarness(
        address account,
        address owner,
        bytes32 permissionId,
        SessionEnableProof calldata proof,
        bytes calldata operationData,
        GasRefund calldata gasRefund
    )
        external
        view
    {
        _checkInitialRegistrationPolicy(
            account,
            owner,
            permissionId,
            proof,
            operationData,
            gasRefund
        );
    }

    function fundingCallIndexesHarness(
        Execution[] memory executions,
        address account,
        address owner,
        address token
    )
        external
        pure
        returns (uint256 permitIndex, uint256 transferIndex)
    {
        return _fundingCallIndexes(executions, account, owner, token);
    }

    function checkResolverBindingHarness(address resolver, bool usesResolver, bool deploysResolver)
        external
        view
    {
        _checkResolverBinding(
            resolver,
            RegistrationPolicyState({usesResolver: usesResolver, deploysResolver: deploysResolver, grantsOwnerResolverRoles: false})
        );
    }

    function operationHashHarness(bytes calldata operationData) external pure returns (bytes32) {
        return _operationHash(operationData);
    }

    function readUintHarness(bytes memory callData, uint256 offset) external pure returns (uint256) {
        return _readUint(callData, offset);
    }

    function singleChainDigestHarness(address account, uint256 nonce, bytes calldata operationData)
        external
        view
        returns (bytes32)
    {
        return _singleChainDigest(account, nonce, operationData, GasRefund(address(0), 0, 0));
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
        IAddressSet upgradeSet,
        IAddressSet predecessorUpgradeSet
    )
        StandaloneSingleOwnerHCA(
            entryPoint,
            defaultValidator,
            defaultExecutor,
            validatorInitData,
            upgradeSet,
            predecessorUpgradeSet
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


/// @title Owner Slot Writer
/// @notice Writes the standalone HCA owner slot in the active execution context.
contract OwnerSlotWriter {
    /// @notice Replaces the address stored in slot zero.
    /// @param replacementOwner The address to store.
    function writeOwner(address replacementOwner) external {
        assembly ("memory-safe") {
            sstore(0, replacementOwner)
        }
    }
}


/// @title HCA Primary-Name Adapter Interface
/// @notice Defines the adapter entry point used by the delegatecall exploit proof.
interface ISetNameWithHCA {
    /// @notice Sets an account's primary name through an HCA caller.
    /// @param account The account whose name changes.
    /// @param name The primary name.
    function setNameWithHCA(address account, string calldata name) external;
}


/// @title Owner Spoofing Payload
/// @notice Temporarily replaces the HCA owner while calling a vulnerable reverse adapter.
contract OwnerSpoofingPayload {
    /// @notice Impersonates an unrelated account for one nested adapter call.
    /// @param adapter The vulnerable HCA-aware adapter.
    /// @param victim The unrelated account whose reverse name changes.
    /// @param name The reverse name selected by the HCA owner.
    function spoofOwnerAndSetName(ISetNameWithHCA adapter, address victim, string calldata name)
        external
    {
        address originalOwner;
        assembly ("memory-safe") {
            originalOwner := sload(0)
            sstore(0, victim)
        }
        adapter.setNameWithHCA(victim, name);
        assembly ("memory-safe") {
            sstore(0, originalOwner)
        }
    }
}


/// @title Implementation-Trust-Only Default Adapter
/// @notice Reproduces HCA authorization that omits deployment provenance.
contract ImplementationTrustOnlyDefaultAdapter {
    DefaultReverseRegistrar internal immutable REGISTRAR;
    VerifiableFactory internal immutable VERIFIABLE_FACTORY;
    IAddressSet internal immutable TRUSTED_HCA_SET;

    /// @param registrar The reverse registrar updated by the adapter.
    /// @param verifiableFactory The factory queried for the caller's current implementation.
    /// @param trustedHCASet The implementation allowlist.
    constructor(
        DefaultReverseRegistrar registrar,
        VerifiableFactory verifiableFactory,
        IAddressSet trustedHCASet
    )
    {
        REGISTRAR = registrar;
        VERIFIABLE_FACTORY = verifiableFactory;
        TRUSTED_HCA_SET = trustedHCASet;
    }

    /// @notice Sets a reverse name after performing the vulnerable runtime checks.
    /// @param account The account whose name changes.
    /// @param name The reverse name to set.
    function setNameWithHCA(address account, string calldata name) external {
        address implementation = VERIFIABLE_FACTORY.verifyContract(msg.sender);
        require(TRUSTED_HCA_SET.includes(implementation));
        require(IStandaloneHCAOwner(msg.sender).owner() == account);
        REGISTRAR.setNameForAddr(account, name);
    }
}


/// @title Address Set Approval Interface
/// @notice Exposes the mutation used with production address-set deployments in these tests.
interface IAddressSetApproval is IAddressSet {
    /// @notice Adds or removes an address from the set.
    /// @param addr The address whose membership changes.
    /// @param approved Whether the address is included.
    function approve(address addr, bool approved) external;
}


/// @title Legacy Delegatecall HCA
/// @notice Test-only Nexus account retaining the vulnerable inherited execution paths.
contract LegacyDelegatecallHCA is Nexus {
    /// @notice The initialized owner.
    address public owner;

    /// @notice The fixed-session nonce reported to the validator.
    uint96 public sessionNonce;

    /// @param entryPoint_ ERC-4337 EntryPoint used by Nexus.
    /// @param defaultValidator_ Validator used for owner UserOperations.
    constructor(address entryPoint_, address defaultValidator_)
        Nexus(entryPoint_, defaultValidator_, address(0), "", "")
    {}

    /// @notice Initializes the account owner.
    /// @param initData ABI-encoded owner address.
    function initializeAccount(bytes calldata initData) external payable override {
        owner = abi.decode(initData, (address));
    }

    /// @notice Returns the owner and fixed-session nonce.
    /// @return owner_ The initialized owner.
    /// @return sessionNonce_ The current fixed-session nonce.
    function ownerAndSessionNonce() external view returns (address owner_, uint96 sessionNonce_) {
        return (owner, sessionNonce);
    }
}
