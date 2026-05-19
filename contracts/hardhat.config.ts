import type { HardhatUserConfig } from "hardhat/config";

import { readdirSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

import HardhatChaiMatchersViemPlugin from "@ensdomains/hardhat-chai-matchers-viem";
import HardhatNetworkHelpersPlugin from "@nomicfoundation/hardhat-network-helpers";
import HardhatViem from "@nomicfoundation/hardhat-viem";
import HardhatDeploy from "hardhat-deploy";

import HardhatIgnoreWarningsPlugin from "./plugins/ignore-warnings/index.ts";
import HardhatStorageLayoutPlugin from "./plugins/storage-layout/index.ts";

const projectRoot = dirname(fileURLToPath(import.meta.url));
const isCoverageBuild =
  process.argv.includes("--coverage") || process.env.COVERAGE === "1";

const hcaArtifactSourcePaths = [
  "./lib/compact-utils/src/common/AddressBook/",
  "./lib/compact-utils/src/router/",
  "./lib/compact-utils/src/arbiters/samechain/",
  "./lib/compact-utils/src/executor/",
  "./lib/ens-modules/src/hca/",
  "./lib/ens-modules/src/hca-module/",
  "./lib/account-abstraction/contracts/core/",
];

const compactUtilsSettings = {
  optimizer: {
    enabled: true,
    runs: 10_000,
  },
  evmVersion: "prague",
  viaIR: true,
  metadata: {
    bytecodeHash: "none",
    useLiteralContent: false,
  },
};

function solFilesUnder(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = join(dir, entry.name);
    if (entry.isDirectory()) return solFilesUnder(entryPath);
    if (!entry.isFile() || !entry.name.endsWith(".sol")) return [];
    return [relative(projectRoot, entryPath).split(sep).join("/")];
  });
}

const compactUtilsOverrides = Object.fromEntries(
  ["lib/compact-utils/src"].flatMap((dir) =>
    solFilesUnder(join(projectRoot, dir)).map((sourcePath) => [
      sourcePath,
      {
        version: "0.8.30",
        settings: compactUtilsSettings,
      },
    ]),
  ),
);

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
      {
        version: "0.8.27",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
          evmVersion: "cancun",
        },
      },
      {
        version: "0.8.30",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
          evmVersion: "cancun",
        },
      },
    ].filter((compiler) => !isCoverageBuild || compiler.version !== "0.8.30"),
    overrides: {
      ...compactUtilsOverrides,
      "src/L2/reverse-registrar/L2ReverseRegistrar.sol": {
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
      },
    },
  },
  paths: {
    sources: {
      solidity: [
        "./src/",
        ...(isCoverageBuild ? [] : hcaArtifactSourcePaths),
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
  ],
} satisfies HardhatUserConfig;

export default config;
