import type { HardhatUserConfig } from "hardhat/config";

import HardhatChaiMatchersViemPlugin from "@ensdomains/hardhat-chai-matchers-viem";
import HardhatNetworkHelpersPlugin from "@nomicfoundation/hardhat-network-helpers";
import HardhatViem from "@nomicfoundation/hardhat-viem";
import HardhatDeploy from "hardhat-deploy";

import HardhatIgnoreWarningsPlugin from "./plugins/ignore-warnings/index.ts";
import HardhatStorageLayoutPlugin from "./plugins/storage-layout/index.ts";

const version = "0.8.25";
const hcaVersion = "0.8.27";
const outputSelection = {
  "*": {
    "*": ["storageLayout"],
  },
};
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
          evmVersion: "cancun",
          outputSelection,
        },
      },
    ],
    overrides: {
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
  shouldIgnoreWarnings: (path) => {
    return path.startsWith("./lib/");
  },
  plugins: [
    HardhatNetworkHelpersPlugin,
    HardhatChaiMatchersViemPlugin,
    HardhatViem,
    HardhatStorageLayoutPlugin,
    HardhatIgnoreWarningsPlugin,
    HardhatDeploy,
  ],
} satisfies HardhatUserConfig;

export default config;
