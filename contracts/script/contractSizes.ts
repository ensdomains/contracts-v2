import { artifacts } from "hardhat";

const MAX = 24576; // https://eips.ethereum.org/EIPS/eip-170;

console.table(
  (
    await Promise.allSettled(
      [...(await artifacts.getAllFullyQualifiedNames())]
        .filter((name) => name.startsWith("src/")) // limit to repo
        .map(async (name) => {
          const artifact = await artifacts.readArtifact(name);
          if (artifact.deployedBytecode.startsWith("0x73")) {
            throw new Error("library");
          }
          const byteCount = (artifact.deployedBytecode.length - 2) >> 1;
          return {
            contract: artifact.contractName,
            byteCount,
            Δ: byteCount - MAX,
          };
        }),
    )
  )
    .flatMap((x) =>
      x.status === "fulfilled" && x.value.byteCount > 0 ? x.value : [],
    )
    .sort(
      (a, b) =>
        b.byteCount - a.byteCount || a.contract.localeCompare(b.contract),
    ),
);
console.log("Max:", MAX);
