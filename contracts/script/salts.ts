import { encodeAbiParameters, keccak256, stringToHex } from "viem";

export function computeLockedMigrationControllerSalt(version = 0n) {
  return BigInt(
    keccak256(
      encodeAbiParameters(
        [
          { name: "id", type: "bytes32" },
          { name: "version", type: "uint256" },
        ],
        [keccak256(stringToHex("LockedMigrationController")), version],
      ),
    ),
  );
}
