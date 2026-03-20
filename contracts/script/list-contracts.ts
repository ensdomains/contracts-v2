import { loadDeploymentsFromFiles } from "@rocketh/node";
import { resolve } from 'path';

const currentPath = new URL(import.meta.url).pathname;
const path = resolve(currentPath, '../..', 'deployments');

const chainName = "sepolia-dev";
const deployments = {
  v1: await loadDeploymentsFromFiles(resolve(path, 'v1'), chainName, false).then(d => d.deployments),
  v2: await loadDeploymentsFromFiles(path, chainName, false).then(d => d.deployments),
} as const;

for (const chain of Object.keys(deployments) as (keyof typeof deployments)[]) {
  console.log(chain);
  const ctrcts = [];
  for (const contract of Object.keys(deployments[chain])) {
    ctrcts.push({ name: contract, address: (deployments[chain] as Record<string, { address: string }>)[contract].address });
  }
  console.table(ctrcts, ["name", "address"]);
}