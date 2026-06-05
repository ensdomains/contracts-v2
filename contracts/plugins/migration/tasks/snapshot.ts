import type { NewTaskActionFunction } from "hardhat/types/tasks";

import { createSnapshot, saveSnapshotFile } from "./snapshot-utils.js";

type SnapshotTaskArgs = {
  file: string;
};

const action: NewTaskActionFunction<SnapshotTaskArgs> = async (args, hre) => {
  const connection = await hre.network.connect();
  try {
    const snapshotId = await createSnapshot(connection.provider);
    console.log(snapshotId);
    if (args.file !== "") {
      await saveSnapshotFile(args.file, snapshotId, connection.networkName);
      console.log(`snapshot file: ${args.file}`);
    }
  } finally {
    await connection.close();
  }
};

export default action;
