// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ProxyLib} from "./ProxyLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IInitDataGenerator} from "./IInitDataGenerator.sol";

import {IHCAFactory} from "./IHCAFactory.sol";
import {IHCA} from "./IHCA.sol";

contract HCAFactory is Ownable, IHCAFactory {
    address internal _implementation;

    IInitDataGenerator internal _initDataGenerator;

    event AccountCreated(address indexed owner, address indexed account);

    event InitDataGeneratorUpdated(address indexed generator);

    constructor(
        address implementation_,
        IInitDataGenerator initDataGenerator_,
        address owner_
    ) Ownable(owner_) {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
    }

    function setImplementation(address implementation_) external onlyOwner {
        _implementation = implementation_;
    }

    function setInitDataGenerator(
        IInitDataGenerator initDataGenerator_
    ) external onlyOwner {
        _initDataGenerator = initDataGenerator_;
        emit InitDataGeneratorUpdated(address(initDataGenerator_));
    }

    function createAccount(address owner_) external returns (address) {
        // Generate account-specific init data using the external generator
        bytes memory accountInitData = _initDataGenerator.generateInitData(
            owner_
        );
        (bool alreadyDeployed, address payable account) = ProxyLib.deployProxy(
            _implementation,
            owner_,
            accountInitData
        );
        if (!alreadyDeployed) emit AccountCreated(owner_, account);
        return account;
    }

    function getImplementation() external view returns (address) {
        return _implementation;
    }

    function getInitDataGenerator() external view returns (IInitDataGenerator) {
        return _initDataGenerator;
    }

    function getAccountOwner(address account) external view returns (address) {
        // Check if the account has code (is a contract)
        if (account.code.length == 0) {
            return address(0);
        }

        try IHCA(account).getOwner() returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    function computeAccountAddress(
        address owner_
    ) external view returns (address) {
        return ProxyLib.predictProxyAddress(owner_);
    }
}
