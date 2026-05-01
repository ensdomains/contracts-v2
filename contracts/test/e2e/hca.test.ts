import { artifacts } from "@rocketh";
import { describe, it } from "bun:test";
import {
  encodeFunctionData,
  namehash,
  parseUnits,
  zeroAddress,
  zeroHash,
} from "viem";
import { entryPoint07Address } from "viem/account-abstraction";
import { privateKeyToAccount } from "viem/accounts";
import { ROLES, STATUS } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import {
  BURNER_SESSION_SIGNER_KEY,
  createGasReporter,
  createHCATestUtils,
  REGISTRATION_DURATION,
} from "../utils/hca.js";
import { createMockestratorUtils } from "../utils/mockestrator.js";
import { COIN_TYPE_ETH } from "../utils/resolutions.js";
import { idFromLabel } from "../utils/utils.js";

describe("HCA", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  setupEnv({ resetOnEach: true });

  const {
    buildHCAInitCode,
    buildPermit2IntentCallData,
    createHCA,
    executeBatchThroughHCA,
    executeThroughHCA,
    hcaModuleAddress,
    intentExecutorAddress,
  } = createHCATestUtils(env);
  const { executeThroughMockestrator, startMockestrator } =
    createMockestratorUtils(env);

  it("creates an HCA inside handleOps before executing a user operation", async () => {
    const owner = env.namedAccounts.user;
    expectVar({ entryPoint: env.v2.EntryPoint.address }).toEqualAddress(
      entryPoint07Address,
    );
    const gas = createGasReporter("HCA account creation inside handleOps");
    const hca = await env.v2.HCAFactory.read.computeAccountAddress([
      owner.address,
    ]);
    const amount = 123n;

    const hcaCodeBefore = await env.client.getCode({ address: hca });
    expectVar({ hcaCodeBefore }).toBeUndefined();
    const hcaOwnerBefore = await env.v2.HCAFactory.read.getAccountOwner([hca]);
    expectVar({ hcaOwnerBefore }).toEqualAddress(zeroAddress);

    await env.v2.EntryPoint.write.depositTo([hca], {
      account: env.namedAccounts.deployer,
      value: parseUnits("1", 18),
    });

    await executeThroughHCA({
      hca,
      owner,
      initCode: buildHCAInitCode(owner),
      target: env.erc20.MockUSDC.address,
      data: encodeFunctionData({
        abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
        functionName: "approve",
        args: [env.v2.ETHRegistrar.address, amount],
      }),
      gas,
      gasLabel: "handleOps(create account + approve)",
    });

    const hcaCodeAfter = await env.client.getCode({ address: hca });
    expectVar({ hcaCodeAfter }).not.toBeUndefined();
    const hcaOwnerAfter = await env.v2.HCAFactory.read.getAccountOwner([hca]);
    expectVar({ hcaOwnerAfter }).toEqualAddress(owner.address);
    const allowance = await env.erc20.MockUSDC.read.allowance([
      owner.address,
      env.v2.ETHRegistrar.address,
    ]);
    expectVar({ allowance }).toStrictEqual(amount);
    gas.report();
  });

  it("registers an .eth name after the owner authorizes a burner session signer", async () => {
    const owner = env.namedAccounts.user;
    const sessionSigner = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const gas = createGasReporter("HCA session-signer registration");
    const hca = await createHCA(owner);
    const label = "hcasession";
    const labelId = idFromLabel(label);
    const secret = zeroHash;
    const referrer = zeroHash;

    const currentBlock = await env.client.getBlock();
    const sessionExpiration = Number(currentBlock.timestamp + 3600n);
    await executeThroughHCA({
      hca,
      owner,
      target: hcaModuleAddress(),
      data: encodeFunctionData({
        abi: artifacts.HCAModule.abi,
        functionName: "updateConfig",
        args: [
          1n,
          [{ addr: sessionSigner.address, expiration: sessionExpiration }],
          [],
        ],
      }),
      gas,
      gasLabel: "handleOps(authorize session signer)",
    });

    const sessionSignerIsOwner = await env.client.readContract({
      address: hcaModuleAddress(),
      abi: artifacts.HCAModule.abi,
      functionName: "isOwner",
      args: [hca, sessionSigner.address],
    });
    expectVar({ sessionSignerIsOwner }).toBe(true);

    const commitment = await env.v2.ETHRegistrar.read.makeCommitment([
      label,
      owner.address,
      secret,
      zeroAddress,
      zeroAddress,
      REGISTRATION_DURATION,
      referrer,
    ]);
    const [basePrice, premiumPrice] = await env.v2.ETHRegistrar.read.rentPrice([
      label,
      owner.address,
      REGISTRATION_DURATION,
      env.erc20.MockUSDC.address,
    ]);
    const price = basePrice + premiumPrice;

    await env.erc20.MockUSDC.write.mint([owner.address, price], {
      account: env.namedAccounts.deployer,
    });

    await executeBatchThroughHCA({
      hca,
      owner: sessionSigner,
      executions: [
        {
          target: env.erc20.MockUSDC.address,
          data: encodeFunctionData({
            abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
            functionName: "approve",
            args: [env.v2.ETHRegistrar.address, price],
          }),
        },
        {
          target: env.v2.ETHRegistrar.address,
          data: encodeFunctionData({
            abi: artifacts.ETHRegistrar.abi,
            functionName: "commit",
            args: [commitment],
          }),
        },
      ],
      gas,
      gasLabel: "handleOps(approve + commit)",
    });

    await env.sync({ warpSec: 61 });

    await executeBatchThroughHCA({
      hca,
      owner: sessionSigner,
      executions: [
        {
          target: env.v2.ETHRegistrar.address,
          data: encodeFunctionData({
            abi: artifacts.ETHRegistrar.abi,
            functionName: "register",
            args: [
              label,
              owner.address,
              secret,
              zeroAddress,
              zeroAddress,
              REGISTRATION_DURATION,
              env.erc20.MockUSDC.address,
              referrer,
            ],
          }),
        },
        {
          target: env.v2.ETHRegistry.address,
          data: encodeFunctionData({
            abi: artifacts.PermissionedRegistry.abi,
            functionName: "setResolver",
            args: [labelId, owner.resolver.address],
          }),
        },
      ],
      gas,
      gasLabel: "handleOps(register + set resolver)",
    });

    const state = await env.v2.ETHRegistry.read.getState([labelId]);
    expectVar({ status: state.status }).toStrictEqual(STATUS.REGISTERED);
    expectVar({ latestOwner: state.latestOwner }).toEqualAddress(owner.address);
    const resolver = await env.v2.ETHRegistry.read.getResolver([label]);
    expectVar({ resolver }).toEqualAddress(owner.resolver.address);
    gas.report();
  });

  it("registers an .eth name after the owner authorizes a burner session signer from a Permit2-style signature", async () => {
    const owner = env.namedAccounts.user;
    const sessionSigner = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const gas = createGasReporter("HCA Permit2 session authorization registration");
    const hca = await env.v2.HCAFactory.read.computeAccountAddress([
      owner.address,
    ]);
    const label = "hcapermit2session";
    const labelId = idFromLabel(label);
    const secret = zeroHash;
    const referrer = zeroHash;
    const currentBlock = await env.client.getBlock();
    const expires = currentBlock.timestamp + 3600n;
    const sessionExpiration = Number(currentBlock.timestamp + 3600n);
    const resolverNode = namehash(`${label}.eth`);
    const resolverSalt = env.computeOwnedResolverSalt(owner.address, 1n);
    const resolver = env.computeVerifiableProxyAddress(hca, resolverSalt);

    const hcaCodeBefore = await env.client.getCode({ address: hca });
    expectVar({ hcaCodeBefore }).toBeUndefined();
    const hcaOwnerBefore = await env.v2.HCAFactory.read.getAccountOwner([hca]);
    expectVar({ hcaOwnerBefore }).toEqualAddress(zeroAddress);
    const resolverCodeBefore = await env.client.getCode({ address: resolver });
    expectVar({ resolverCodeBefore }).toBeUndefined();

    await env.v2.EntryPoint.write.depositTo([hca], {
      account: env.namedAccounts.deployer,
      value: parseUnits("1", 18),
    });

    const commitment = await env.v2.ETHRegistrar.read.makeCommitment([
      label,
      owner.address,
      secret,
      zeroAddress,
      resolver,
      REGISTRATION_DURATION,
      referrer,
    ]);
    const [basePrice, premiumPrice] = await env.v2.ETHRegistrar.read.rentPrice([
      label,
      owner.address,
      REGISTRATION_DURATION,
      env.erc20.MockUSDC.address,
    ]);
    const price = basePrice + premiumPrice;

    await env.erc20.MockUSDC.write.mint([owner.address, price], {
      account: env.namedAccounts.deployer,
    });

    const authorizeSessionSignerData = await buildPermit2IntentCallData({
      hca,
      signer: owner,
      nonce: 1n,
      expires,
      arbiter: hca,
      executions: [
        {
          target: hcaModuleAddress(),
          value: 0n,
          callData: encodeFunctionData({
            abi: artifacts.HCAModule.abi,
            functionName: "updateConfig",
            args: [
              1n,
              [{ addr: sessionSigner.address, expiration: sessionExpiration }],
              [],
            ],
          }),
        },
      ],
    });

    await executeBatchThroughHCA({
      hca,
      owner,
      initCode: buildHCAInitCode(owner),
      executions: [
        {
          target: intentExecutorAddress(),
          data: authorizeSessionSignerData,
        },
        {
          target: env.erc20.MockUSDC.address,
          data: encodeFunctionData({
            abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
            functionName: "approve",
            args: [env.v2.ETHRegistrar.address, price],
          }),
        },
        {
          target: env.v2.ETHRegistrar.address,
          data: encodeFunctionData({
            abi: artifacts.ETHRegistrar.abi,
            functionName: "commit",
            args: [commitment],
          }),
        },
      ],
      gas,
      gasLabel: "handleOps(create + permit2 + approve + commit)",
    });

    const hcaCodeAfter = await env.client.getCode({ address: hca });
    expectVar({ hcaCodeAfter }).not.toBeUndefined();
    const hcaOwnerAfter = await env.v2.HCAFactory.read.getAccountOwner([hca]);
    expectVar({ hcaOwnerAfter }).toEqualAddress(owner.address);
    const permit2NonceConsumed = await env.client.readContract({
      address: intentExecutorAddress(),
      abi: artifacts.IntentExecutor.abi,
      functionName: "isPermit2IntentNonceConsumed",
      args: [1n, hca],
    });
    expectVar({ permit2NonceConsumed }).toBe(true);
    const sessionSignerIsOwner = await env.client.readContract({
      address: hcaModuleAddress(),
      abi: artifacts.HCAModule.abi,
      functionName: "isOwner",
      args: [hca, sessionSigner.address],
    });
    expectVar({ sessionSignerIsOwner }).toBe(true);
    const commitTime = await env.v2.ETHRegistrar.read.commitmentAt([
      commitment,
    ]);
    expectVar({ commitTime }).toBeGreaterThan(0n);

    await env.sync({ warpSec: 61 });

    await executeBatchThroughHCA({
      hca,
      owner: sessionSigner,
      executions: [
        {
          target: env.v2.ETHRegistrar.address,
          data: encodeFunctionData({
            abi: artifacts.ETHRegistrar.abi,
            functionName: "register",
            args: [
              label,
              owner.address,
              secret,
              zeroAddress,
              resolver,
              REGISTRATION_DURATION,
              env.erc20.MockUSDC.address,
              referrer,
            ],
          }),
        },
        {
          target: env.v2.VerifiableFactory.address,
          data: encodeFunctionData({
            abi: artifacts.VerifiableFactory.abi,
            functionName: "deployProxy",
            args: [
              env.v2.PermissionedResolverImpl.address,
              resolverSalt,
              encodeFunctionData({
                abi: artifacts.PermissionedResolver.abi,
                functionName: "initialize",
                args: [owner.address, ROLES.ALL],
              }),
            ],
          }),
        },
        {
          target: resolver,
          data: encodeFunctionData({
            abi: artifacts.PermissionedResolver.abi,
            functionName: "setAddr",
            args: [resolverNode, COIN_TYPE_ETH, owner.address],
          }),
        },
      ],
      gas,
      gasLabel: "handleOps(register + deploy resolver + set ETH addr)",
    });

    const resolverCodeAfter = await env.client.getCode({ address: resolver });
    expectVar({ resolverCodeAfter }).not.toBeUndefined();
    const state = await env.v2.ETHRegistry.read.getState([labelId]);
    expectVar({ status: state.status }).toStrictEqual(STATUS.REGISTERED);
    expectVar({ latestOwner: state.latestOwner }).toEqualAddress(owner.address);
    const registryResolver = await env.v2.ETHRegistry.read.getResolver([label]);
    expectVar({ registryResolver }).toEqualAddress(resolver);
    const ethAddress = await env.client.readContract({
      address: resolver,
      abi: artifacts.PermissionedResolver.abi,
      functionName: "addr",
      args: [resolverNode],
    });
    expectVar({ ethAddress }).toEqualAddress(owner.address);
    gas.report();
  });

  it("registers an .eth name through an HCA user operation", async () => {
    const owner = env.namedAccounts.user;
    const gas = createGasReporter("HCA owner-signed registration");
    const hca = await createHCA(owner);
    const label = "hcaregistration";
    const labelId = idFromLabel(label);
    const secret = zeroHash;
    const referrer = zeroHash;

    const commitment = await env.v2.ETHRegistrar.read.makeCommitment([
      label,
      owner.address,
      secret,
      zeroAddress,
      zeroAddress,
      REGISTRATION_DURATION,
      referrer,
    ]);
    const [basePrice, premiumPrice] = await env.v2.ETHRegistrar.read.rentPrice([
      label,
      owner.address,
      REGISTRATION_DURATION,
      env.erc20.MockUSDC.address,
    ]);
    const price = basePrice + premiumPrice;

    await env.erc20.MockUSDC.write.mint([owner.address, price], {
      account: env.namedAccounts.deployer,
    });

    await executeThroughHCA({
      hca,
      owner,
      target: env.erc20.MockUSDC.address,
      data: encodeFunctionData({
        abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
        functionName: "approve",
        args: [env.v2.ETHRegistrar.address, price],
      }),
      gas,
      gasLabel: "handleOps(approve payment token)",
    });
    const allowance = await env.erc20.MockUSDC.read.allowance([
      owner.address,
      env.v2.ETHRegistrar.address,
    ]);
    expectVar({ allowance }).toStrictEqual(price);

    await executeThroughHCA({
      hca,
      owner,
      target: env.v2.ETHRegistrar.address,
      data: encodeFunctionData({
        abi: artifacts.ETHRegistrar.abi,
        functionName: "commit",
        args: [commitment],
      }),
      gas,
      gasLabel: "handleOps(commit name)",
    });
    const commitTime = await env.v2.ETHRegistrar.read.commitmentAt([
      commitment,
    ]);
    expectVar({ commitTime }).toBeGreaterThan(0n);

    await env.sync({ warpSec: 61 });

    await executeThroughHCA({
      hca,
      owner,
      target: env.v2.ETHRegistrar.address,
      data: encodeFunctionData({
        abi: artifacts.ETHRegistrar.abi,
        functionName: "register",
        args: [
          label,
          owner.address,
          secret,
          zeroAddress,
          zeroAddress,
          REGISTRATION_DURATION,
          env.erc20.MockUSDC.address,
          referrer,
        ],
      }),
      gas,
      gasLabel: "handleOps(register name)",
    });

    const state = await env.v2.ETHRegistry.read.getState([labelId]);
    expectVar({ status: state.status }).toStrictEqual(STATUS.REGISTERED);
    expectVar({ latestOwner: state.latestOwner }).toEqualAddress(owner.address);
    const ownerBalance = await env.erc20.MockUSDC.read.balanceOf([
      owner.address,
    ]);
    expectVar({ ownerBalance }).toStrictEqual(0n);

    await executeThroughHCA({
      hca,
      owner,
      target: env.v2.ETHRegistry.address,
      data: encodeFunctionData({
        abi: artifacts.PermissionedRegistry.abi,
        functionName: "setResolver",
        args: [labelId, owner.resolver.address],
      }),
      gas,
      gasLabel: "handleOps(set resolver)",
    });

    const resolver = await env.v2.ETHRegistry.read.getResolver([label]);
    expectVar({ resolver }).toEqualAddress(owner.resolver.address);
    gas.report();
  });

  it("registers an .eth name through mockestrator HCA destination executions", async () => {
    const owner = env.namedAccounts.user;
    const gas = createGasReporter("HCA mockestrator registration");
    const hca = await createHCA(owner);
    const label = "hcamockestrator";
    const labelId = idFromLabel(label);
    const secret = zeroHash;
    const referrer = zeroHash;
    const mockestrator = await startMockestrator();

    try {
      await env.client.setBalance({
        address: hca,
        value: parseUnits("1", 18),
      });

      const commitment = await env.v2.ETHRegistrar.read.makeCommitment([
        label,
        owner.address,
        secret,
        zeroAddress,
        zeroAddress,
        REGISTRATION_DURATION,
        referrer,
      ]);
      const [basePrice, premiumPrice] =
        await env.v2.ETHRegistrar.read.rentPrice([
          label,
          owner.address,
          REGISTRATION_DURATION,
          env.erc20.MockUSDC.address,
        ]);
      const price = basePrice + premiumPrice;

      await env.erc20.MockUSDC.write.mint([owner.address, price], {
        account: env.namedAccounts.deployer,
      });

      const commitStatus = await executeThroughMockestrator({
        mockestrator,
        hca,
        executions: [
          {
            to: env.erc20.MockUSDC.address,
            data: encodeFunctionData({
              abi: artifacts["test/mocks/MockERC20.sol/MockERC20"].abi,
              functionName: "approve",
              args: [env.v2.ETHRegistrar.address, price],
            }),
          },
          {
            to: env.v2.ETHRegistrar.address,
            data: encodeFunctionData({
              abi: artifacts.ETHRegistrar.abi,
              functionName: "commit",
              args: [commitment],
            }),
          },
        ],
      });
      expectVar({ commitStatus: commitStatus.status }).toStrictEqual(
        "COMPLETED",
      );
      gas.record(
        "mockestrator(approve + commit)",
        await env.waitFor(commitStatus.fillTransactionHash),
      );
      const commitTime = await env.v2.ETHRegistrar.read.commitmentAt([
        commitment,
      ]);
      expectVar({ commitTime }).toBeGreaterThan(0n);

      await env.sync({ warpSec: 61 });

      const registerStatus = await executeThroughMockestrator({
        mockestrator,
        hca,
        executions: [
          {
            to: env.v2.ETHRegistrar.address,
            data: encodeFunctionData({
              abi: artifacts.ETHRegistrar.abi,
              functionName: "register",
              args: [
                label,
                owner.address,
                secret,
                zeroAddress,
                zeroAddress,
                REGISTRATION_DURATION,
                env.erc20.MockUSDC.address,
                referrer,
              ],
            }),
          },
          {
            to: env.v2.ETHRegistry.address,
            data: encodeFunctionData({
              abi: artifacts.PermissionedRegistry.abi,
              functionName: "setResolver",
              args: [labelId, owner.resolver.address],
            }),
          },
        ],
      });
      expectVar({ registerStatus: registerStatus.status }).toStrictEqual(
        "COMPLETED",
      );
      gas.record(
        "mockestrator(register + set resolver)",
        await env.waitFor(registerStatus.fillTransactionHash),
      );

      const state = await env.v2.ETHRegistry.read.getState([labelId]);
      expectVar({ status: state.status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner: state.latestOwner }).toEqualAddress(
        owner.address,
      );
      const resolver = await env.v2.ETHRegistry.read.getResolver([label]);
      expectVar({ resolver }).toEqualAddress(owner.resolver.address);
      gas.report();
    } finally {
      await mockestrator.stop();
    }
  }, 180_000);
});
