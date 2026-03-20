import { configVariable, type HardhatUserConfig } from "hardhat/config";

import HardhatChaiMatchersViemPlugin from "@ensdomains/hardhat-chai-matchers-viem";
import HardhatKeystore from "@nomicfoundation/hardhat-keystore";
import HardhatNetworkHelpersPlugin from "@nomicfoundation/hardhat-network-helpers";
import HardhatViem from "@nomicfoundation/hardhat-viem";
import HardhatDeploy from "hardhat-deploy";

import HardhatIgnoreWarningsPlugin from "./plugins/ignore-warnings/index.ts";
import HardhatClearRemappingsPlugin from "./plugins/clear-remappings/index.ts";
import HardhatStorageLayoutPlugin from "./plugins/storage-layout/index.ts";

const config = {
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
          evmVersion: "cancun",
          outputSelection: {
            "*": {
              "*": ["storageLayout"],
            },
          },
        },
      },
    ],
    overrides: {
      'lib/ens-contracts/contracts/wrapper/NameWrapper.sol': {
        version: "0.8.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1200,
          },
        },
      },
      'src/L2/reverse-registrar/L2ReverseRegistrar.sol': {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1_000_000,
          },
          evmVersion: "paris",
          outputSelection: {
            "*": {
              "*": ["storageLayout"],
            },
          },
        },
      }
    }
  },
  networks: {
    'sepolia-dev': {
      type: 'http',
      url: configVariable('SEPOLIA_RPC_URL'),
      accounts: [configVariable('DEV_DEPLOYER_KEY')],
      chainId: 11155111,
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
        "./lib/openzeppelin-contracts/contracts/token/ERC721",
        "./lib/openzeppelin-contracts/contracts/token/ERC1155/",
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
    return (
      path.startsWith("./lib/ens-contracts/") ||
      path.startsWith("./lib/solsha1/")
    );
  },
  plugins: [
    HardhatNetworkHelpersPlugin,
    HardhatChaiMatchersViemPlugin,
    HardhatViem,
    HardhatStorageLayoutPlugin,
    HardhatIgnoreWarningsPlugin,
    HardhatDeploy,
    HardhatKeystore,
    HardhatClearRemappingsPlugin,
  ],
} satisfies HardhatUserConfig;

export default config;
