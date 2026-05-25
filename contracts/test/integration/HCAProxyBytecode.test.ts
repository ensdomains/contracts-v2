import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const contractsDir = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const proxyLibPath = resolve(contractsDir, "src/hca/ProxyLib.sol");
const execFileAsync = promisify(execFile);

async function readProxyLibConstant(name: string) {
  const source = await readFile(proxyLibPath, "utf8");
  const match = source.match(
    new RegExp(`bytes internal constant ${name}\\s*=\\s*hex"([0-9a-fA-F]+)"`),
  );
  if (!match) throw new Error(`Could not find ProxyLib constant ${name}`);
  return `0x${match[1]}`;
}

async function inspectYulBytecode(path: string, contract: string) {
  const { stdout, stderr, code } = await spawnForge([
    "inspect",
    `${path}:${contract}`,
    "bytecode",
  ]);
  if (code !== 0) {
    throw new Error(`forge inspect failed:\n${stderr}\n${stdout}`);
  }
  const matches = stdout.match(/0x[0-9a-fA-F]+/g);
  if (!matches?.length) {
    throw new Error(`forge inspect produced no bytecode:\n${stderr}\n${stdout}`);
  }
  return matches[matches.length - 1];
}

async function spawnForge(args: string[]) {
  try {
    const { stdout, stderr } = await execFileAsync("forge", args, {
      cwd: contractsDir,
      encoding: "utf8",
      env: forgeEnv(),
    });
    return { stdout, stderr, code: 0 };
  } catch (err) {
    const error = err as {
      stdout?: string;
      stderr?: string;
      code?: number;
    };
    return {
      stdout: error.stdout ?? "",
      stderr: error.stderr ?? "",
      code: error.code ?? 1,
    };
  }
}

function forgeEnv() {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === "string") env[key] = value;
  }
  env.FOUNDRY_PROFILE = "yul";
  return env;
}

describe("HCA proxy bytecode", () => {
  it("matches the initialized proxy Yul source", async () => {
    const [embedded, compiled] = await Promise.all([
      readProxyLibConstant("INITIALIZED_HCA_PROXY_INIT_CODE_PREFIX"),
      inspectYulBytecode("src/hca/HCAProxyInitCode.yul", "HCAProxyInitCode"),
    ]);

    expect(embedded).toEqual(compiled);
  });

  it("matches the uninitialized proxy Yul source", async () => {
    const [embedded, compiled] = await Promise.all([
      readProxyLibConstant("UNINITIALIZED_HCA_PROXY_INIT_CODE_PREFIX"),
      inspectYulBytecode(
        "src/hca/HCAProxyNoInitCode.yul",
        "HCAProxyNoInitCode",
      ),
    ]);

    expect(embedded).toEqual(compiled);
  });
});
