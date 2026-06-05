import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

export async function createSnapshot(
  provider: { request(args: { method: string; params?: unknown[] }): Promise<unknown> },
): Promise<string> {
  const snapshotId = await provider.request({ method: "evm_snapshot", params: [] });
  if (typeof snapshotId !== "string") {
    throw new Error(`unexpected evm_snapshot response: ${String(snapshotId)}`);
  }
  return snapshotId;
}

export async function saveSnapshotFile(path: string, snapshotId: string, network: string) {
  const filePath = resolve(path);
  await mkdir(dirname(filePath), { recursive: true });
  await writeFile(
    filePath,
    `${JSON.stringify({
      network,
      snapshotId,
      createdAt: new Date().toISOString(),
    }, null, 2)}\n`,
  );
}

export async function readSnapshotFile(path: string): Promise<string> {
  const contents = await readFile(resolve(path), "utf8");
  try {
    const parsed = JSON.parse(contents);
    if (typeof parsed.snapshotId === "string") return parsed.snapshotId;
  } catch {
    // Plain snapshot id files are also accepted.
  }
  const snapshotId = contents.trim();
  if (!snapshotId) throw new Error(`snapshot file is empty: ${path}`);
  return snapshotId;
}
