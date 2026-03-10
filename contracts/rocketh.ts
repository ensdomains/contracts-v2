// rocketh.ts
// ------------------------------------------------------------------------------------------------
// Typed Config
// ------------------------------------------------------------------------------------------------
import { resolve } from "path";
import type { Deployment, UnknownDeployments, UserConfig } from "rocketh";
import type { Abi } from "viem";
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
  networks: {
    // "l1-local": {
    //   scripts: ["deploy/l1", "deploy/shared"],
    //   tags: ["l1", "local"],
    //   rpcUrl: "http://127.0.0.1:8545",
    // },
    // "l2-local": {
    //   scripts: ["deploy/l2", "deploy/shared"],
    //   tags: ["l2", "local"],
    //   rpcUrl: "http://127.0.0.1:8546",
    // },
    mainnet: {
      scripts: ["deploy/l1/universalResolver"],
      tags: ["hasDao"],
    },
    sepolia: {
      scripts: ["deploy/l1/universalResolver"],
      tags: [],
    },
    holesky: {
      scripts: ["deploy/l1/universalResolver"],
      tags: [],
    },
    sepoliaFresh: {
      scripts: [
        "lib/ens-contracts/deploy",
        "deploy",
      ],
      tags: ["l1", "l2", "use_root", "allow_unsafe", "legacy"],
    },
  },
} as const satisfies UserConfig;

// ------------------------------------------------------------------------------------------------
// Imports and Re-exports
// ------------------------------------------------------------------------------------------------
// We regroup all what is needed for the deploy scripts
// so that they just need to import this file
import * as deployFunctions from "@rocketh/deploy";
import * as readExecuteFunctions from "@rocketh/read-execute";
import * as viemFunctions from "@rocketh/viem";

// ------------------------------------------------------------------------------------------------
// we re-export the artifacts, so they are easily available from the alias
import artifacts from "./generated/artifacts.ts";
export { artifacts };
// ------------------------------------------------------------------------------------------------

import {
  loadDeployments,
  setup,
  type CurriedFunctions,
  type Environment as Environment_,
} from "rocketh";

const deploymentsCache = new Map<string, UnknownDeployments>();

const functions = {
  ...deployFunctions,
  ...readExecuteFunctions,
  ...viemFunctions,
  getV1: (env: Environment_) => {
    const path = resolve(env.config.deployments, "v1");
    const v1Deployments = (() => {
      if (deploymentsCache.has(path)) return deploymentsCache.get(path)!;
      try {
        const { deployments: deployments_ } = loadDeployments(
          path,
          env.config.network.name,
          false,
        );
        deploymentsCache.set(path, deployments_);
        return deployments_;
      } catch {
        // V1 deployment directory not found, return empty
        deploymentsCache.set(path, {});
        return {};
      }
    })();
    return <TAbi extends Abi>(name: string): Deployment<TAbi> => {
      // Try V1 deployment directory first
      const v1Deployment = v1Deployments[name];
      if (v1Deployment) return v1Deployment as Deployment<TAbi>;
      // Fall back to current deployment namespace (for local devnet where
      // V1 and V2 are deployed together)
      const currentDeployment = env.deployments[name];
      if (currentDeployment) return currentDeployment as Deployment<TAbi>;
      throw new Error(`V1 Deployment ${name} not found`);
    };
  },
};

export type Environment = Environment_<typeof config.accounts> &
  CurriedFunctions<typeof functions>;

const enhanced = setup<typeof functions, typeof config.accounts>(functions);

export const execute = enhanced.deployScript;
export const deployScript = enhanced.deployScript;

export const loadAndExecuteDeployments = enhanced.loadAndExecuteDeployments;
