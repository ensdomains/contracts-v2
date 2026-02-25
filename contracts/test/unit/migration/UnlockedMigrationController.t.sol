// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test, Vm} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UnauthorizedCaller} from "~src/CommonErrors.sol";
import {
    PermissionedRegistry,
    IPermissionedRegistry,
    RegistryRolesLib,
    IRegistryMetadata,
    EACBaseRolesLib
} from "~src/registry/PermissionedRegistry.sol";
import {UnlockedMigrationController} from "~src/migration/UnlockedMigrationController.sol";
import {TransferData, MigrationData} from "~src/migration/types/MigrationTypes.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";
import {MockBaseRegistrar} from "~test/mocks/v1/MockBaseRegistrar.sol";

// Simple mock that implements IRegistryMetadata
contract MockRegistryMetadata is IRegistryMetadata {
    function tokenUri(uint256) external pure override returns (string memory) {
        return "";
    }
}

// Mock ERC1155 contract for wrapped names
contract MockNameWrapper is ERC1155 {
    mapping(uint256 tokenId => address owner) private _tokenOwners;
    mapping(uint256 tokenId => uint32 fuses) private _tokenFuses;

    MockBaseRegistrar public registrar;

    constructor(MockBaseRegistrar _registrar) ERC1155("https://metadata.ens.domains/") {
        registrar = _registrar;
    }

    function wrapETH2LD(string memory label, address owner, uint16, address) external {
        uint256 tokenId = uint256(keccak256(bytes(label)));
        _mint(owner, tokenId, 1, "");
        _tokenOwners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _tokenOwners[tokenId];
    }

    function getData(uint256 tokenId) external view returns (address, uint32, uint64) {
        return (_tokenOwners[tokenId], _tokenFuses[tokenId], 0);
    }

    function setFuses(uint256 tokenId, uint32 fuses) external {
        _tokenFuses[tokenId] = fuses;
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public override {
        super.safeTransferFrom(from, to, id, amount, data);
        _tokenOwners[id] = to;
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public override {
        super.safeBatchTransferFrom(from, to, ids, amounts, data);
        for (uint256 i = 0; i < ids.length; i++) {
            _tokenOwners[ids[i]] = to;
        }
    }

    function unwrapETH2LD(
        bytes32 label,
        address newRegistrant,
        address /*newController*/
    ) external {
        uint256 tokenId = uint256(label);
        // Mock unwrap by burning the ERC1155 token from the caller (migration controller)
        _burn(msg.sender, tokenId, 1);
        _tokenOwners[tokenId] = newRegistrant;
    }
}

contract UnlockedMigrationControllerTest is Test, ERC1155Holder, ERC721Holder {
    MockBaseRegistrar ethRegistrarV1;
    MockNameWrapper nameWrapper;
    UnlockedMigrationController migrationController;

    // Real components for testing
    PermissionedRegistry registry;
    MockRegistryMetadata registryMetadata;
    MockHCAFactoryBasic hcaFactory;

    address user = address(0x1234);
    address controller = address(0x5678);

    string testLabel = "test";
    uint256 testTokenId;

    /**
     * Helper method to create properly encoded migration data for transfers
     */
    function _createMigrationData(
        string memory label
    ) internal pure returns (MigrationData memory) {
        return
            MigrationData({
                transferData: TransferData({
                    dnsEncodedName: NameCoder.ethName(label),
                    owner: address(0),
                    subregistry: address(0),
                    resolver: address(0),
                    roleBitmap: 0,
                    expires: 0
                }),
                salt: 0
            });
    }

    /**
     * Helper method to create migration data with valid expiration
     */
    function _createMigrationDataWithExpiry(
        string memory label
    ) internal view returns (MigrationData memory) {
        return
            MigrationData({
                transferData: TransferData({
                    dnsEncodedName: NameCoder.ethName(label),
                    owner: address(0x1111),
                    subregistry: address(0x2222),
                    resolver: address(0x3333),
                    roleBitmap: 0,
                    expires: uint64(block.timestamp + 86400)
                }),
                salt: 0
            });
    }

    function setUp() public {
        // Set up real registry infrastructure
        hcaFactory = new MockHCAFactoryBasic();
        registryMetadata = new MockRegistryMetadata();

        // Deploy the real registry
        registry = new PermissionedRegistry(
            hcaFactory,
            registryMetadata,
            address(this),
            EACBaseRolesLib.ALL_ROLES
        );

        // Deploy mock base registrar and name wrapper (keep these as mocks)
        ethRegistrarV1 = new MockBaseRegistrar();
        ethRegistrarV1.addController(controller);
        nameWrapper = new MockNameWrapper(ethRegistrarV1);

        // Deploy migration controller
        migrationController = new UnlockedMigrationController(
            INameWrapper(address(nameWrapper)),
            IPermissionedRegistry(address(registry))
        );

        // Grant necessary roles to the migration controller
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(migrationController)
        );

        testTokenId = uint256(keccak256(bytes(testLabel)));
    }

    function test_constructor() public view {
        assertEq(address(migrationController.NAME_WRAPPER()), address(nameWrapper));
        assertEq(address(migrationController.ETH_REGISTRY()), address(registry));
    }

    function test_migrateUnwrappedEthName() public {
        // Register a name in the v1 registrar
        vm.prank(controller);
        ethRegistrarV1.register(testTokenId, user, 86400);

        // Verify user owns the token
        assertEq(ethRegistrarV1.ownerOf(testTokenId), user);

        // Create migration data with proper owner
        MigrationData memory migrationData = _createMigrationDataWithExpiry(testLabel);
        // Update owner to match the actual token owner for this test
        migrationData.transferData.owner = user;
        bytes memory data = abi.encode(migrationData);

        // Transfer to migration controller (simulating migration)
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(user, address(migrationController), testTokenId, data);

        // Verify the migration controller owns the token
        assertEq(ethRegistrarV1.ownerOf(testTokenId), address(migrationController));

        // Verify the name was registered in the ETH registry
        assertEq(address(registry.getSubregistry(testLabel)) != address(0), true);
    }

    function test_Revert_migrateUnwrappedEthName_wrong_caller() public {
        // Register a name in the v1 registrar
        vm.prank(controller);
        ethRegistrarV1.register(testTokenId, user, 86400);

        // Create migration data
        MigrationData memory migrationData = _createMigrationData(testLabel);
        bytes memory data = abi.encode(migrationData);

        // Try to transfer from wrong registry
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, address(this)));
        migrationController.onERC721Received(address(this), user, testTokenId, data);
    }

    function test_Revert_migrateUnwrappedEthName_not_owner() public {
        // Register a name in the v1 registrar
        vm.prank(controller);
        ethRegistrarV1.register(testTokenId, user, 86400);

        // Create migration data
        MigrationData memory migrationData = _createMigrationData(testLabel);
        bytes memory data = abi.encode(migrationData);

        // Try to call onERC721Received directly when migration controller doesn't own the token
        // This should fail with UnauthorizedCaller because we're calling it directly
        // and msg.sender is not ethRegistrarV1
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, address(this)));
        migrationController.onERC721Received(address(this), user, testTokenId, data);
    }

    function test_migrateUnlockedWrappedEthName_single() public {
        // Wrap a name (simulate) - this should mint the token to the user
        nameWrapper.wrapETH2LD(testLabel, user, 0, address(0));
        // Ensure fuses are 0 (unlocked)
        nameWrapper.setFuses(testTokenId, 0);

        // Verify user owns the wrapped token
        assertEq(nameWrapper.balanceOf(user, testTokenId), 1);

        // Create migration data with proper owner
        MigrationData memory migrationData = _createMigrationDataWithExpiry(testLabel);
        migrationData.transferData.owner = user;
        bytes memory data = abi.encode(migrationData);

        // Transfer wrapped token to migration controller
        vm.prank(user);
        nameWrapper.safeTransferFrom(user, address(migrationController), testTokenId, 1, data);

        // Verify the name was registered in the ETH registry
        assertEq(address(registry.getSubregistry(testLabel)) != address(0), true);
    }

    function test_migrateWrappedEthName_batch_allUnlocked() public {
        string memory label1 = "unlocked1";
        string memory label2 = "unlocked2";
        uint256 tokenId1 = uint256(keccak256(bytes(label1)));
        uint256 tokenId2 = uint256(keccak256(bytes(label2)));

        nameWrapper.wrapETH2LD(label1, user, 0, address(0));
        nameWrapper.setFuses(tokenId1, 0); // Unlocked
        nameWrapper.wrapETH2LD(label2, user, 0, address(0));
        nameWrapper.setFuses(tokenId2, 0); // Unlocked

        // Verify user owns the wrapped tokens
        assertEq(nameWrapper.balanceOf(user, tokenId1), 1);
        assertEq(nameWrapper.balanceOf(user, tokenId2), 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        MigrationData[] memory migrationDataArray = new MigrationData[](2);
        migrationDataArray[0] = _createMigrationDataWithExpiry(label1);
        migrationDataArray[0].transferData.owner = user;
        migrationDataArray[1] = _createMigrationDataWithExpiry(label2);
        migrationDataArray[1].transferData.owner = user;

        bytes memory data = abi.encode(migrationDataArray);

        vm.prank(user);
        nameWrapper.safeBatchTransferFrom(
            user,
            address(migrationController),
            tokenIds,
            amounts,
            data
        );

        // Verify both names were registered in the ETH registry
        assertEq(address(registry.getSubregistry(label1)) != address(0), true);
        assertEq(address(registry.getSubregistry(label2)) != address(0), true);
    }

    function test_Revert_migrateWrappedEthName_single_locked() public {
        // First wrap a name so the user actually owns it
        vm.prank(user);
        nameWrapper.wrapETH2LD(testLabel, user, 0, address(0));
        nameWrapper.setFuses(testTokenId, CANNOT_UNWRAP); // Mark as locked

        // Create migration data
        MigrationData memory migrationData = _createMigrationData(testLabel);
        bytes memory data = abi.encode(migrationData);

        // Try to transfer locked name (should revert with MigrationNotSupported)
        vm.expectRevert(
            abi.encodeWithSelector(UnlockedMigrationController.MigrationNotSupported.selector)
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(user, address(migrationController), testTokenId, 1, data);
    }

    function test_Revert_migrateWrappedEthName_batch_locked() public {
        string memory label1 = "locked1";
        string memory label2 = "locked2";
        uint256 tokenId1 = uint256(keccak256(bytes(label1)));
        uint256 tokenId2 = uint256(keccak256(bytes(label2)));

        // First wrap names so the user actually owns them
        vm.startPrank(user);
        nameWrapper.wrapETH2LD(label1, user, 0, address(0));
        nameWrapper.setFuses(tokenId1, CANNOT_UNWRAP); // Mark as locked
        nameWrapper.wrapETH2LD(label2, user, 0, address(0));
        nameWrapper.setFuses(tokenId2, CANNOT_UNWRAP); // Mark as locked
        vm.stopPrank();

        // Prepare batch data
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        MigrationData[] memory migrationDataArray = new MigrationData[](2);
        migrationDataArray[0] = _createMigrationData(label1);
        migrationDataArray[1] = _createMigrationData(label2);

        bytes memory data = abi.encode(migrationDataArray);

        // Should revert when processing the first locked name
        vm.expectRevert(
            abi.encodeWithSelector(UnlockedMigrationController.MigrationNotSupported.selector)
        );
        vm.prank(user);
        nameWrapper.safeBatchTransferFrom(
            user,
            address(migrationController),
            tokenIds,
            amounts,
            data
        );
    }

    function test_supportsInterface() public view {
        assertTrue(migrationController.supportsInterface(type(IERC165).interfaceId));
        assertTrue(migrationController.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(migrationController.supportsInterface(type(IERC1155Receiver).interfaceId));
        // Ownable is not directly advertised via supportsInterface in UnlockedMigrationController based on its ERC165 logic
        // assertTrue(migrationController.supportsInterface(type(Ownable).interfaceId));
    }

    function test_Revert_onERC1155Received_wrong_caller() public {
        // Create migration data
        MigrationData memory migrationData = _createMigrationData(testLabel);
        bytes memory data = abi.encode(migrationData);

        // Try to call onERC1155Received from wrong contract (not nameWrapper)
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, address(this)));
        migrationController.onERC1155Received(address(this), user, testTokenId, 1, data);
    }

    function test_Revert_onERC1155BatchReceived_wrong_caller() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = testTokenId;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        // For batch, data is MigrationData[]
        MigrationData[] memory migrationDataArray = new MigrationData[](1);
        migrationDataArray[0] = _createMigrationData(testLabel);

        bytes memory data = abi.encode(migrationDataArray);

        // Try to call onERC1155BatchReceived from wrong contract (not nameWrapper)
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, address(this)));
        migrationController.onERC1155BatchReceived(address(this), user, tokenIds, amounts, data);
    }

    function test_onERC1155Received_nameWrapper_authorization() public {
        // Create migration data (single item)
        MigrationData memory migrationData = _createMigrationData(testLabel);
        bytes memory data = abi.encode(migrationData); // onERC1155Received expects a single MigrationData

        // Call onERC1155Received as nameWrapper (should work)
        // Use a locked token so it doesn't try to unwrap (which would trigger the ERC1155InvalidReceiver issue)
        nameWrapper.setFuses(testTokenId, CANNOT_UNWRAP); // Mark as locked

        vm.expectRevert(
            abi.encodeWithSelector(UnlockedMigrationController.MigrationNotSupported.selector)
        );
        vm.prank(address(nameWrapper));
        migrationController.onERC1155Received(address(this), user, testTokenId, 1, data);
    }

    function test_onERC1155BatchReceived_nameWrapper_authorization() public {
        string memory label1 = "batchAuth1";
        uint256 tokenId1 = uint256(keccak256(bytes(label1)));

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        MigrationData[] memory migrationDataArray = new MigrationData[](1);
        migrationDataArray[0] = _createMigrationData(label1);

        bytes memory data = abi.encode(migrationDataArray); // onERC1155BatchReceived expects MigrationData[]

        // Call onERC1155BatchReceived as nameWrapper (should work)
        // Use a locked token so it doesn't try to unwrap (which would trigger the ERC1155InvalidReceiver issue)
        nameWrapper.setFuses(tokenId1, CANNOT_UNWRAP); // Mark as locked

        vm.expectRevert(
            abi.encodeWithSelector(UnlockedMigrationController.MigrationNotSupported.selector)
        );
        vm.prank(address(nameWrapper));
        migrationController.onERC1155BatchReceived(address(this), user, tokenIds, amounts, data);
    }

    function test_Revert_migrateUnwrappedEthName_tokenId_mismatch() public {
        // Register a name in the v1 registrar
        vm.prank(controller);
        ethRegistrarV1.register(testTokenId, user, 86400);

        // Create migration data with wrong label
        MigrationData memory migrationData = _createMigrationData("wronglabel");
        bytes memory data = abi.encode(migrationData);

        // Calculate expected tokenId for the wrong label
        uint256 expectedTokenId = uint256(keccak256(bytes("wronglabel")));

        // Try to transfer with mismatched tokenId and label
        vm.expectRevert(
            abi.encodeWithSelector(
                UnlockedMigrationController.TokenIdMismatch.selector,
                testTokenId,
                expectedTokenId
            )
        );
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(user, address(migrationController), testTokenId, data);
    }

    function test_Revert_migrateWrappedEthName_tokenId_mismatch() public {
        // Wrap a name (simulate) - this should mint the token to the user
        nameWrapper.wrapETH2LD(testLabel, user, 0, address(0));

        // Verify user owns the wrapped token
        assertEq(nameWrapper.balanceOf(user, testTokenId), 1);

        // Create migration data with wrong label
        MigrationData memory migrationData = _createMigrationData("wronglabel");
        bytes memory data = abi.encode(migrationData);

        // Calculate expected tokenId for the wrong label
        uint256 expectedTokenId = uint256(keccak256(bytes("wronglabel")));

        // Try to transfer with mismatched tokenId and label
        vm.expectRevert(
            abi.encodeWithSelector(
                UnlockedMigrationController.TokenIdMismatch.selector,
                testTokenId,
                expectedTokenId
            )
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(user, address(migrationController), testTokenId, 1, data);
    }

    function test_Revert_migrateWrappedEthName_batch_tokenId_mismatch() public {
        string memory label1 = "correct1";
        string memory wrongLabel2 = "wrong2";
        uint256 tokenId1 = uint256(keccak256(bytes(label1)));
        uint256 tokenId2 = uint256(keccak256(bytes("correct2"))); // This is the correct tokenId

        nameWrapper.wrapETH2LD(label1, user, 0, address(0));
        nameWrapper.wrapETH2LD("correct2", user, 0, address(0));

        // Verify user owns the wrapped tokens
        assertEq(nameWrapper.balanceOf(user, tokenId1), 1);
        assertEq(nameWrapper.balanceOf(user, tokenId2), 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        // Create migration data with one wrong label
        MigrationData[] memory migrationDataArray = new MigrationData[](2);
        migrationDataArray[0] = _createMigrationDataWithExpiry(label1);
        migrationDataArray[0].transferData.owner = user;
        migrationDataArray[1] = _createMigrationDataWithExpiry(wrongLabel2);
        migrationDataArray[1].transferData.owner = user;

        bytes memory data = abi.encode(migrationDataArray);

        // Calculate expected tokenId for the wrong label
        uint256 expectedTokenId = uint256(keccak256(bytes(wrongLabel2)));

        // Should revert when processing the second token with mismatched data
        vm.expectRevert(
            abi.encodeWithSelector(
                UnlockedMigrationController.TokenIdMismatch.selector,
                tokenId2,
                expectedTokenId
            )
        );
        vm.prank(user);
        nameWrapper.safeBatchTransferFrom(
            user,
            address(migrationController),
            tokenIds,
            amounts,
            data
        );
    }
}
