import * as generatedAbis from "generated/abis/index.ts";
import * as generatedArtifacts from "generated/artifacts/index.ts";

type Artifact<TAbi extends readonly unknown[] = readonly unknown[]> = {
  abi: TAbi;
  bytecode: `0x${string}`;
  deployedBytecode?: `0x${string}`;
  metadata?: string;
  contractName?: string;
  sourceName?: string;
};

const interfaceArtifact = <TAbi extends readonly unknown[]>(
  abi: TAbi,
): Artifact<TAbi> => ({
  abi,
  bytecode: "0x",
  metadata: "",
});

const artifacts = {
  ...generatedArtifacts,
  IAddressSet: interfaceArtifact(generatedAbis.IAddressSet),
  IContractNamer: interfaceArtifact(generatedAbis.IContractNamer),
  IETHRegistrarController: interfaceArtifact(
    generatedAbis.IETHRegistrarController,
  ),
  ILabelStore: interfaceArtifact(generatedAbis.ILabelStore),
  INameWrapper: interfaceArtifact(generatedAbis.INameWrapper),
  IRentPriceOracle: interfaceArtifact(generatedAbis.IRentPriceOracle),
  IWrappedETHRegistrarController: interfaceArtifact(
    generatedAbis.IWrappedETHRegistrarController,
  ),
  MigrationHelper:
    generatedArtifacts.src_migration_MigrationHelper_sol_MigrationHelper,
  "test/mocks/MockERC20.sol/MockERC20":
    generatedArtifacts.test_mocks_MockERC20_sol_MockERC20,
};

export default artifacts;
