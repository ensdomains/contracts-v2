import type { TaskOverrideActionFunction } from "hardhat/types/tasks";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const REMAPPINGS_PATH = resolve(
  import.meta.dirname,
  "../../lib/ens-contracts/remappings.txt",
);

// This is for emptying out the remappings.txt in ens-contracts
// so that it doesn't break the build. We already have the remappings for ens-contracts
// in our own local file, but the build process still doesn't like that
// the folders referenced in the ens-contracts remappings don't exist.

const action: TaskOverrideActionFunction = async (task, _hre, runSuper) => {
  const original = await readFile(REMAPPINGS_PATH, "utf8");
  await writeFile(REMAPPINGS_PATH, "");
  try {
    return await runSuper(task);
  } finally {
    await writeFile(REMAPPINGS_PATH, original);
  }
};

export default action;
