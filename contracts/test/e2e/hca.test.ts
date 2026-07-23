import { describe, it } from "bun:test";
import {
  createRhinestoneAccount,
  type RhinestoneAccountConfig,
} from "@rhinestone/sdk";
import { getPermissionId } from "@rhinestone/sdk/smart-sessions";
import {
  type Account,
  type Address,
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  keccak256,
  namehash,
  parseAbiParameters,
  recoverMessageAddress,
  recoverTypedDataAddress,
  size,
  slice,
  type Hex,
  zeroAddress,
  zeroHash,
} from "viem";
import { entryPoint07Address } from "viem/account-abstraction";
import { privateKeyToAccount } from "viem/accounts";

import artifacts from "../../script/artifacts.js";
import { ROLES, STATUS } from "../../script/deploy-constants.js";
import { expect, expectVar } from "../utils/expectVar.js";
import { COIN_TYPE_ETH, getReverseName, idFromLabel } from "../utils/utils.js";

const REGISTRATION_DURATION = 28n * 86400n;
const BURNER_SESSION_SIGNER_KEY =
  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const HCA_USER_SALT = 0n;
const ERC7579_ERC1271_MODE = `0x0201${"00".repeat(30)}` as Hex;
const MOCK_ORCHESTRATOR_URL = "https://hca-orchestrator.invalid";
const MOCK_BUNDLER_URL = "https://hca-bundler.invalid";

type HCAExecution = {
  target: Address;
  value: bigint;
  callData: Hex;
};

type MockIntentInput = {
  account: {
    address: Address;
    accountType: string;
    setupOps: { to: Address; data: Hex }[];
  };
  destinationChainId: number;
  destinationExecutions: { to: Address; value: string; data: Hex }[];
  recipient?: {
    address: Address;
    accountType: string;
    setupOps: { to: Address; data: Hex }[];
  };
};

type MockRouteOptions = {
  arbiter: Address;
  enabledSessionValidator?: Address;
  fundingMethod: "NO_FUNDING" | "PERMIT2";
  settlementLayer: "INTENT_EXECUTOR" | "ACROSS";
  sourceToken?: Address;
  sourceAmount?: bigint;
  gasRefund?: {
    token: Address;
    exchangeRate: bigint;
    overhead: bigint;
  };
  nonce?: bigint;
  targetExecutionNonce?: bigint;
};

type JsonRpcRequest = {
  id: number | string;
  method: string;
  params?: unknown[];
};

function mockIntentRoute(
  input: MockIntentInput,
  {
    arbiter,
    fundingMethod,
    settlementLayer,
    sourceToken = zeroAddress,
    sourceAmount = 0n,
    gasRefund,
    nonce = 1n,
    targetExecutionNonce = 2n,
  }: MockRouteOptions,
) {
  const tokenId = BigInt(sourceToken).toString();
  const amount = sourceAmount.toString();
  const recipient = input.recipient ?? input.account;
  return {
    intentOp: {
      sponsor: zeroAddress,
      nonce: nonce.toString(),
      targetExecutionNonce: targetExecutionNonce.toString(),
      expires: (BigInt(Math.floor(Date.now() / 1000)) + 3600n).toString(),
      elements: [
        {
          arbiter,
          chainId: input.destinationChainId.toString(),
          idsAndAmounts: [[tokenId, amount]],
          spendTokens: [[tokenId, amount]],
          beforeFill: false,
          mandate: {
            recipient: recipient.address,
            tokenOut: [[tokenId, amount]],
            destinationChainId: input.destinationChainId.toString(),
            fillDeadline: (
              BigInt(Math.floor(Date.now() / 1000)) + 1800n
            ).toString(),
            destinationOps: {
              vt: ERC7579_ERC1271_MODE,
              ops: input.destinationExecutions,
            },
            preClaimOps: { vt: ERC7579_ERC1271_MODE, ops: [] },
            qualifier: {
              settlementContext: {
                settlementLayer,
                fundingMethod,
                using7579: true,
                ...(gasRefund && {
                  gasRefund: {
                    token: gasRefund.token,
                    exchangeRate: gasRefund.exchangeRate.toString(),
                    overhead: gasRefund.overhead.toString(),
                  },
                }),
              },
              encodedVal: zeroHash,
            },
            minGas: "0",
          },
        },
      ],
      serverSignature: "0x",
      signedMetadata: {
        fees: {},
        quotes: {},
        tokenPrices: {},
        opGasParams: { estimatedCalldataSize: 0 },
        gasPrices: {},
        account: { ...input.account, accountContext: {} },
        ...(input.recipient && {
          recipient: { ...input.recipient, accountContext: {} },
        }),
      },
    },
    intentCost: {},
  };
}

async function withMockedIntentRoute<T>(
  options: MockRouteOptions,
  run: () => Promise<T>,
): Promise<T> {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input, init) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.href
          : input.url;
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    if (url === `${MOCK_ORCHESTRATOR_URL}/intents/route`) {
      return Response.json(mockIntentRoute(body as MockIntentInput, options));
    }
    if (
      options.enabledSessionValidator &&
      (body as JsonRpcRequest | undefined)?.method === "eth_call"
    ) {
      const request = body as JsonRpcRequest;
      const call = request.params?.[0] as { to?: Address } | undefined;
      if (
        call?.to?.toLowerCase() ===
        options.enabledSessionValidator.toLowerCase()
      ) {
        return Response.json({
          jsonrpc: "2.0",
          id: request.id,
          result: `0x${"00".repeat(31)}01`,
        });
      }
    }
    return originalFetch(input, init);
  }) as typeof globalThis.fetch;
  try {
    return await run();
  } finally {
    globalThis.fetch = originalFetch;
  }
}

describe("Standalone HCA", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  // The devnet deploy scripts deploy the local HCA stack and register its
  // implementation with the default reverse adapter.
  const stack = {
    factory: env.hca.StandaloneHCAFactory,
    executor: env.hca.MockRegistrationIntentExecutor,
    hcaImplementation: env.hca.StandaloneHCAImplementation,
    validator: env.hca.HCAOwnerAndSessionValidator,
  };

  setupEnv({ resetOnEach: true });

  async function standaloneConfig(
    owner: Account,
  ): Promise<RhinestoneAccountConfig> {
    return {
      account: {
        type: "hca",
        version: "ens-standalone-1.1.0",
        factory: stack.factory.address,
        implementation: stack.hcaImplementation.address,
        validator: stack.validator.address,
        verifiableFactory: env.v2.VerifiableFactory.address,
        proxyLogic: await env.v2.VerifiableFactory.read.proxyLogic(),
        userSalt: HCA_USER_SALT,
      },
      owners: {
        type: "ecdsa",
        accounts: [owner],
        module: stack.validator.address,
      },
      experimental_sessions: {
        enabled: true,
        module: stack.validator.address,
      },
    };
  }

  function sdkConfig() {
    return {
      auth: { mode: "apiKey" as const, apiKey: "test" },
      provider: {
        type: "custom" as const,
        urls: { [env.client.chain.id]: `http://${env.hostPort}` },
      },
    };
  }

  function computeOwnerBoundHcaSalt(
    owner: Address,
    implementation: Address,
    userSalt: bigint,
  ): bigint {
    return BigInt(
      keccak256(
        encodeAbiParameters(parseAbiParameters("uint256,address,address"), [
          userSalt,
          owner,
          implementation,
        ]),
      ),
    );
  }

  function computeHcaAddress(
    owner: Address,
    userSalt = HCA_USER_SALT,
  ): Address {
    const deploymentSalt = computeOwnerBoundHcaSalt(
      owner,
      stack.hcaImplementation.address,
      userSalt,
    );
    return env.computeVerifiableProxyAddress(
      stack.factory.address,
      deploymentSalt,
    );
  }

  async function operationData(
    executions: HCAExecution[],
    session = true,
  ): Promise<Hex> {
    return env.client.readContract({
      address: stack.executor.address,
      abi: stack.executor.abi,
      functionName: session ? "encodeSessionOperation" : "encodeOperation",
      args: [executions],
    }) as Promise<Hex>;
  }

  async function signRhinestoneMessage(
    signer: Account,
    digest: Hex,
  ): Promise<Hex> {
    if (!signer.signMessage) {
      throw new Error("HCA e2e signer must support message signing");
    }
    const signature = await signer.signMessage({ message: { raw: digest } });
    const v = Number.parseInt(signature.slice(-2), 16) + 4;
    return `${signature.slice(0, -2)}${v.toString(16).padStart(2, "0")}` as Hex;
  }

  async function buildSessionSignature({
    hca,
    nonce,
    permissionId,
    sessionKey,
    executions,
  }: {
    hca: Address;
    nonce: bigint;
    permissionId: Hex;
    sessionKey: Account;
    executions: HCAExecution[];
  }): Promise<Hex> {
    const data = await operationData(executions);
    const digest = (await env.client.readContract({
      address: stack.executor.address,
      abi: stack.executor.abi,
      functionName: "singleChainDigest",
      args: [hca, nonce, executions],
    })) as Hex;
    return encodePacked(
      ["address", "bytes1", "bytes32", "uint256", "bytes", "bytes"],
      [
        zeroAddress,
        "0x01",
        permissionId,
        nonce,
        data,
        await signRhinestoneMessage(sessionKey, digest),
      ],
    );
  }

  async function executeOwnerIntent({
    hca,
    owner,
    executions,
  }: {
    hca: Address;
    owner: Account;
    executions: HCAExecution[];
  }) {
    const data = await operationData(executions, false);
    const signature = encodePacked(
      ["address", "bytes"],
      [zeroAddress, await signRhinestoneMessage(owner, keccak256(data))],
    );
    await env.waitFor(
      stack.executor.write.execute([hca, executions, signature]),
    );
  }

  async function enableSession({
    hca,
    owner,
    permissionId,
    sessionKey,
    validUntil,
    resolver,
  }: {
    hca: Address;
    owner: Account;
    permissionId: Hex;
    sessionKey: Account;
    validUntil: number;
    resolver: Address;
  }) {
    await executeOwnerIntent({
      hca,
      owner,
      executions: [
        {
          target: stack.validator.address,
          value: 0n,
          callData: encodeFunctionData({
            abi: stack.validator.abi,
            functionName: "enableSession",
            args: [permissionId, sessionKey.address, validUntil, resolver],
          }),
        },
      ],
    });
  }

  // Local E2E deploys separately. A sponsored production route can put deployment and
  // commitment in one intent fill.
  async function deployHCAAndCommit({
    label,
    owner,
    resolver,
    walletPaid = false,
  }: {
    label: string;
    owner: Account;
    resolver: Address;
    walletPaid?: boolean;
  }) {
    const hca = computeHcaAddress(owner.address);
    const commitment = await env.v2.ETHRegistrar.read.makeCommitment([
      label,
      owner.address,
      zeroHash,
      zeroAddress,
      resolver,
      REGISTRATION_DURATION,
      zeroHash,
    ]);

    const hcaCodeBefore = await env.client.getCode({ address: hca });
    const needsDeployment = !hcaCodeBefore || hcaCodeBefore === "0x";
    if (needsDeployment) {
      await env.waitFor(
        stack.factory.write.deploy(
          [owner.address, stack.hcaImplementation.address, HCA_USER_SALT],
          {
            account: walletPaid ? owner : env.namedAccounts.deployer,
          },
        ),
      );
    }

    if (walletPaid) {
      await executeHcaByOwner({
        hca,
        owner,
        executions: [
          {
            target: env.v2.ETHRegistrar.address,
            value: 0n,
            callData: encodeFunctionData({
              abi: env.v2.ETHRegistrar.abi,
              functionName: "commit",
              args: [commitment],
            }),
          },
        ],
      });
    } else {
      await env.waitFor(env.v2.ETHRegistrar.write.commit([commitment]));
    }

    const hcaCodeAfter = await env.client.getCode({ address: hca });
    expectVar({ hcaCodeAfter }).not.toBeUndefined();

    const hcaOwner = (await env.client.readContract({
      address: hca,
      abi: stack.hcaImplementation.abi,
      functionName: "owner",
      args: [],
    })) as Address;
    expectVar({ hcaOwner }).toEqualAddress(owner.address);

    const commitTime = await env.v2.ETHRegistrar.read.commitmentAt([
      commitment,
    ]);
    expectVar({ commitTime }).toBeGreaterThan(0n);

    return { hca, deployed: needsDeployment };
  }

  async function buildRegistrationExecutions({
    label,
    owner,
    hca,
    resolver,
    resolverSalt,
    price,
  }: {
    label: string;
    owner: Account;
    hca: Address;
    resolver: Address;
    resolverSalt: bigint;
    price: bigint;
  }): Promise<HCAExecution[]> {
    const node = namehash(`${label}.eth`);
    const reverseNode = namehash(getReverseName(owner.address));
    const executions: HCAExecution[] = [];

    const resolverCode = await env.client.getCode({ address: resolver });
    if (!resolverCode || resolverCode === "0x") {
      executions.push({
        target: env.v2.VerifiableFactory.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: artifacts.VerifiableFactory.abi,
          functionName: "deployProxy",
          args: [
            env.v2.PermissionedResolverImpl.address,
            resolverSalt,
            encodeFunctionData({
              abi: artifacts.PermissionedResolver.abi,
              functionName: "initialize",
              args: [hca, ROLES.ALL, []],
            }),
          ],
        }),
      });
    }

    executions.push(
      {
        target: env.erc20.MockUSDC.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: env.erc20.MockUSDC.abi,
          functionName: "approve",
          args: [env.v2.ETHRegistrar.address, price],
        }),
      },
      {
        target: env.v2.ETHRegistrar.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: env.v2.ETHRegistrar.abi,
          functionName: "register",
          args: [
            label,
            owner.address,
            zeroHash,
            zeroAddress,
            resolver,
            REGISTRATION_DURATION,
            env.erc20.MockUSDC.address,
            zeroHash,
          ],
        }),
      },
      {
        target: resolver,
        value: 0n,
        callData: encodeFunctionData({
          abi: artifacts.PermissionedResolver.abi,
          functionName: "setAddr",
          args: [node, COIN_TYPE_ETH, owner.address],
        }),
      },
      {
        target: resolver,
        value: 0n,
        callData: encodeFunctionData({
          abi: artifacts.PermissionedResolver.abi,
          functionName: "setText",
          args: [node, "url", `https://example.com/${label}`],
        }),
      },
      {
        target: resolver,
        value: 0n,
        callData: encodeFunctionData({
          abi: artifacts.PermissionedResolver.abi,
          functionName: "setName",
          args: [reverseNode, `${label}.eth`],
        }),
      },
      {
        target: env.shared.DefaultReverseRegistrarAdapter.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: env.shared.DefaultReverseRegistrarAdapter.abi,
          functionName: "setNameWithHCA",
          args: [owner.address, `${label}.eth`],
        }),
      },
      // Make the owner co-admin of its resolver ("0x00" = DNS-encoded root, i.e. root
      // resource) so record management never depends on the disposable HCA. The policy
      // only permits this grant when the grantee is the owner.
      {
        target: resolver,
        value: 0n,
        callData: encodeFunctionData({
          abi: artifacts.PermissionedResolver.abi,
          functionName: "authorizeNameRoles",
          args: ["0x00", ROLES.ALL, owner.address, true],
        }),
      },
    );

    return executions;
  }

  async function prepareRegistration(
    label: string,
    owner: Account,
    { walletPaid = false }: { walletPaid?: boolean } = {},
  ) {
    const hca = computeHcaAddress(owner.address);
    const resolverSalt = env.computeOwnedResolverSalt(hca);
    const resolver = env.computeVerifiableProxyAddress(hca, resolverSalt);

    const [basePrice, premiumPrice] =
      await env.v2.ETHRegistrar.read.getRegisterPrice([
        label,
        REGISTRATION_DURATION,
        env.erc20.MockUSDC.address,
      ]);
    const price = basePrice + premiumPrice;

    await deployHCAAndCommit({ label, owner, resolver, walletPaid });
    await env.erc20.MockUSDC.write.mint([hca, price], {
      account: env.namedAccounts.deployer,
    });
    await env.sync({ warpSec: 61 });

    const executions = await buildRegistrationExecutions({
      label,
      owner,
      hca,
      resolver,
      resolverSalt,
      price,
    });

    return { executions, hca, price, resolver };
  }

  async function executeHcaIntent({
    hca,
    nonce,
    executions,
    signature,
  }: {
    hca: Address;
    nonce: bigint;
    executions: HCAExecution[];
    signature: Hex;
  }) {
    await env.waitFor(
      stack.executor.write.executeWithSession([
        hca,
        executions,
        nonce,
        signature,
      ]),
    );
  }

  async function executeHcaByOwner({
    hca,
    owner,
    executions,
  }: {
    hca: Address;
    owner: Account;
    executions: HCAExecution[];
  }) {
    await env.waitFor(
      env.client.writeContract({
        address: hca,
        abi: stack.hcaImplementation.abi,
        functionName: "executeByOwner",
        args: [executions],
        account: owner,
      }),
    );
  }

  async function expectRegistered({
    label,
    owner,
    hca,
    price,
    resolver,
  }: {
    label: string;
    owner: Account;
    hca: Address;
    price: bigint;
    resolver: Address;
  }) {
    const labelId = idFromLabel(label);
    const node = namehash(`${label}.eth`);
    const reverseNode = namehash(getReverseName(owner.address));

    const state = await env.v2.ETHRegistry.read.getState([labelId]);
    expectVar({ status: state.status }).toStrictEqual(STATUS.REGISTERED);
    expectVar({ latestOwner: state.latestOwner }).toEqualAddress(owner.address);

    const registryResolver = await env.v2.ETHRegistry.read.getResolver([label]);
    expectVar({ registryResolver }).toEqualAddress(resolver);

    const resolverImplementation =
      await env.v2.VerifiableFactory.read.verifyContract([resolver]);
    expectVar({ resolverImplementation }).toEqualAddress(
      env.v2.PermissionedResolverImpl.address,
    );

    const hcaBalance = await env.erc20.MockUSDC.read.balanceOf([hca]);
    expectVar({ hcaBalance }).toStrictEqual(0n);
    expectVar({ price }).toBeGreaterThan(0n);

    const ethAddress = await env.client.readContract({
      address: resolver,
      abi: artifacts.PermissionedResolver.abi,
      functionName: "addr",
      args: [node],
    });
    expectVar({ ethAddress }).toEqualAddress(owner.address);

    const url = await env.client.readContract({
      address: resolver,
      abi: artifacts.PermissionedResolver.abi,
      functionName: "text",
      args: [node, "url"],
    });
    expectVar({ url }).toStrictEqual(`https://example.com/${label}`);

    const reverseResolver = await env.v1.ENSRegistry.read.resolver([
      reverseNode,
    ]);
    expectVar({ reverseResolver }).toEqualAddress(zeroAddress);

    const primary = await env.client.readContract({
      address: resolver,
      abi: artifacts.PermissionedResolver.abi,
      functionName: "name",
      args: [reverseNode],
    });
    expectVar({ primary }).toStrictEqual(`${label}.eth`);

    const defaultPrimary =
      await env.shared.DefaultReverseRegistrar.read.nameForAddr([
        owner.address,
      ]);
    expectVar({ defaultPrimary }).toStrictEqual(`${label}.eth`);

    const ownerIsResolverAdmin = await env.client.readContract({
      address: resolver,
      abi: artifacts.PermissionedResolver.abi,
      functionName: "hasRoles",
      args: [0n, ROLES.ALL, owner.address],
    });
    expectVar({ ownerIsResolverAdmin }).toStrictEqual(true);
  }

  it("deploys an owner-bound HCA once and reuses it", async () => {
    const owner = env.namedAccounts.user;
    const label = "hcastandalone";
    const hca = computeHcaAddress(owner.address);
    const resolverSalt = env.computeOwnedResolverSalt(hca);
    const resolver = env.computeVerifiableProxyAddress(hca, resolverSalt);

    const first = await deployHCAAndCommit({ label, owner, resolver });
    const second = await deployHCAAndCommit({
      label: "hcastandalonesecond",
      owner,
      resolver,
    });

    expectVar({ firstDeployed: first.deployed }).toStrictEqual(true);
    expectVar({ secondHca: second.hca }).toEqualAddress(first.hca);
    expectVar({ secondDeployed: second.deployed }).toStrictEqual(false);

    const implementation = await env.v2.VerifiableFactory.read.verifyContract([
      hca,
    ]);
    expectVar({ implementation }).toEqualAddress(
      stack.hcaImplementation.address,
    );
  });

  it("matches the standalone HCA adapter to the deployed account", async () => {
    const owner = env.namedAccounts.user;
    const config = await standaloneConfig(owner);
    const account = await createRhinestoneAccount({
      ...sdkConfig(),
      ...config,
    });
    const hca = computeHcaAddress(owner.address);
    const sessionKey = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const sdkSession = {
      chain: env.client.chain,
      owners: { type: "ecdsa" as const, accounts: [sessionKey] },
    };
    const permissionId = getPermissionId(sdkSession);

    expectVar({ sdkAddress: account.getAddress() }).toEqualAddress(hca);
    expectVar({ initData: account.getInitData() }).toStrictEqual({
      factory: stack.factory.address,
      factoryData: encodeFunctionData({
        abi: stack.factory.abi,
        functionName: "deploy",
        args: [owner.address, stack.hcaImplementation.address, HCA_USER_SALT],
      }),
    });

    await env.waitFor(
      stack.factory.write.deploy([
        owner.address,
        stack.hcaImplementation.address,
        HCA_USER_SALT,
      ]),
    );
    const currentBlock = await env.client.getBlock();
    await enableSession({
      hca,
      owner,
      permissionId,
      sessionKey,
      validUntil: Number(currentBlock.timestamp + 3600n),
      resolver: zeroAddress,
    });
    expectVar({
      sdkSessionEnabled:
        await account.experimental_isSessionEnabled(sdkSession),
    }).toStrictEqual(true);
    const signature = await account.signTypedData(
      {
        domain: {
          name: "SDK parity",
          version: "1",
          chainId: env.client.chain.id,
          verifyingContract: hca,
        },
        types: { Message: [{ name: "value", type: "bytes32" }] },
        primaryType: "Message",
        message: { value: zeroHash },
      },
      env.client.chain,
      undefined,
    );
    const defaultValidatorPrefix = signature.slice(0, 42) as Address;
    expectVar({ defaultValidatorPrefix }).toEqualAddress(zeroAddress);
    expectVar({ signatureSize: size(signature) }).toStrictEqual(85);

    const existing = await createRhinestoneAccount({
      ...sdkConfig(),
      ...config,
      initData: { address: hca },
    });
    expectVar({ existingAddress: existing.getAddress() }).toEqualAddress(hca);
    expect(() => existing.getInitData()).toThrow();
  });

  it("packs refund-aware fixed sessions through the Rhinestone SDK", async () => {
    const owner = env.namedAccounts.user;
    const config = await standaloneConfig(owner);
    const account = await createRhinestoneAccount({
      ...sdkConfig(),
      ...config,
      endpointUrl: MOCK_ORCHESTRATOR_URL,
    });
    const sessionKey = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const session = {
      chain: env.client.chain,
      owners: { type: "ecdsa" as const, accounts: [sessionKey] },
    };
    const permissionId = getPermissionId(session);
    const refundToken = env.erc20.MockUSDC.address;
    const refundPaymaster = await stack.validator.read.GAS_REFUND_PAYMASTER();
    const maxExchangeRate = 10_000_000_000n;
    const maxGasOverhead = 100_000;
    const maxRefundAmount = 25_000_000n;
    const packedOverhead = (maxRefundAmount << 128n) | BigInt(maxGasOverhead);
    const calls: HCAExecution[] = [
      {
        target: refundToken,
        value: 0n,
        callData: encodeFunctionData({
          abi: env.erc20.MockUSDC.abi,
          functionName: "approve",
          args: [refundPaymaster, maxRefundAmount],
        }),
      },
      {
        target: env.v2.ETHRegistrar.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: env.v2.ETHRegistrar.abi,
          functionName: "commit",
          args: [keccak256("0x1234")],
        }),
      },
    ];
    const targetExecutionNonce = 91n;
    const signed = await withMockedIntentRoute(
      {
        arbiter: stack.executor.address,
        enabledSessionValidator: stack.validator.address,
        fundingMethod: "NO_FUNDING",
        settlementLayer: "INTENT_EXECUTOR",
        gasRefund: {
          token: refundToken,
          exchangeRate: maxExchangeRate,
          overhead: packedOverhead,
        },
        targetExecutionNonce,
      },
      async () => {
        const prepared = await account.prepareTransaction({
          chain: env.client.chain,
          calls: calls.map(({ target: to, value, callData: data }) => ({
            to,
            value,
            data,
          })),
          feeAsset: refundToken,
          sponsored: false,
          signers: {
            type: "experimental_session",
            session,
            verifyExecutions: true,
          },
        });
        return account.signTransaction(prepared);
      },
    );

    const signature = signed.targetExecutionSignature;
    expectVar({ signature }).not.toBeUndefined();
    const operation = await operationData(calls);
    const expectedPrefix = encodePacked(
      [
        "address",
        "bytes1",
        "bytes32",
        "uint256",
        "address",
        "uint256",
        "uint256",
        "bytes",
      ],
      [
        zeroAddress,
        "0x02",
        permissionId,
        targetExecutionNonce,
        refundToken,
        maxExchangeRate,
        packedOverhead,
        operation,
      ],
    );
    expectVar({ signature }).toSatisfy((value: Hex) =>
      value.toLowerCase().startsWith(expectedPrefix.toLowerCase()),
    );
    expectVar({ signatureSize: size(signature!) }).toStrictEqual(
      size(expectedPrefix) + 65,
    );

    const rawSignature = slice(signature!, size(signature!) - 65);
    const v = Number.parseInt(rawSignature.slice(-2), 16);
    expectVar({ v }).toSatisfy((value: number) => value === 31 || value === 32);
  });

  it("reuses one Nexus Permit2 signature for the destination HCA", async () => {
    const owner = env.namedAccounts.user;
    let signatureCount = 0;
    const trackedOwner = {
      ...owner,
      signTypedData: (async (parameters: unknown) => {
        signatureCount += 1;
        return owner.signTypedData(parameters as never);
      }) as typeof owner.signTypedData,
    };
    const recipient = await standaloneConfig(owner);
    const source = await createRhinestoneAccount({
      ...sdkConfig(),
      account: { type: "nexus" },
      owners: { type: "ecdsa", accounts: [trackedOwner] },
      endpointUrl: MOCK_ORCHESTRATOR_URL,
    });
    const sourceAmount = 10_000_000n;
    const paymentToken = env.erc20.MockUSDC.address;
    const signed = await withMockedIntentRoute(
      {
        arbiter: stack.executor.address,
        fundingMethod: "PERMIT2",
        settlementLayer: "ACROSS",
        sourceToken: paymentToken,
        sourceAmount,
      },
      async () => {
        const prepared = await source.prepareTransaction({
          sourceChains: [env.client.chain],
          targetChain: env.client.chain,
          recipient,
          calls: [
            {
              to: env.v2.ETHRegistrar.address,
              value: 0n,
              data: encodeFunctionData({
                abi: env.v2.ETHRegistrar.abi,
                functionName: "commit",
                args: [keccak256("0x5678")],
              }),
            },
          ],
          tokenRequests: [{ address: paymentToken, amount: sourceAmount }],
          sourceAssets: [
            {
              chain: env.client.chain,
              address: paymentToken,
              amount: sourceAmount,
            },
          ],
          settlementLayers: ["ACROSS"],
          sponsored: false,
        });
        return source.signTransaction(prepared);
      },
    );

    expectVar({ signatureCount }).toStrictEqual(1);
    expectVar({
      originSignatureCount: signed.originSignatures.length,
    }).toStrictEqual(1);
    const originSignature = signed.originSignatures[0];
    expectVar({ originSignature }).toSatisfy(
      (value: unknown) => typeof value === "string",
    );
    expectVar({
      destinationSignature: signed.destinationSignature,
    }).toStrictEqual(originSignature);
    expectVar({
      destinationSignatureSize: size(signed.destinationSignature),
    }).toStrictEqual(85);
    expectVar({ destinationSignature: signed.destinationSignature }).toSatisfy(
      (value: Hex) => value.toLowerCase().startsWith(zeroAddress),
    );
    expectVar({
      targetExecutionSignature: signed.targetExecutionSignature,
    }).toBeUndefined();
    const recipientSetup =
      signed.intentRoute.intentOp.signedMetadata.recipient?.setupOps;
    expectVar({ recipientSetupCount: recipientSetup?.length }).toStrictEqual(1);
    expectVar({ recipientFactory: recipientSetup?.[0]?.to }).toEqualAddress(
      stack.factory.address,
    );

    const message = source.getTransactionMessages(signed).origin[0]!;
    const recovered = await recoverTypedDataAddress({
      ...message,
      signature: slice(originSignature as Hex, 20),
    });
    expectVar({ recovered }).toEqualAddress(owner.address);
  });

  it("prepares and signs a fresh standalone HCA UserOperation", async () => {
    const owner = env.namedAccounts.user;
    const config = await standaloneConfig(owner);
    const expectedFactoryData = encodeFunctionData({
      abi: stack.factory.abi,
      functionName: "deploy",
      args: [owner.address, stack.hcaImplementation.address, HCA_USER_SALT],
    });
    const localRpcUrl = `http://${env.hostPort}`;
    const captured: { estimatedUserOperation?: Record<string, unknown> } = {};
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      const url =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.href
            : input.url;
      const request = init?.body
        ? (JSON.parse(String(init.body)) as JsonRpcRequest)
        : undefined;
      if (
        new URL(url).origin === new URL(MOCK_BUNDLER_URL).origin &&
        request?.method === "eth_estimateUserOperationGas"
      ) {
        captured.estimatedUserOperation = request.params?.[0] as Record<
          string,
          unknown
        >;
        return Response.json({
          jsonrpc: "2.0",
          id: request.id,
          result: {
            callGasLimit: "0x186a0",
            preVerificationGas: "0xc350",
            verificationGasLimit: "0x7a120",
          },
        });
      }
      if (
        new URL(url).origin === new URL(localRpcUrl).origin &&
        request?.method === "eth_call"
      ) {
        const call = request.params?.[0] as { to?: Address } | undefined;
        if (call?.to?.toLowerCase() === entryPoint07Address.toLowerCase()) {
          return Response.json({
            jsonrpc: "2.0",
            id: request.id,
            result: `0x${"00".repeat(32)}`,
          });
        }
      }
      return originalFetch(input, init);
    }) as typeof globalThis.fetch;

    try {
      const account = await createRhinestoneAccount({
        ...sdkConfig(),
        ...config,
        bundler: { type: "custom", url: MOCK_BUNDLER_URL },
      });
      const prepared = await account.prepareUserOperation({
        chain: env.client.chain,
        calls: [
          {
            to: env.erc20.MockUSDC.address,
            value: 0n,
            data: "0x",
          },
        ],
      });

      expectVar({ sender: prepared.userOperation.sender }).toEqualAddress(
        account.getAddress(),
      );
      expectVar({ factory: prepared.userOperation.factory }).toEqualAddress(
        stack.factory.address,
      );
      expectVar({
        factoryData: prepared.userOperation.factoryData,
      }).toStrictEqual(expectedFactoryData);
      expectVar({
        estimatedFactory: captured.estimatedUserOperation?.factory,
      }).toStrictEqual(stack.factory.address);
      expectVar({
        estimatedFactoryData: captured.estimatedUserOperation?.factoryData,
      }).toStrictEqual(expectedFactoryData);

      const signed = await account.signUserOperation(prepared);
      expectVar({ signatureSize: size(signed.signature) }).toStrictEqual(65);
      const recovered = await recoverMessageAddress({
        message: { raw: prepared.hash },
        signature: signed.signature,
      });
      expectVar({ recovered }).toEqualAddress(owner.address);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("registers two names through wallet-paid HCA batches without intent signatures", async () => {
    const owner = env.namedAccounts.user;
    const label = "hcadirectowner";
    const { executions, hca, price, resolver } = await prepareRegistration(
      label,
      owner,
      { walletPaid: true },
    );

    await expect(
      executeHcaByOwner({
        hca,
        owner: env.namedAccounts.user2,
        executions,
      }),
    ).rejects.toThrow();
    await executeHcaByOwner({ hca, owner, executions });

    await expectRegistered({ label, owner, hca, price, resolver });

    // The in-batch role grant makes the EOA co-admin: a direct owner record write must
    // succeed without any HCA involvement.
    const node = namehash(`${label}.eth`);
    await env.waitFor(
      env.client.writeContract({
        address: resolver,
        abi: artifacts.PermissionedResolver.abi,
        functionName: "setText",
        args: [node, "com.example", "owner-direct"],
        account: owner,
      }),
    );
    const ownerDirectText = await env.client.readContract({
      address: resolver,
      abi: artifacts.PermissionedResolver.abi,
      functionName: "text",
      args: [node, "com.example"],
    });
    expectVar({ ownerDirectText }).toStrictEqual("owner-direct");

    const secondLabel = "hcadirectownertwo";
    const second = await prepareRegistration(secondLabel, owner, {
      walletPaid: true,
    });
    expectVar({ secondHca: second.hca }).toEqualAddress(hca);
    expectVar({ secondResolver: second.resolver }).toEqualAddress(resolver);
    expectVar({
      redeploysResolver: second.executions.some(
        ({ target }) =>
          target.toLowerCase() ===
          env.v2.VerifiableFactory.address.toLowerCase(),
      ),
    }).toStrictEqual(false);

    await executeHcaByOwner({
      hca: second.hca,
      owner,
      executions: second.executions,
    });
    await expectRegistered({
      label: secondLabel,
      owner,
      hca: second.hca,
      price: second.price,
      resolver: second.resolver,
    });
  });

  it("reuses one owner-enabled session for registration and a later primary change", async () => {
    const owner = env.namedAccounts.user;
    const sessionKey = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const label = "hcasessionkey";
    const { executions, hca, price, resolver } = await prepareRegistration(
      label,
      owner,
    );
    const currentBlock = await env.client.getBlock();
    const validUntil = Number(currentBlock.timestamp + 3600n);
    const permissionId = keccak256(
      encodePacked(["address", "address"], [hca, sessionKey.address]),
    );
    await enableSession({
      hca,
      owner,
      permissionId,
      sessionKey,
      validUntil,
      resolver,
    });

    const blockedExecutions: HCAExecution[] = [
      {
        target: env.namedAccounts.user2.resolver.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: artifacts.PermissionedResolver.abi,
          functionName: "setText",
          args: [namehash(`${label}.eth`), "url", "https://example.com/nope"],
        }),
      },
    ];
    const blockedSignature = await buildSessionSignature({
      hca,
      nonce: 1n,
      permissionId,
      sessionKey,
      executions: blockedExecutions,
    });
    await expect(
      executeHcaIntent({
        hca,
        nonce: 1n,
        executions: blockedExecutions,
        signature: blockedSignature,
      }),
    ).rejects.toThrow();

    const signature = await buildSessionSignature({
      hca,
      nonce: 2n,
      permissionId,
      sessionKey,
      executions,
    });
    await executeHcaIntent({ hca, nonce: 2n, executions, signature });

    await expectRegistered({ label, owner, hca, price, resolver });

    const laterName = `later-${label}.eth`;
    const laterExecutions: HCAExecution[] = [
      {
        target: env.shared.DefaultReverseRegistrarAdapter.address,
        value: 0n,
        callData: encodeFunctionData({
          abi: env.shared.DefaultReverseRegistrarAdapter.abi,
          functionName: "setNameWithHCA",
          args: [owner.address, laterName],
        }),
      },
    ];
    const laterSignature = await buildSessionSignature({
      hca,
      nonce: 3n,
      permissionId,
      sessionKey,
      executions: laterExecutions,
    });
    await executeHcaIntent({
      hca,
      nonce: 3n,
      executions: laterExecutions,
      signature: laterSignature,
    });

    const laterPrimary =
      await env.shared.DefaultReverseRegistrar.read.nameForAddr([
        owner.address,
      ]);
    expectVar({ laterPrimary }).toStrictEqual(laterName);
  });

  it("invalidates a fixed session with the HCA session nonce", async () => {
    const owner = env.namedAccounts.user;
    const sessionKey = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const label = "hcarevokedsession";
    const { executions, hca, resolver } = await prepareRegistration(
      label,
      owner,
    );
    const currentBlock = await env.client.getBlock();
    const validUntil = Number(currentBlock.timestamp + 3600n);
    const permissionId = keccak256(
      encodePacked(["address", "address"], [hca, sessionKey.address]),
    );
    await enableSession({
      hca,
      owner,
      permissionId,
      sessionKey,
      validUntil,
      resolver,
    });

    await env.waitFor(
      env.client.writeContract({
        address: hca,
        abi: stack.hcaImplementation.abi,
        functionName: "revokeSessions",
        account: owner,
      }),
    );

    const signature = await buildSessionSignature({
      hca,
      nonce: 1n,
      permissionId,
      sessionKey,
      executions,
    });
    await expect(
      executeHcaIntent({ hca, nonce: 1n, executions, signature }),
    ).rejects.toThrow();
  });
});
