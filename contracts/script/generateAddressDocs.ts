#!/usr/bin/env bun
import { Command } from "commander";
import { resolve } from "node:path";
import {
  generateAddressMarkdown,
  rpcBlockTimes,
  writeNamespaceAddressTable,
} from "./addressDocs.js";
import { httpRpcProvider } from "./migrations/rpc.js";

const currentPath = new URL(import.meta.url).pathname;
const defaultDeploymentsDir = resolve(currentPath, "../..", "deployments");

const program = new Command()
  .option(
    "--network <name>",
    "Canonical network name used for the output filename and heading",
    "sepolia",
  )
  .option(
    "--namespace <dir>",
    "Deployment namespace subdirectory to read (defaults to the network name)",
  )
  .option(
    "--deployments-dir <path>",
    "Root directory for v2 deployment files",
    defaultDeploymentsDir,
  )
  .option(
    "--out-dir <path>",
    "Output directory for the generated markdown (defaults to docs/addresses)",
  )
  .option(
    "--file-name <name>",
    "Basename of the generated file, without the extension (defaults to the network name)",
  )
  .option(
    "--rpc-url <url>",
    "RPC endpoint the changelog's deploy times are read from (default: <NETWORK>_RPC_URL)",
  );

program.parse(process.argv);
const opts = program.opts<{
  network: string;
  namespace?: string;
  deploymentsDir: string;
  outDir?: string;
  fileName?: string;
  rpcUrl?: string;
}>();

const namespace = opts.namespace ?? opts.network;
const rpcEnvVar = `${opts.network.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_RPC_URL`;
const rpcUrl = opts.rpcUrl ?? process.env[rpcEnvVar];
// A page without a changelog reads nothing from the chain, so the RPC is only
// required once the writer asks for a block time.
const blockTimes = rpcUrl ? rpcBlockTimes(httpRpcProvider(rpcUrl)) : undefined;
const outPath = await generateAddressMarkdown({
  deploymentsDir: opts.deploymentsDir,
  namespace,
  docName: opts.network,
  outDir: opts.outDir,
  fileName: opts.fileName,
  blockTimes,
});
console.log(`Wrote ${outPath}`);

// The network's own namespace also carries its table beside its records. Any
// other namespace keeps the table its deploy wrote, which can hold sections
// this command does not know about.
if (namespace === opts.network) {
  const tablePath = await writeNamespaceAddressTable({
    deploymentsDir: opts.deploymentsDir,
    namespace,
    blockTimes,
  });
  console.log(`Wrote ${tablePath}`);
}
