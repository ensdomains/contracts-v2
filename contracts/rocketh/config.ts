/// ----------------------------------------------------------------------------
// Typed Config
// ----------------------------------------------------------------------------
import type { Deployment, UserConfig } from "rocketh/types";

// we define our config and export it as "config"
export const config = {
  accounts: {
    deployer: {
      default: 0,
    },
    owner: {
      default: 0,
      // admin is DAO on mainnet
      1: "0xFe89cc7aBB2C4183683ab71653C4cdc9B02D44b7",
    },
  },
  environments: {
    mainnet: {
      chain: 1,
      scripts: ["deploy"],
      overrides: {
        tags: ['hasDao'],
      }
    },
    sepolia: {
      chain: 11155111,
      scripts: ["deploy"],
    },
    'sepolia-v1-dev': {
      chain: 11155111,
      scripts: ["lib/ens-contracts/deploy"],
    }
  },
  data: {},
} as const satisfies UserConfig;

import * as deployExtension from "@rocketh/deploy";
import * as readExecuteExtension from "@rocketh/read-execute";
import * as viemExtension from "@rocketh/viem";

import type { Environment } from '@rocketh/node';
import { loadDeploymentsFromFiles } from "@rocketh/node";
import { resolve } from "path";

const currentPath = new URL(import.meta.url).pathname;
const deploymentsCache = new Map<string, ReturnType<typeof loadDeploymentsFromFiles>>();

// and export them as a unified object
const extensions = {
  ...deployExtension,
  ...readExecuteExtension,
  ...viemExtension,
  getV1: (env: Environment) => {
    const path = resolve(currentPath, '../..', 'deployments', 'v1');
    const deploymentsPromise = (() => {
      if (deploymentsCache.has(path)) return deploymentsCache.get(path)!;
      const result = loadDeploymentsFromFiles(path, env.name, false);
      deploymentsCache.set(path, result);
      return result;
    })();
    return async <TAbi extends deployExtension.Abi>(name: string): Promise<Deployment<TAbi>> => {
      // Try file-based V1 deployments first (for sepolia/mainnet where V1 is pre-deployed)
      const {deployments} = await deploymentsPromise;
      const deployment = deployments[name];
      if (deployment) return deployment as Deployment<TAbi>;
      // Fall back to current environment (for devnet where V1 is deployed in-process)
      const current = env.deployments[name];
      if (current) return current as Deployment<TAbi>;
      throw new Error(`V1 Deployment ${name} not found`);
    };
  },
};
export { extensions };

type HookFunctions = {
  createLegacyRegistryNames?: (env: Environment) => () => Promise<void>
  registerLegacyNames?: (env: Environment) => () => Promise<void>
  registerWrappedNames?: (env: Environment) => () => Promise<void>
  registerUnwrappedNames?: (env: Environment) => () => Promise<void>
}

// then we also export the types that our config exhibits so others can use them

type Extensions = typeof extensions & HookFunctions;
type Accounts = typeof config.accounts;
type Data = typeof config.data;

export type { Accounts, Data, Extensions };
