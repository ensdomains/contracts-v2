import { existsSync, unlinkSync, writeFileSync, readFileSync } from "node:fs";
import {
  createFreshCheckpoint,
  type Checkpoint,
} from "../../script/preMigration.js";

const DEFAULT_CHECKPOINT_FILE = "preMigration-checkpoint.json";

export function createTestCheckpoint(
  overrides: Partial<Checkpoint> = {},
): Checkpoint {
  return {
    ...createFreshCheckpoint(),
    ...overrides,
  };
}

export function writeTestCheckpoint(
  checkpoint: Checkpoint,
  filename: string = DEFAULT_CHECKPOINT_FILE,
) {
  writeFileSync(filename, JSON.stringify(checkpoint, null, 2));
}

export function readTestCheckpoint(
  filename: string = DEFAULT_CHECKPOINT_FILE,
): Checkpoint | null {
  if (!existsSync(filename)) return null;
  return JSON.parse(readFileSync(filename, "utf-8"));
}

export function deleteTestCheckpoint(
  filename: string = DEFAULT_CHECKPOINT_FILE,
) {
  if (existsSync(filename)) {
    unlinkSync(filename);
  }
}
