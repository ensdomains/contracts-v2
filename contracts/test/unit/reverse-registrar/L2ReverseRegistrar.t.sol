// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file, namechain/import-order-separation, gas-small-strings, gas-strict-inequalities, gas-increment-by-one, gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {MockSmartContractWallet} from "@ens/contracts/test/mocks/MockSmartContractWallet.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";
import {MockERC6492WalletFactory} from "@ens/contracts/test/mocks/MockERC6492WalletFactory.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {
    L2ReverseRegistrar,
    IL2ReverseRegistrar,
    IContractName,
    LibISO8601,
    LibString
} from "~src/reverse-registrar/L2ReverseRegistrar.sol";

contract L2ReverseRegistrarTest is Test {
    using MessageHashUtils for bytes;
    using Strings for uint256;
    using Strings for address;

    // Constants matching Optimism chain setup
    uint256 constant OPTIMISM_CHAIN_ID = 10;
    // Coin type format: 0x80000000 | chainId (see ENSIP-11)
    uint256 constant COIN_TYPE = 0x80000000 | OPTIMISM_CHAIN_ID;
    string constant COIN_TYPE_LABEL = "8000000a";
    string constant PARENT_NAMESPACE = "8000000a.reverse";

    bytes32 constant REVERSE_NODE =
        0xa097f6721ce401e757d1223a763fef49b8b5f90bb18567ddb86fd205dff71d34;

    L2ReverseRegistrar registrar;
    MockSmartContractWallet mockSca;
    MockERC6492WalletFactory mockErc6492Factory;
    MockOwnable mockOwnableEoa;
    MockOwnable mockOwnableSca;

    // Test accounts
    uint256 user1Pk = 0x1;
    uint256 user2Pk = 0x2;
    address user1;
    address user2;
    address relayer;

    function setUp() public {
        // Deploy Universal Signature Validator at the expected address
        _deployUniversalSigValidator();

        user1 = vm.addr(user1Pk);
        user2 = vm.addr(user2Pk);
        relayer = makeAddr("relayer");

        // Deploy the L2ReverseRegistrar
        registrar = new L2ReverseRegistrar(OPTIMISM_CHAIN_ID, COIN_TYPE_LABEL);

        // Deploy mock contracts
        mockSca = new MockSmartContractWallet(user1);
        mockErc6492Factory = new MockERC6492WalletFactory();
        mockOwnableEoa = new MockOwnable(user1);
        mockOwnableSca = new MockOwnable(address(mockSca));
    }

    function _deployUniversalSigValidator() internal {
        // Deploy the actual UniversalSigValidator at the expected address
        // Bytecode from: contracts/test/integration/fixtures/deployUniversalSigValidator.ts
        address expectedAddress = 0x164af34fAF9879394370C7f09064127C043A35E9;

        // Use vm.etch with the runtime bytecode of the UniversalSigValidator
        // This bytecode is extracted from the deployment in the TypeScript fixture
        bytes
            memory runtimeCode = hex"608060405234801561001057600080fd5b50600436106100415760003560e01c806316d43401146100465780638f0684301461006d57806398ef1ed814610080575b600080fd5b61005961005436600461085e565b610093565b604051901515815260200160405180910390f35b61005961007b3660046108d2565b6105f8565b61005961008e3660046108d2565b61068e565b600073ffffffffffffffffffffffffffffffffffffffff86163b6060826020861080159061010157507f649264926492649264926492649264926492649264926492649264926492649287876100ea60208261092e565b6100f6928a929061096e565b6100ff91610998565b145b90508015610200576000606088828961011b60208261092e565b926101289392919061096e565b8101906101359190610acf565b9550909250905060008590036101f9576000808373ffffffffffffffffffffffffffffffffffffffff168360405161016d9190610b6e565b6000604051808303816000865af19150503d80600081146101aa576040519150601f19603f3d011682016040523d82523d6000602084013e6101af565b606091505b5091509150816101f657806040517f9d0d6e2d0000000000000000000000000000000000000000000000000000000081526004016101ed9190610bd4565b60405180910390fd5b50505b505061023a565b86868080601f0160208091040260200160405190810160405280939291908181526020018383808284376000920191909152509294505050505b80806102465750600083115b156103d3576040517f1626ba7e00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8a1690631626ba7e9061029f908b908690600401610bee565b602060405180830381865afa9250505080156102f6575060408051601f3d9081017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe01682019092526102f391810190610c07565b60015b61035e573d808015610324576040519150601f19603f3d011682016040523d82523d6000602084013e610329565b606091505b50806040517f6f2a95990000000000000000000000000000000000000000000000000000000081526004016101ed9190610bd4565b7fffffffff0000000000000000000000000000000000000000000000000000000081167f1626ba7e0000000000000000000000000000000000000000000000000000000014841580156103ae5750825b80156103b8575086155b156103c757806000526001601ffd5b94506105ef9350505050565b60418614610463576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152603a60248201527f5369676e617475726556616c696461746f72237265636f7665725369676e657260448201527f3a20696e76616c6964207369676e6174757265206c656e67746800000000000060648201526084016101ed565b6000610472602082898b61096e565b61047b91610998565b9050600061048d604060208a8c61096e565b61049691610998565b90506000898960408181106104ad576104ad610c49565b919091013560f81c915050601b81148015906104cd57508060ff16601c14155b1561055a576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152602d60248201527f5369676e617475726556616c696461746f723a20696e76616c6964207369676e60448201527f617475726520762076616c75650000000000000000000000000000000000000060648201526084016101ed565b6040805160008152602081018083528d905260ff831691810191909152606081018490526080810183905273ffffffffffffffffffffffffffffffffffffffff8d169060019060a0016020604051602081039080840390855afa1580156105c5573d6000803e3d6000fd5b5050506020604051035173ffffffffffffffffffffffffffffffffffffffff161496505050505050505b95945050505050565b6040517f16d4340100000000000000000000000000000000000000000000000000000000815260009030906316d4340190610640908890889088908890600190600401610c78565b6020604051808303816000875af115801561065f573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906106839190610cf5565b90505b949350505050565b6040517f16d4340100000000000000000000000000000000000000000000000000000000815260009030906316d43401906106d59088908890889088908890600401610c78565b6020604051808303816000875af192505050801561072e575060408051601f3d9081017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe016820190925261072b91810190610cf5565b60015b6107db573d80801561075c576040519150601f19603f3d011682016040523d82523d6000602084013e610761565b606091505b50805160018190036107d4578160008151811061078057610780610c49565b6020910101517fff00000000000000000000000000000000000000000000000000000000000000167f0100000000000000000000000000000000000000000000000000000000000000149250610686915050565b8060208301fd5b9050610686565b73ffffffffffffffffffffffffffffffffffffffff8116811461080457600080fd5b50565b60008083601f84011261081957600080fd5b50813567ffffffffffffffff81111561083157600080fd5b60208301915083602082850101111561084957600080fd5b9250929050565b801515811461080457600080fd5b60008060008060006080868803121561087657600080fd5b8535610881816107e2565b945060208601359350604086013567ffffffffffffffff8111156108a457600080fd5b6108b088828901610807565b90945092505060608601356108c481610850565b809150509295509295909350565b600080600080606085870312156108e857600080fd5b84356108f3816107e2565b935060208501359250604085013567ffffffffffffffff81111561091657600080fd5b61092287828801610807565b95989497509550505050565b81810381811115610968577f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b92915050565b6000808585111561097e57600080fd5b8386111561098b57600080fd5b5050820193919092039150565b80356020831015610968577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff602084900360031b1b1692915050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b600082601f830112610a1457600080fd5b813567ffffffffffffffff811115610a2e57610a2e6109d4565b6040517fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0603f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f8501160116810181811067ffffffffffffffff82111715610a9a57610a9a6109d4565b604052818152838201602001851015610ab257600080fd5b816020850160208301376000918101602001919091529392505050565b600080600060608486031215610ae457600080fd5b8335610aef816107e2565b9250602084013567ffffffffffffffff811115610b0b57600080fd5b610b1786828701610a03565b925050604084013567ffffffffffffffff811115610b3457600080fd5b610b4086828701610a03565b9150509250925092565b60005b83811015610b65578181015183820152602001610b4d565b50506000910152565b60008251610b80818460208701610b4a565b9190910192915050565b60008151808452610ba2816020860160208601610b4a565b601f017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0169290920160200192915050565b602081526000610be76020830184610b8a565b9392505050565b8281526040602082015260006106866040830184610b8a565b600060208284031215610c1957600080fd5b81517fffffffff0000000000000000000000000000000000000000000000000000000081168114610be757600080fd5b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b73ffffffffffffffffffffffffffffffffffffffff8616815284602082015260806040820152826080820152828460a0830137600060a08483010152600060a07fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f860116830101905082151560608301529695505050505050565b600060208284031215610d0757600080fd5b8151610be78161085056fea2646970667358221220fa1669652244780c8dcf7823a819ca1aa2abb64af0cf4d7adedb2339d4e907d964736f6c634300081a0033";
        vm.etch(expectedAddress, runtimeCode);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helper Functions
    ////////////////////////////////////////////////////////////////////////

    function _getNode(address addr) internal view returns (bytes32) {
        string memory label = LibString.toAddressString(addr);
        return
            keccak256(
                abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
            );
    }

    function _buildDnsEncodedName(address addr) internal pure returns (bytes memory) {
        string memory addrString = LibString.toAddressString(addr);
        bytes memory parent = abi.encodePacked(
            uint8(bytes(COIN_TYPE_LABEL).length),
            COIN_TYPE_LABEL,
            uint8(7),
            "reverse",
            uint8(0)
        );
        return abi.encodePacked(uint8(40), addrString, parent);
    }

    function _chainIdsToString(uint256[] memory chainIds) internal pure returns (string memory) {
        string memory result = "";
        for (uint256 i = 0; i < chainIds.length; i++) {
            result = string.concat(result, chainIds[i].toString());
            if (i < chainIds.length - 1) result = string.concat(result, ", ");
        }
        return result;
    }

    function _createNameForAddrMessage(
        string memory name_,
        address addr,
        uint256[] memory chainIds,
        uint256 signedAt
    ) internal view returns (bytes32) {
        string memory addrString = addr.toChecksumHexString();
        string memory chainIdsString = _chainIdsToString(chainIds);
        string memory signedAtString = LibISO8601.toISO8601(signedAt);

        return
            abi
                .encodePacked(
                    "You are setting your ENS primary name to:\n",
                    name_,
                    "\n\nAddress: ",
                    addrString,
                    "\nChains: ",
                    chainIdsString,
                    "\nSigned At: ",
                    signedAtString
                )
                .toEthSignedMessageHash();
    }

    function _createNameForOwnableMessage(
        string memory name_,
        address contractAddress,
        address owner,
        uint256[] memory chainIds,
        uint256 signedAt
    ) internal view returns (bytes32) {
        string memory addrString = contractAddress.toChecksumHexString();
        string memory ownerString = owner.toChecksumHexString();
        string memory chainIdsString = _chainIdsToString(chainIds);
        string memory signedAtString = LibISO8601.toISO8601(signedAt);

        return
            abi
                .encodePacked(
                    "You are setting the ENS primary name for a contract you own to:\n",
                    name_,
                    "\n\nContract Address: ",
                    addrString,
                    "\nOwner: ",
                    ownerString,
                    "\nChains: ",
                    chainIdsString,
                    "\nSigned At: ",
                    signedAtString
                )
                .toEthSignedMessageHash();
    }

    function _singleChainIdArray() internal pure returns (uint256[] memory) {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        return chainIds;
    }

    function _multipleChainIdArray() internal pure returns (uint256[] memory) {
        uint256[] memory chainIds = new uint256[](4);
        chainIds[0] = 1; // ETH
        chainIds[1] = OPTIMISM_CHAIN_ID; // Optimism (10)
        chainIds[2] = 8453; // Base
        chainIds[3] = 42161; // Arbitrum
        // Must be in ascending order: 1, 10, 8453, 42161
        return chainIds;
    }

    function _unsortedChainIdArray() internal pure returns (uint256[] memory) {
        uint256[] memory chainIds = new uint256[](4);
        chainIds[0] = 1; // ETH
        chainIds[1] = 42161; // Arbitrum
        chainIds[2] = OPTIMISM_CHAIN_ID; // Optimism (10) - out of order
        chainIds[3] = 8453; // Base
        return chainIds;
    }

    function _duplicateChainIdArray() internal pure returns (uint256[] memory) {
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 1; // ETH
        chainIds[1] = OPTIMISM_CHAIN_ID; // Optimism
        chainIds[2] = OPTIMISM_CHAIN_ID; // Duplicate
        return chainIds;
    }

    function _chainIdArrayWithoutOptimism() internal pure returns (uint256[] memory) {
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 1; // ETH
        chainIds[1] = 8453; // Base
        chainIds[2] = 42161; // Arbitrum
        // Ascending order: 1, 8453, 42161 (does not include Optimism's chain ID 10)
        return chainIds;
    }

    function _emptyChainIdArray() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _largeChainIdArray(uint256 length) internal pure returns (uint256[] memory) {
        uint256[] memory chainIds = new uint256[](length);
        for (uint256 i = 1; i < length; i++) {
            chainIds[i] = i;
        }
        return chainIds;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constructor / Immutables Tests
    ////////////////////////////////////////////////////////////////////////

    function test_constructor_setChainId() public view {
        assertEq(registrar.CHAIN_ID(), OPTIMISM_CHAIN_ID, "CHAIN_ID should match");
    }

    function test_constructor_setParentNode() public view {
        bytes32 expectedParentNode = keccak256(
            abi.encodePacked(REVERSE_NODE, keccak256(abi.encodePacked(COIN_TYPE_LABEL)))
        );
        assertEq(registrar.PARENT_NODE(), expectedParentNode, "PARENT_NODE should match");
    }

    ////////////////////////////////////////////////////////////////////////
    // supportsInterface Tests
    ////////////////////////////////////////////////////////////////////////

    function test_supportsInterface_erc165() public view {
        assertTrue(ERC165Checker.supportsERC165(address(registrar)), "Should support ERC165");
    }

    function test_supportsInterface_extendedResolver() public view {
        assertTrue(
            registrar.supportsInterface(type(IExtendedResolver).interfaceId),
            "Should support IExtendedResolver"
        );
    }

    function test_supportsInterface_nameResolver() public view {
        assertTrue(
            registrar.supportsInterface(type(INameResolver).interfaceId),
            "Should support INameResolver"
        );
    }

    function test_supportsInterface_ierc165() public view {
        assertTrue(
            registrar.supportsInterface(type(IERC165).interfaceId),
            "Should support IERC165"
        );
    }

    function test_supportsInterface_il2ReverseRegistrar() public view {
        assertTrue(
            registrar.supportsInterface(type(IL2ReverseRegistrar).interfaceId),
            "Should support IL2ReverseRegistrar"
        );
    }

    function test_supportsInterface_invalidInterface() public view {
        assertFalse(
            registrar.supportsInterface(bytes4(0xdeadbeef)),
            "Should not support random interface"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // setName Tests
    ////////////////////////////////////////////////////////////////////////

    function test_setName_setsNameRecord() public {
        string memory name_ = "myname.eth";

        vm.prank(user1);
        registrar.setName(name_);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set");
    }

    function test_setName_emitsNameChangedEvent() public {
        string memory name_ = "myname.eth";
        bytes32 expectedNode = _getNode(user1);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(expectedNode, name_);
        registrar.setName(name_);
    }

    function test_setName_canUpdateNameRecord() public {
        string memory firstName = "first.eth";
        string memory secondName = "second.eth";

        vm.startPrank(user1);
        registrar.setName(firstName);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), firstName, "First name should be set");

        registrar.setName(secondName);
        assertEq(registrar.name(node), secondName, "Name should be updated");
        vm.stopPrank();
    }

    function test_setName_canSetToEmptyString() public {
        string memory name_ = "myname.eth";

        vm.startPrank(user1);
        registrar.setName(name_);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set");

        registrar.setName("");
        assertEq(registrar.name(node), "", "Name should be empty");
        vm.stopPrank();
    }

    function testFuzz_setName(address addr, string memory name_) public {
        vm.assume(addr != address(0));

        vm.prank(addr);
        registrar.setName(name_);

        bytes32 node = _getNode(addr);
        assertEq(registrar.name(node), name_, "Name should be set");
    }

    ////////////////////////////////////////////////////////////////////////
    // setNameForAddr Tests
    ////////////////////////////////////////////////////////////////////////

    function test_setNameForAddr_setsNameForOwnedContract() public {
        string memory name_ = "myname.eth";

        vm.prank(user1);
        registrar.setNameForAddr(address(mockOwnableEoa), name_);

        bytes32 node = _getNode(address(mockOwnableEoa));
        assertEq(registrar.name(node), name_, "Name should be set for contract");
    }

    function test_setNameForAddr_emitsNameChangedEvent() public {
        string memory name_ = "myname.eth";
        bytes32 expectedNode = _getNode(address(mockOwnableEoa));

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(expectedNode, name_);
        registrar.setNameForAddr(address(mockOwnableEoa), name_);
    }

    function test_setNameForAddr_callerCanSetOwnName() public {
        string memory name_ = "myname.eth";

        vm.prank(user1);
        registrar.setNameForAddr(user1, name_);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set for caller");
    }

    function test_setNameForAddr_revert_callerNotOwnerOfTargetAddress() public {
        string memory name_ = "myname.eth";

        vm.prank(user2);
        vm.expectRevert(L2ReverseRegistrar.Unauthorized.selector);
        registrar.setNameForAddr(address(mockOwnableEoa), name_);
    }

    function test_setNameForAddr_revert_callerTriesToSetNameForAnotherEOA() public {
        string memory name_ = "myname.eth";

        vm.prank(user1);
        vm.expectRevert(L2ReverseRegistrar.Unauthorized.selector);
        registrar.setNameForAddr(user2, name_);
    }

    function test_setNameForAddr_revert_callerNotOwnerOfTargetContractViaOwnable() public {
        string memory name_ = "myname.eth";

        // mockOwnableSca is owned by mockSca, not user1
        vm.prank(user1);
        vm.expectRevert(L2ReverseRegistrar.Unauthorized.selector);
        registrar.setNameForAddr(address(mockOwnableSca), name_);
    }

    ////////////////////////////////////////////////////////////////////////
    // setNameForAddrWithSignature Tests
    ////////////////////////////////////////////////////////////////////////

    function test_setNameForAddrWithSignature_allowsRelayerToClaim() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set via signature");
    }

    function test_setNameForAddrWithSignature_emitsNameChangedEvent() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        bytes32 expectedNode = _getNode(user1);

        vm.prank(relayer);
        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(expectedNode, name_);
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_allowsScaSignaturesERC1271() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, address(mockSca), chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockSca),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(address(mockSca));
        assertEq(registrar.name(node), name_, "Name should be set for SCA");
    }

    function test_setNameForAddrWithSignature_allowsUndeployedScaSignaturesERC6492() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;

        address predictedAddress = mockErc6492Factory.predictAddress(user1);
        bytes memory wrappedSignature = _createErc6492Signature(name_, predictedAddress, signedAt);

        uint256[] memory chainIds = _singleChainIdArray();
        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: predictedAddress,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, wrappedSignature);

        bytes32 node = _getNode(predictedAddress);
        assertEq(registrar.name(node), name_, "Name should be set for undeployed SCA");
    }

    function _createErc6492Signature(
        string memory name_,
        address predictedAddress,
        uint256 signedAt
    ) internal view returns (bytes memory) {
        uint256[] memory chainIds = _singleChainIdArray();
        bytes32 message = _createNameForAddrMessage(name_, predictedAddress, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory originalSignature = abi.encodePacked(r, s, v);

        bytes memory factoryCallData = abi.encodeCall(mockErc6492Factory.createWallet, (user1));
        bytes32 ERC6492_DETECTION_SUFFIX = 0x6492649264926492649264926492649264926492649264926492649264926492;

        // ERC6492 format: abi.encode(factory, factoryCallData, originalSignature) ++ suffix
        return
            abi.encodePacked(
                abi.encode(address(mockErc6492Factory), factoryCallData, originalSignature),
                ERC6492_DETECTION_SUFFIX
            );
    }

    function test_setNameForAddrWithSignature_revert_signatureParametersDoNotMatch() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Sign with different name
        bytes32 message = _createNameForAddrMessage("different.eth", user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.InvalidSignature.selector);
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_revert_signedAtInFuture() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp + 1; // In the future
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                L2ReverseRegistrar.SignatureNotValidYet.selector,
                signedAt,
                block.timestamp
            )
        );
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_revert_signedAtNotAfterInception() public {
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // First, set a name to establish an inception
        {
            bytes32 message = _createNameForAddrMessage("myname.eth", user1, chainIds, signedAt);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "myname.eth",
                addr: user1,
                chainIds: chainIds,
                signedAt: signedAt
            });

            vm.prank(relayer);
            registrar.setNameForAddrWithSignature(claim, abi.encodePacked(r, s, v));
        }

        // Now try to use a signature with signedAt equal to the inception (should fail)
        {
            bytes32 message = _createNameForAddrMessage("newname.eth", user1, chainIds, signedAt);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "newname.eth",
                addr: user1,
                chainIds: chainIds,
                signedAt: signedAt
            });

            vm.prank(relayer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    L2ReverseRegistrar.StaleSignature.selector,
                    signedAt,
                    signedAt
                )
            );
            registrar.setNameForAddrWithSignature(claim, abi.encodePacked(r, s, v));
        }
    }

    function test_setNameForAddrWithSignature_allowsMultipleChainIds() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _multipleChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set with multiple chain IDs");
    }

    function test_setNameForAddrWithSignature_allowsLargeChainIdArray_25() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _largeChainIdArray(25);

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set with large chain ID array");
    }

    function test_setNameForAddrWithSignature_allowsLargeChainIdArray_50() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _largeChainIdArray(50);

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set with large chain ID array");
    }

    function test_setNameForAddrWithSignature_allowsLargeChainIdArray_100() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _largeChainIdArray(100);

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set with large chain ID array");
    }

    function test_setNameForAddrWithSignature_allowsLargeChainIdArray_200() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _largeChainIdArray(200);

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), name_, "Name should be set with large chain ID array");
    }

    function test_setNameForAddrWithSignature_revert_currentChainIdNotInArray() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _chainIdArrayWithoutOptimism();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                L2ReverseRegistrar.CurrentChainNotFound.selector,
                OPTIMISM_CHAIN_ID
            )
        );
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_revert_emptyChainIdArray() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _emptyChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                L2ReverseRegistrar.CurrentChainNotFound.selector,
                OPTIMISM_CHAIN_ID
            )
        );
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_revert_chainIdsNotAscending() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _unsortedChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.ChainIdsNotAscending.selector);
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_revert_duplicateChainIds() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _duplicateChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.ChainIdsNotAscending.selector);
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_revert_replayProtection() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        // First call should succeed
        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        // Second call should fail (same signedAt is not after inception)
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(L2ReverseRegistrar.StaleSignature.selector, signedAt, signedAt)
        );
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    function test_setNameForAddrWithSignature_allowsNewerSignature() public {
        uint256 signedAt1 = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // First signature
        {
            bytes32 message = _createNameForAddrMessage("first.eth", user1, chainIds, signedAt1);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "first.eth",
                addr: user1,
                chainIds: chainIds,
                signedAt: signedAt1
            });

            vm.prank(relayer);
            registrar.setNameForAddrWithSignature(claim, abi.encodePacked(r, s, v));
        }

        // Advance time and use a newer signature
        vm.warp(block.timestamp + 100);
        uint256 signedAt2 = block.timestamp;

        {
            bytes32 message = _createNameForAddrMessage("second.eth", user1, chainIds, signedAt2);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "second.eth",
                addr: user1,
                chainIds: chainIds,
                signedAt: signedAt2
            });

            vm.prank(relayer);
            registrar.setNameForAddrWithSignature(claim, abi.encodePacked(r, s, v));
        }

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "second.eth", "Name should be updated to second");
    }

    function test_setNameForAddrWithSignature_revert_olderSignatureAfterNewerUsed() public {
        uint256 signedAt1 = block.timestamp + 100; // Newer timestamp
        uint256 signedAt2 = block.timestamp; // Older timestamp
        uint256[] memory chainIds = _singleChainIdArray();

        // Use the newer signature first
        vm.warp(block.timestamp + 100);
        {
            bytes32 message = _createNameForAddrMessage("first.eth", user1, chainIds, signedAt1);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "first.eth",
                addr: user1,
                chainIds: chainIds,
                signedAt: signedAt1
            });

            vm.prank(relayer);
            registrar.setNameForAddrWithSignature(claim, abi.encodePacked(r, s, v));
        }

        // Try to use the older signature (should fail)
        {
            bytes32 message = _createNameForAddrMessage("second.eth", user1, chainIds, signedAt2);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "second.eth",
                addr: user1,
                chainIds: chainIds,
                signedAt: signedAt2
            });

            vm.prank(relayer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    L2ReverseRegistrar.StaleSignature.selector,
                    signedAt2,
                    signedAt1
                )
            );
            registrar.setNameForAddrWithSignature(claim, abi.encodePacked(r, s, v));
        }
    }

    function test_setNameForAddrWithSignature_updatesInception() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Check initial inception is 0
        assertEq(registrar.inceptionOf(user1), 0, "Initial inception should be 0");

        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForAddrWithSignature(claim, signature);

        // Check inception is updated
        assertEq(registrar.inceptionOf(user1), signedAt, "Inception should be updated to signedAt");
    }

    function test_setNameForAddrWithSignature_revert_signedByWrongAccount() public {
        string memory name_ = "myname.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Sign with user2 but claim is for user1
        bytes32 message = _createNameForAddrMessage(name_, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user1,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.InvalidSignature.selector);
        registrar.setNameForAddrWithSignature(claim, signature);
    }

    ////////////////////////////////////////////////////////////////////////
    // setNameForOwnableWithSignature Tests
    ////////////////////////////////////////////////////////////////////////

    function test_setNameForOwnableWithSignature_allowsEoaOwner() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);

        bytes32 node = _getNode(address(mockOwnableEoa));
        assertEq(registrar.name(node), name_, "Name should be set for ownable contract");
    }

    function test_setNameForOwnableWithSignature_allowsScaOwner() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // mockOwnableSca is owned by mockSca, which is owned by user1
        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableSca),
            address(mockSca),
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableSca),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForOwnableWithSignature(claim, address(mockSca), signature);

        bytes32 node = _getNode(address(mockOwnableSca));
        assertEq(registrar.name(node), name_, "Name should be set for ownable contract via SCA");
    }

    function test_setNameForOwnableWithSignature_revert_ownerAddressNotOwnerOfContract() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Sign with user2 and claim they own mockOwnableEoa (which is owned by user1)
        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user2,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.NotOwnerOfContract.selector);
        registrar.setNameForOwnableWithSignature(claim, user2, signature);
    }

    function test_setNameForOwnableWithSignature_revert_targetAddressIsEOA() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Try to claim for EOA user2 saying user1 owns it
        bytes32 message = _createNameForOwnableMessage(name_, user2, user1, chainIds, signedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: user2,
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.NotOwnerOfContract.selector);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_targetDoesNotImplementOwnable() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // L2ReverseRegistrar itself does not implement Ownable
        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(registrar),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(registrar),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.NotOwnerOfContract.selector);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_invalidSignature() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Sign with different name to create invalid signature
        bytes32 message = _createNameForOwnableMessage(
            "different.eth",
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.InvalidSignature.selector);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_signedAtInFuture() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp + 1; // In the future
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                L2ReverseRegistrar.SignatureNotValidYet.selector,
                signedAt,
                block.timestamp
            )
        );
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_signedAtNotAfterInception() public {
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // First, set a name to establish an inception
        {
            bytes32 message = _createNameForOwnableMessage(
                "ownable.eth",
                address(mockOwnableEoa),
                user1,
                chainIds,
                signedAt
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "ownable.eth",
                addr: address(mockOwnableEoa),
                chainIds: chainIds,
                signedAt: signedAt
            });

            vm.prank(relayer);
            registrar.setNameForOwnableWithSignature(claim, user1, abi.encodePacked(r, s, v));
        }

        // Now try to use a signature with signedAt equal to the inception (should fail)
        {
            bytes32 message = _createNameForOwnableMessage(
                "newname.eth",
                address(mockOwnableEoa),
                user1,
                chainIds,
                signedAt
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);

            IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
                name: "newname.eth",
                addr: address(mockOwnableEoa),
                chainIds: chainIds,
                signedAt: signedAt
            });

            vm.prank(relayer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    L2ReverseRegistrar.StaleSignature.selector,
                    signedAt,
                    signedAt
                )
            );
            registrar.setNameForOwnableWithSignature(claim, user1, abi.encodePacked(r, s, v));
        }
    }

    function test_setNameForOwnableWithSignature_allowsMultipleChainIds() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _multipleChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);

        bytes32 node = _getNode(address(mockOwnableEoa));
        assertEq(registrar.name(node), name_, "Name should be set with multiple chain IDs");
    }

    function test_setNameForOwnableWithSignature_allowsLargeChainIdArray() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _largeChainIdArray(50);

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);

        bytes32 node = _getNode(address(mockOwnableEoa));
        assertEq(registrar.name(node), name_, "Name should be set with large chain ID array");
    }

    function test_setNameForOwnableWithSignature_revert_currentChainIdNotInArray() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _chainIdArrayWithoutOptimism();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                L2ReverseRegistrar.CurrentChainNotFound.selector,
                OPTIMISM_CHAIN_ID
            )
        );
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_emptyChainIdArray() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _emptyChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                L2ReverseRegistrar.CurrentChainNotFound.selector,
                OPTIMISM_CHAIN_ID
            )
        );
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_chainIdsNotAscending() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _unsortedChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.ChainIdsNotAscending.selector);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_duplicateChainIds() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _duplicateChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        vm.expectRevert(L2ReverseRegistrar.ChainIdsNotAscending.selector);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_revert_replayProtection() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        // First call should succeed
        vm.prank(relayer);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);

        // Second call should fail (same signedAt is not after inception)
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(L2ReverseRegistrar.StaleSignature.selector, signedAt, signedAt)
        );
        registrar.setNameForOwnableWithSignature(claim, user1, signature);
    }

    function test_setNameForOwnableWithSignature_updatesInception() public {
        string memory name_ = "ownable.eth";
        uint256 signedAt = block.timestamp;
        uint256[] memory chainIds = _singleChainIdArray();

        // Check initial inception is 0
        assertEq(
            registrar.inceptionOf(address(mockOwnableEoa)),
            0,
            "Initial inception should be 0"
        );

        bytes32 message = _createNameForOwnableMessage(
            name_,
            address(mockOwnableEoa),
            user1,
            chainIds,
            signedAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1Pk, message);
        bytes memory signature = abi.encodePacked(r, s, v);

        IL2ReverseRegistrar.NameClaim memory claim = IL2ReverseRegistrar.NameClaim({
            name: name_,
            addr: address(mockOwnableEoa),
            chainIds: chainIds,
            signedAt: signedAt
        });

        vm.prank(relayer);
        registrar.setNameForOwnableWithSignature(claim, user1, signature);

        // Check inception is updated
        assertEq(
            registrar.inceptionOf(address(mockOwnableEoa)),
            signedAt,
            "Inception should be updated to signedAt"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // syncName() Tests
    ////////////////////////////////////////////////////////////////////////

    function test_syncName() external {
        string memory name = "mycontract.eth";
        address addr = address(new MockContractName(name));
        assertEq(registrar.nameForAddr(addr), "", "before");
        vm.prank(makeAddr("anyone"));
        registrar.syncName(addr);
        assertEq(registrar.nameForAddr(addr), name, "after");
    }

    function test_syncName_empty() external {
        string memory name = "mycontract.eth";
        address addr = address(new MockContractName(""));
        vm.prank(addr);
        registrar.setName(name);
        assertEq(registrar.nameForAddr(addr), name, "before");
        registrar.syncName(addr);
        assertEq(registrar.nameForAddr(addr), "", "after");
    }

    function test_syncName_notContract() external {
        vm.expectRevert();
        registrar.syncName(makeAddr("dne"));
    }

    function test_syncName_notImplemented() external {
        vm.expectRevert();
        registrar.syncName(address(this));
    }

    ////////////////////////////////////////////////////////////////////////
    // name() Tests (reading reverse records)
    ////////////////////////////////////////////////////////////////////////

    function test_name_returnsEmptyForUnsetAddress() public view {
        bytes32 node = _getNode(user2);
        assertEq(registrar.name(node), "", "Should return empty for unset address");
    }

    function test_name_returnsSetName() public {
        string memory expectedName = "vitalik.eth";

        vm.prank(user1);
        registrar.setName(expectedName);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), expectedName, "Should return set name");
    }

    ////////////////////////////////////////////////////////////////////////
    // resolve() Tests
    ////////////////////////////////////////////////////////////////////////

    function test_resolve_canResolveNameForAddress() public {
        string memory expectedName = "test.eth";

        vm.prank(user1);
        registrar.setName(expectedName);

        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory decodedName = abi.decode(result, (string));
        assertEq(decodedName, expectedName, "Resolved name should match");
    }

    function test_resolve_returnsEmptyForUnsetAddress() public view {
        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory decodedName = abi.decode(result, (string));
        assertEq(decodedName, "", "Should return empty for unset address");
    }

    function testFuzz_resolve_differentAddresses(address addr, string memory expectedName) public {
        vm.assume(addr != address(0));

        vm.prank(addr);
        registrar.setName(expectedName);

        bytes memory dnsEncodedName = _buildDnsEncodedName(addr);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory decodedName = abi.decode(result, (string));
        assertEq(decodedName, expectedName, "Should return correct name");
    }

    ////////////////////////////////////////////////////////////////////////
    // Integration Tests
    ////////////////////////////////////////////////////////////////////////

    function test_fullFlow_setAndResolve() public {
        string memory expectedName = "integration.eth";

        vm.prank(user1);
        registrar.setName(expectedName);

        // Resolve via resolve()
        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory resolvedName = abi.decode(result, (string));
        assertEq(resolvedName, expectedName, "Resolved name should match");

        // Also verify via direct name() call
        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), expectedName, "Direct name() should match");
    }

    function test_multipleUsers() public {
        string memory name1 = "user1.eth";
        string memory name2 = "user2.eth";

        vm.prank(user1);
        registrar.setName(name1);

        vm.prank(user2);
        registrar.setName(name2);

        bytes32 node1 = _getNode(user1);
        bytes32 node2 = _getNode(user2);

        assertEq(registrar.name(node1), name1, "User1 name should match");
        assertEq(registrar.name(node2), name2, "User2 name should match");
    }
}

contract MockContractName is IContractName {
    string public ensContractName;
    constructor(string memory name) {
        ensContractName = name;
    }
}
