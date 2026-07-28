import { configVariable, type HardhatUserConfig } from "hardhat/config";

import HardhatChaiMatchersViemPlugin from "@ensdomains/hardhat-chai-matchers-viem";
import HardhatKeystore from "@nomicfoundation/hardhat-keystore";
import HardhatNetworkHelpersPlugin from "@nomicfoundation/hardhat-network-helpers";
import HardhatViem from "@nomicfoundation/hardhat-viem";
import HardhatDeploy from "hardhat-deploy";

import HardhatIgnoreWarningsPlugin from "./plugins/ignore-warnings/index.ts";
import HardhatClearRemappingsPlugin from "./plugins/clear-remappings/index.ts";
import HardhatMigrationPlugin from "./plugins/migration/index.ts";
import HardhatStorageLayoutPlugin from "./plugins/storage-layout/index.ts";

const version = "0.8.25";
const hcaVersion = "0.8.27";
const outputSelection = {
  "*": {
    "*": ["storageLayout"],
  },
};
const tenderlySepoliaRpcUrl =
  process.env.TENDERLY_SEPOLIA_RPC_URL ??
  configVariable("TENDERLY_SEPOLIA_RPC_URL");
const plugins = [
  HardhatNetworkHelpersPlugin,
  ...(process.env.HARDHAT_DISABLE_VIEM === "1"
    ? []
    : [HardhatChaiMatchersViemPlugin, HardhatViem]),
  HardhatStorageLayoutPlugin,
  HardhatIgnoreWarningsPlugin,
  HardhatDeploy,
  HardhatKeystore,
  HardhatClearRemappingsPlugin,
  HardhatMigrationPlugin,
];
const config = {
  solidity: {
    compilers: [
      {
        version,
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
          evmVersion: "cancun",
          outputSelection,
        },
      },
      {
        version: hcaVersion,
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
          evmVersion: "prague",
          outputSelection,
        },
      },
    ],
    overrides: {
      "lib/ens-contracts/contracts/wrapper/NameWrapper.sol": {
        version: "0.8.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1200,
          },
        },
      },
      // 23k at 1
      // 25k at 1000
      "src/registry/WrapperRegistry.sol": {
        version,
        settings: {
          optimizer: {
            enabled: true,
            runs: 100,
          },
          evmVersion: "cancun",
          outputSelection,
        },
      },
      "src/L2/reverse-registrar/L2ReverseRegistrar.sol": {
        version,
        settings: {
          optimizer: {
            enabled: true,
            runs: 1_000_000,
          },
          evmVersion: "paris",
          outputSelection,
        },
      },
    },
  },
  networks: {
    sepolia: {
      type: "http",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("DEPLOYER_KEY")],
      chainId: 11155111,
    },
    "sepolia-dev": {
      type: "http",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("DEV_DEPLOYER_KEY")],
      chainId: 11155111,
    },
    "tenderly-sepolia": {
      type: "http",
      url: tenderlySepoliaRpcUrl,
      accounts: [configVariable("DEPLOYER_KEY")],
    },
  },
  paths: {
    sources: {
      solidity: [
        "./src/",
        "./test/mocks/",
        "./lib/verifiable-factory/src/",
        "./lib/ens-contracts/contracts/",
        "./lib/openzeppelin-contracts/contracts/utils/introspection/",
        "./lib/openzeppelin-contracts/contracts/token/ERC721/",
        "./lib/openzeppelin-contracts/contracts/token/ERC1155/",
        "./lib/openzeppelin-contracts/contracts/proxy/ERC1967/",
        // note: this increases artifact size by 25MB+ for 1 interface
        // "./lib/unruggable-gateways/contracts/",
      ],
    },
  },
  generateTypedArtifacts: {
    destinations: [
      {
        mode: "typescript",
      },
    ],
  },
  shouldIgnoreWarnings: (path) => {
    return path.startsWith("./lib/");
  },
  plugins,
} satisfies HardhatUserConfig;

export default config;
