import hre from "hardhat";
import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseEther,
  zeroAddress,
  type Abi,
  type Address,
  type Hex,
  type WalletClient,
} from "viem";
import { describe, expect, it } from "vitest";

import { MAX_EXPIRY, ROLES } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import { idFromLabel } from "../utils/utils.js";
import { waitForSuccessfulTransactionReceipt } from "../utils/waitForSuccessfulTransactionReceipt.ts";

const network = await hre.network.connect();

type GasRow = {
  operation: string;
  gasUsed: bigint;
};

type AccountWalletClient = WalletClient & {
  account: NonNullable<WalletClient["account"]>;
};

async function fixture() {
  const publicClient = await network.viem.getPublicClient();
  const [deployer, user, relayer, other] =
    (await network.viem.getWalletClients()) as AccountWalletClient[];
  const gasRows: GasRow[] = [];

  const parser = await network.viem.deployContract("MockHCAInitDataParser");
  const accountImplementation = await network.viem.deployContract(
    "MockHCAAccountImplementation",
  );
  const executorImplementation = await network.viem.deployContract(
    "MockHCAExecutorImplementation",
  );

  const hcaFactoryArtifact = await hre.artifacts.readArtifact("HCAFactory");
  const deployHash = await deployer.deployContract({
    account: deployer.account,
    chain: null,
    abi: hcaFactoryArtifact.abi as Abi,
    bytecode: hcaFactoryArtifact.bytecode as Hex,
    args: [
      accountImplementation.address,
      parser.address,
      deployer.account.address,
    ],
  });
  const deploymentReceipt = await waitForSuccessfulTransactionReceipt(
    publicClient,
    { hash: deployHash, ensureDeployment: true },
  );

  const hcaFactory = await network.viem.getContractAt(
    "HCAFactory",
    deploymentReceipt.contractAddress,
  );
  const deferredImplementation =
    await hcaFactory.read.deferredImplementation();

  const labelStore = await network.viem.deployContract("LabelStore");
  const registry = await network.viem.deployContract("PermissionedRegistry", [
    hcaFactory.address,
    labelStore.address,
    user.account.address,
    ROLES.ALL,
  ]);
  const resolver = await network.viem.deployContract("OwnedResolver");

  async function recordGas(
    operation: string,
    hash: Hex,
  ) {
    const receipt = await waitForSuccessfulTransactionReceipt(publicClient, {
      hash,
    });
    gasRows.push({ operation, gasUsed: receipt.gasUsed });
    return receipt;
  }

  async function selectImplementation({
    owner,
    implementation,
    operation,
  }: {
    owner: AccountWalletClient;
    implementation: Address;
    operation: string;
  }) {
    const hash = await hcaFactory.write.setAccountImplementation(
      [implementation],
      { account: owner.account },
    );
    await recordGas(operation, hash);
  }

  async function createAccount({
    owner,
    sender = relayer,
    value,
    operation,
  }: {
    owner: AccountWalletClient;
    sender?: AccountWalletClient;
    value?: bigint;
    operation: string;
  }) {
    const initData = encodeAbiParameters(
      [{ type: "address" }],
      [owner.account.address],
    );
    const hca = await hcaFactory.read.computeAccountAddress([
      owner.account.address,
    ]);
    const hash = await hcaFactory.write.createAccount([initData], {
      account: sender.account,
      value,
    });
    const receipt = await recordGas(operation, hash);
    return { hca, initData, receipt };
  }

  async function deployInitializedHCA(owner: AccountWalletClient = user) {
    const { hca, initData } = await createAccount({
      owner,
      operation: "createAccount(current implementation)",
    });
    return {
      hca,
      initData,
      account: await network.viem.getContractAt(
        "MockHCAAccountImplementation",
        hca,
      ),
    };
  }

  async function deployDeferredHCA(owner: AccountWalletClient = user) {
    await selectImplementation({
      owner,
      implementation: deferredImplementation,
      operation: "setAccountImplementation(deferred)",
    });
    const { hca, initData } = await createAccount({
      owner,
      operation: "createAccount(deferred)",
    });
    return {
      hca,
      initData,
      deferred: await network.viem.getContractAt(
        "HCADeferredImplementation",
        hca,
      ),
    };
  }

  function printGasReport(title: string) {
    const totalGas = gasRows.reduce((sum, { gasUsed }) => sum + gasUsed, 0n);
    console.table(
      [
        ...gasRows,
        {
          operation: "total",
          gasUsed: totalGas,
        },
      ].map(({ operation, gasUsed }) => ({
        operation,
        gasUsed: gasUsed.toString(),
      })),
    );
    console.log(`${title} total gas: ${totalGas}`);
  }

  function resetGasRows() {
    gasRows.splice(0, gasRows.length);
  }

  return {
    publicClient,
    deployer,
    user,
    relayer,
    other,
    gasRows,
    parser,
    accountImplementation,
    executorImplementation,
    hcaFactory,
    deferredImplementation,
    labelStore,
    registry,
    resolver,
    recordGas,
    selectImplementation,
    createAccount,
    deployInitializedHCA,
    deployDeferredHCA,
    printGasReport,
    resetGasRows,
  };
}

async function loadFixture() {
  const loadedFixture = await network.networkHelpers.loadFixture(fixture);
  loadedFixture.resetGasRows();
  return loadedFixture;
}

describe("HCAFactory integration", () => {
  it("requires account implementation selection before no-code lookup but not deployment", async () => {
    const F = await loadFixture();
    const initData = encodeAbiParameters(
      [{ type: "address" }],
      [F.user.account.address],
    );

    await expect(
      F.hcaFactory.read.getAccountOwner([F.user.account.address]),
    ).toBeRevertedWithCustomError("HCAImplementationNotSet");

    const hca = await F.hcaFactory.read.computeAccountAddress([
      F.user.account.address,
    ]);
    const deployHash = await F.hcaFactory.write.createAccount([initData], {
      account: F.relayer.account,
    });
    await F.recordGas("createAccount(current implementation)", deployHash);

    const selectedImplementation = await F.hcaFactory.read.accountImplementationOf(
      [F.user.account.address],
    );
    const hcaOwner = await F.hcaFactory.read.getAccountOwner([hca]);
    const account = await network.viem.getContractAt(
      "MockHCAAccountImplementation",
      hca,
    );
    const initializedOwner = await account.read.owner();

    expectVar({ selectedImplementation }).toEqualAddress(zeroAddress);
    expectVar({ hcaOwner }).toEqualAddress(F.user.account.address);
    expectVar({ initializedOwner }).toEqualAddress(F.user.account.address);
    await expect(
      F.hcaFactory.read.getAccountOwner([F.user.account.address]),
    ).toBeRevertedWithCustomError("HCAImplementationNotSet");
    F.printGasReport("default HCA deployment flow");
  });

  it("returns zero for no-code lookup after explicit implementation selection", async () => {
    const F = await loadFixture();

    await F.selectImplementation({
      owner: F.user,
      implementation: F.accountImplementation.address,
      operation: "setAccountImplementation(initialized)",
    });

    const hcaOwner = await F.hcaFactory.read.getAccountOwner([
      F.user.account.address,
    ]);
    expectVar({ hcaOwner }).toEqualAddress(zeroAddress);
  });

  it("deploys an initialized HCA and uses HCA equivalence through registry permissions", async () => {
    const F = await loadFixture();
    const { hca, initData, account } = await F.deployInitializedHCA();
    const label = "alice";

    const registerData = encodeFunctionData({
      abi: F.registry.abi,
      functionName: "register",
      args: [
        label,
        F.user.account.address,
        zeroAddress,
        zeroAddress,
        ROLES.ALL,
        MAX_EXPIRY,
      ],
    });
    const registerHash = await account.write.execute(
      [F.registry.address, registerData],
      { account: F.user.account },
    );
    await F.recordGas("HCA.execute(registry.register)", registerHash);

    const tokenId = await F.registry.read.getTokenId([idFromLabel(label)]);
    const executeData = encodeFunctionData({
      abi: F.registry.abi,
      functionName: "setResolver",
      args: [tokenId, F.resolver.address],
    });
    const executeHash = await account.write.execute(
      [F.registry.address, executeData],
      { account: F.user.account },
    );
    await F.recordGas("HCA.execute(registry.setResolver)", executeHash);

    const code = await F.publicClient.getCode({ address: hca });
    const hcaOwner = await F.hcaFactory.read.getAccountOwner([hca]);
    const initializedOwner = await account.read.owner();
    const lastInitDataHash = await account.read.lastInitDataHash();
    const resolverAddress = await F.registry.read.getResolver([label]);

    expect(code).not.toEqual("0x");
    expectVar({ hcaOwner }).toEqualAddress(F.user.account.address);
    expectVar({ initializedOwner }).toEqualAddress(F.user.account.address);
    expect(lastInitDataHash).toEqual(keccak256(initData));
    expectVar({ resolverAddress }).toEqualAddress(F.resolver.address);
    F.printGasReport("initialized HCA registry flow");
  });

  it("deploys a deferred HCA, upgrades it, and funds the existing account path", async () => {
    const F = await loadFixture();
    const { hca, deferred } = await F.deployDeferredHCA();
    const target = await network.viem.deployContract(
      "MockHCAAccountImplementation",
    );
    const initializeData = encodeFunctionData({
      abi: F.executorImplementation.abi,
      functionName: "initialize",
      args: [F.user.account.address],
    });
    const upgradeHash = await deferred.write.upgradeToAndCall(
      [F.executorImplementation.address, initializeData],
      { account: F.user.account },
    );
    await F.recordGas("deferred.upgradeToAndCall(executor)", upgradeHash);

    const executor = await network.viem.getContractAt(
      "MockHCAExecutorImplementation",
      hca,
    );
    const executeData = encodeFunctionData({
      abi: target.abi,
      functionName: "initializeValue",
      args: [42n],
    });
    const executeHash = await executor.write.execute(
      [target.address, executeData],
      { account: F.user.account },
    );
    await F.recordGas("deferred HCA.execute(target)", executeHash);

    const { hca: existingHca } = await F.createAccount({
      owner: F.user,
      value: parseEther("1"),
      operation: "createAccount(existing funding)",
    });

    const balance = await F.publicClient.getBalance({ address: hca });
    const value = await target.read.value();
    const executorOwner = await executor.read.owner();

    expectVar({ existingHca }).toEqualAddress(hca);
    expect(balance).toEqual(parseEther("1"));
    expect(value).toEqual(42n);
    expectVar({ executorOwner }).toEqualAddress(F.user.account.address);
    F.printGasReport("deferred HCA upgrade and funding flow");
  });
});
