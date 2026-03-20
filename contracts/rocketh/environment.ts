import { setupEnvironmentFromFiles } from "@rocketh/node";
import { setupHardhatDeploy } from "hardhat-deploy/helpers";
import {
  type Accounts,
  type Data,
  type Extensions,
  extensions,
} from "./config.js";

// useful for test and scripts, uses file-system
const { loadAndExecuteDeploymentsFromFiles, loadAndExecuteDeploymentsFromFilesWithConfig } = setupEnvironmentFromFiles<
  Extensions,
  Accounts,
  Data
>(extensions);
const { loadEnvironmentFromHardhat } = setupHardhatDeploy<
  Extensions,
  Accounts,
  Data
>(extensions);

export type Environment = Awaited<ReturnType<typeof loadAndExecuteDeploymentsFromFiles>>

export { loadAndExecuteDeploymentsFromFiles, loadAndExecuteDeploymentsFromFilesWithConfig, loadEnvironmentFromHardhat };
