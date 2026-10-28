#!/usr/bin/env bun
import { Command } from "commander";
import { resolve } from "node:path";
import { generateAddressMarkdown } from "./addressDocs.js";

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
  );

program.parse(process.argv);
const opts = program.opts<{
  network: string;
  namespace?: string;
  deploymentsDir: string;
  outDir?: string;
  fileName?: string;
}>();

const outPath = await generateAddressMarkdown({
  deploymentsDir: opts.deploymentsDir,
  namespace: opts.namespace ?? opts.network,
  docName: opts.network,
  outDir: opts.outDir,
  fileName: opts.fileName,
});

console.log(`Wrote ${outPath}`);
