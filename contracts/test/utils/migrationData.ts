import {
  encodeAbiParameters,
  type Hex,
  type AbiParameterToPrimitiveType,
} from "viem";

// see: LibMigration.sol
export const migrationDataComponents = [
  { name: "label", type: "string" },
  { name: "owner", type: "address" },
  { name: "subregistry", type: "address" },
  { name: "resolver", type: "address" },
] as const;

export type MigrationData = AbiParameterToPrimitiveType<{
  type: "tuple";
  components: typeof migrationDataComponents;
}>;

export function encodeMigrationData(v: MigrationData | MigrationData[]): Hex {
  if (Array.isArray(v)) {
    return encodeAbiParameters(
      [{ type: "tuple[]", components: migrationDataComponents }],
      [v],
    );
  } else {
    return encodeAbiParameters(
      [{ type: "tuple", components: migrationDataComponents }],
      [v],
    );
  }
}
