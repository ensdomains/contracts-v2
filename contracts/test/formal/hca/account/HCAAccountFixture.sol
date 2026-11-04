// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {IUUPSProxy} from "@ensdomains/verifiable-factory/IUUPSProxy.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {Execution} from "nexus/types/DataTypes.sol";
import {
    MODULE_TYPE_VALIDATOR,
    ERC1271_MAGICVALUE,
    VALIDATION_SUCCESS
} from "nexus/types/Constants.sol";

import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IStandaloneHCAFactory} from "~src/hca/interfaces/IStandaloneHCAFactory.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

import {DeployedIntentExecutor} from "../executor/DeployedIntentExecutor.sol";

/// @notice Mutable allowlist response boundary for account authorization proofs.
contract HCAFormalAddressSet is IAddressSet {
    mapping(address account => bool included) public includes;

    function set(address account, bool included) external {
        includes[account] = included;
    }
}


/// @notice Fixed validator responses isolate account dispatch from validator policy.
/// @dev Validator policy is verified separately against the production validator contracts.
contract HCAFormalValidatorResponse {
    error SignatureUnavailable();
    error UnexpectedSignatureInputs();

    uint256 public validationResult = VALIDATION_SUCCESS;
    uint256 public validations;
    bytes32 public lastHash;
    uint256 public lastNonce;
    address public lastAccount;
    bytes4 public signatureResult = ERC1271_MAGICVALUE;
    bool public signatureReverts;
    bool public enforceSignatureInputs;
    address public expectedSender;
    bytes32 public expectedHash;
    bytes32 public expectedSignatureHash;

    function onInstall(bytes calldata) external pure {}

    function onUninstall(bytes calldata) external pure {}

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }

    function configureValidation(uint256 result) external {
        validationResult = result;
    }

    function configureSignature(bytes4 result, bool reverts_) external {
        signatureResult = result;
        signatureReverts = reverts_;
    }

    function expectSignatureInputs(address sender, bytes32 digest, bytes memory signature) external {
        enforceSignatureInputs = true;
        expectedSender = sender;
        expectedHash = digest;
        expectedSignatureHash = keccak256(signature);
    }

    function validateUserOp(PackedUserOperation calldata operation, bytes32 digest)
        external
        returns (uint256)
    {
        ++validations;
        lastAccount = msg.sender;
        lastHash = digest;
        lastNonce = operation.nonce;
        return validationResult;
    }

    function isValidSignatureWithSender(address sender, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        if (signatureReverts)
            revert SignatureUnavailable();
        if (enforceSignatureInputs) {
            if (
                sender != expectedSender ||
                digest != expectedHash ||
                keccak256(signature) != expectedSignatureHash
            )
                revert UnexpectedSignatureInputs();
        }
        return signatureResult;
    }
}


/// @notice Explicit call target for successful, reverting, and reentrant execution traces.
contract HCAFormalCallTarget {
    uint256 public value;
    address public caller;
    uint256 public calls;
    bool public callbackSucceeded;

    error DeliberateFailure();

    function write(uint256 value_) external payable {
        value = value_;
        caller = msg.sender;
        ++calls;
    }

    function fail() external pure {
        revert DeliberateFailure();
    }

    function tryCallback(address account, bytes calldata data) external {
        caller = msg.sender;
        (callbackSucceeded, ) = account.call(data);
    }
}


/// @notice Symbolic certificate responses for the registry-mode account and authorizer boundary.
/// @dev Factory certification integrity is covered against the real StandaloneHCAFactory separately.
contract HCAFormalOwnerRegistry {
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;
    mapping(address account => address owner_) public hcaOwners;

    constructor(IVerifiableFactory factory_) {
        VERIFIABLE_FACTORY = factory_;
    }

    function certify(address account, address owner_) external {
        hcaOwners[account] = owner_;
    }

    function authorizedOwnerOf(address account) external view returns (address) {
        return hcaOwners[account];
    }
}


/// @notice Real Nexus account, VerifiableFactory clone, and UUPSProxyLogic fixture.
/// @dev Loads the real mainnet IntentExecutor proxy, implementation, and control slots.
///      Only fixed-validator responses and DAO address-set membership are modeled.
///      The ordinary account storage word is explicitly generalized, while module and proxy
///      storage retain their initialized values. Getter assertions detect layout drift.
abstract contract HCAAccountFixture is Test {
    address internal constant ENTRY_POINT = address(0x4337);
    address internal constant INITIAL_OWNER = address(0xA11CE);
    bytes32 internal constant OWNER_NONCE_SLOT = bytes32(uint256(0));

    HCAFormalValidatorResponse internal modules;
    address internal executor;
    HCAFormalAddressSet internal targetSet;
    HCAFormalAddressSet internal predecessorSet;
    VerifiableFactory internal proxyFactory;
    StandaloneSingleOwnerHCA internal implementation;
    StandaloneSingleOwnerHCA internal account;
    HCAFormalCallTarget internal firstTarget;
    HCAFormalCallTarget internal secondTarget;

    function setUp() public virtual {
        executor = DeployedIntentExecutor.install(false);
        modules = new HCAFormalValidatorResponse();
        targetSet = new HCAFormalAddressSet();
        predecessorSet = new HCAFormalAddressSet();
        proxyFactory = new VerifiableFactory();
        implementation = _implementation(IStandaloneHCAFactory(address(0)), predecessorSet);
        account = StandaloneSingleOwnerHCA(
            payable(
                proxyFactory.deployProxy(
                    address(implementation),
                    0,
                    abi.encodeCall(
                        StandaloneSingleOwnerHCA.initializeAccount,
                        (abi.encode(INITIAL_OWNER))
                    )
                )
            )
        );
        firstTarget = new HCAFormalCallTarget();
        secondTarget = new HCAFormalCallTarget();
    }

    function _implementation(IStandaloneHCAFactory registry, IAddressSet predecessors)
        internal
        returns (StandaloneSingleOwnerHCA)
    {
        return
            new StandaloneSingleOwnerHCA(
                ENTRY_POINT,
                address(modules),
                executor,
                "",
                targetSet,
                predecessors,
                registry
            );
    }

    function _seed(address owner_, uint96 nonce) internal {
        vm.assume(owner_ != address(0));
        vm.store(
            address(account),
            OWNER_NONCE_SLOT,
            bytes32(uint256(uint160(owner_)) | (uint256(nonce) << 160))
        );
        _assertState(owner_, nonce);
    }

    function _assertState(address owner_, uint96 nonce) internal view {
        (address actualOwner, uint96 actualNonce) = account.ownerAndSessionNonce();
        assert(actualOwner == owner_);
        assert(account.owner() == owner_);
        assert(actualNonce == nonce);
    }

    function _implementationOf(address proxy) internal view returns (address impl) {
        (, impl) = IUUPSProxy(proxy).getVerifiableProxyData();
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
        }
    }

    function _assertRevert(bool ok, bytes memory data, bytes4 selector) internal pure {
        assert(!ok);
        assert(_selector(data) == selector);
    }

    function _writeCall(HCAFormalCallTarget target, uint256 value_)
        internal
        pure
        returns (Execution memory)
    {
        return Execution(address(target), 0, abi.encodeCall(HCAFormalCallTarget.write, (value_)));
    }
}
