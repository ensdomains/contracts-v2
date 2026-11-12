#!/usr/bin/env bun
import { Command } from "commander";
import { fileURLToPath } from "node:url";
import {
  generateAddressMarkdown,
  rpcBlockTimes,
  writeNetworkAddressPages,
} from "./addressDocs.js";
import { httpRpcProvider, rpcUrlFor } from "./migrations/rpc.js";

const defaultDeploymentsDir = fileURLToPath(
  new URL("../deployments", import.meta.url),
);

const program = new Command()
  .name("docs:addresses")
  .description(
    "Write a network's address page to docs/addresses/<network>.md, and the same table beside its records in <deployments-dir>/<network>/addresses.md. With --namespace, --out-dir or --file-name, only the first page is written.",
  )
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
const rpcUrl = rpcUrlFor(opts.network, opts.rpcUrl);
// A page without a changelog reads nothing from the chain, so the RPC is only
// required once the writer asks for a block time.
const blockTimes = rpcUrl ? rpcBlockTimes(httpRpcProvider(rpcUrl)) : undefined;

// The network's own namespace also carries its table beside its records. Any
// other namespace keeps the table its deploy wrote, which can hold sections
// this command does not know about, and a page sent elsewhere leaves the
// records untouched.
const paths =
  namespace === opts.network && !opts.outDir && !opts.fileName
    ? await writeNetworkAddressPages({
        deploymentsDir: opts.deploymentsDir,
        network: opts.network,
        blockTimes,
      })
    : [
        await generateAddressMarkdown({
          deploymentsDir: opts.deploymentsDir,
          namespace,
          docName: opts.network,
          outDir: opts.outDir,
          fileName: opts.fileName,
          blockTimes,
        }),
      ];
for (const path of paths) console.log(`Wrote ${path}`);
