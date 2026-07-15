import { describe, it } from "bun:test";
import {
  type Account,
  type Address,
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  keccak256,
  namehash,
  parseAbiParameters,
  stringToHex,
  type Hex,
  zeroAddress,
  zeroHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import artifacts from "../../script/artifacts.js";
import { ROLES, STATUS } from "../../script/deploy-constants.js";
import { expect, expectVar } from "../utils/expectVar.js";
import {
  PERMIT2_ADDRESS,
  type Permit2SessionAuthorization,
  permit2SessionDigest,
  SESSION_GRANT_TYPEHASH,
} from "../utils/hcaSessions.js";
import {
  COIN_TYPE_ETH,
  getReverseName,
  idFromLabel,
} from "../utils/utils.js";

const REGISTRATION_DURATION = 28n * 86400n;
const BURNER_SESSION_SIGNER_KEY =
  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const PERMIT2_SOURCE_CHAIN_ID = 8453n;

type HCAExecution = {
  target: Address;
  value: bigint;
  callData: Hex;
};

describe("Standalone HCA", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  // The devnet deploy scripts (deploy/hca/00-04) deploy the full HCA stack and
  // register the implementation with the default reverse adapter, so the e2e
  // exercises the same pipeline that ships to real networks.
  const stack = {
    bootstrapper: env.hca.RegistrationBootstrapper,
    executor: env.hca.HCARegistrationIntentExecutor,
    hcaImplementation: env.hca.StandaloneHCAImplementation,
    validator: env.hca.OwnerBoundRegistrationSessionValidator,
  };

  setupEnv({ resetOnEach: true });

  function computeStandaloneHcaSalt(label: string): bigint {
    return BigInt(keccak256(stringToHex(`StandaloneHCA:${label}`)));
  }

  function encodeHCAInitializeCall(owner: Address): Hex {
    return encodeFunctionData({
      abi: stack.hcaImplementation.abi,
      functionName: "initializeAccount",
      args: [encodeAbiParameters(parseAbiParameters("address"), [owner])],
    });
  }

  async function signRawHash(signer: Account, hash: Hex): Promise<Hex> {
    const rawSigner = signer as Account & {
      sign?: ({ hash }: { hash: Hex }) => Promise<Hex>;
    };
    if (!rawSigner.sign) {
      throw new Error("HCA e2e signer account must support raw signing");
    }
    return rawSigner.sign({ hash });
  }

  async function operationData(executions: HCAExecution[]): Promise<Hex> {
    return env.client.readContract({
      address: stack.executor.address,
      abi: stack.executor.abi,
      functionName: "encodeOperation",
      args: [executions],
    }) as Promise<Hex>;
  }

  async function signLegacySessionGrant({
    hca,
    owner,
    sessionKey,
    validUntil,
    resolver,
    sessionNonce = 0n,
  }: {
    hca: Address;
    owner: Account;
    sessionKey: Account;
    validUntil: number;
    resolver: Address;
    sessionNonce?: bigint;
  }): Promise<Hex> {
    const grantHash = keccak256(
      encodeAbiParameters(
        parseAbiParameters(
          "bytes32,uint256,address,address,address,uint48,address,uint256",
        ),
        [
          SESSION_GRANT_TYPEHASH,
          BigInt(env.client.chain.id),
          hca,
          owner.address,
          sessionKey.address,
          validUntil,
          resolver,
          sessionNonce,
        ],
      ),
    );
    if (!owner.signMessage) {
      throw new Error("HCA e2e owner account must support message signing");
    }
    return owner.signMessage({ message: { raw: grantHash } });
  }

  async function buildHcaSignature({
    hca,
    owner,
    sessionKey,
    validUntil = 0,
    resolver,
    // Account session-grant nonce; 0 for a not-yet-deployed (counterfactual) HCA.
    sessionNonce = 0n,
    executions,
    permit2,
    sessionGrantSignature,
  }: {
    hca: Address;
    owner: Account;
    sessionKey?: Account;
    validUntil?: number;
    resolver: Address;
    sessionNonce?: bigint;
    executions: HCAExecution[];
    permit2?: Permit2SessionAuthorization;
    sessionGrantSignature?: Hex;
  }): Promise<Hex> {
    const data = await operationData(executions);
    const digest = keccak256(data);
    const sessionKeyAddress = sessionKey?.address ?? zeroAddress;
    let ownerSignature: Hex;
    let sessionSignature: Hex = "0x";

    if (sessionKey) {
      if (sessionGrantSignature) {
        ownerSignature = sessionGrantSignature;
      } else if (permit2) {
        ownerSignature = await signRawHash(
          owner,
          permit2SessionDigest({
            chainId: BigInt(env.client.chain.id),
            hca,
            owner: owner.address,
            sessionKey: sessionKey.address,
            validUntil,
            resolver,
            sessionNonce,
            permit2,
          }),
        );
      } else {
        ownerSignature = await signLegacySessionGrant({
          hca,
          owner,
          sessionKey,
          validUntil,
          resolver,
          sessionNonce,
        });
      }
      sessionSignature = await signRawHash(sessionKey, digest);
    } else {
      ownerSignature = await signRawHash(owner, digest);
    }

    const body = encodeAbiParameters(
      parseAbiParameters(
        "address,address,uint48,address,uint256,address,address,uint256,uint256,bytes,bytes,bytes",
      ),
      [
        owner.address,
        sessionKeyAddress,
        validUntil,
        resolver,
        permit2?.sourceChainId ?? 0n,
        permit2?.permit2Contract ?? zeroAddress,
        permit2?.arbiter ?? zeroAddress,
        permit2?.nonce ?? 0n,
        permit2?.expires ?? 0n,
        ownerSignature,
        sessionSignature,
        data,
      ],
    );

    return encodePacked(["address", "bytes"], [zeroAddress, body]);
  }

  async function deployHCAAndCommit({
    label,
    owner,
    resolver,
  }: {
    label: string;
    owner: Account;
    resolver: Address;
  }) {
    const salt = computeStandaloneHcaSalt(label);
    const hca = env.computeVerifiableProxyAddress(
      stack.bootstrapper.address,
      salt,
    );
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
    expectVar({ hcaCodeBefore }).toBeUndefined();

    await env.waitFor(
      stack.bootstrapper.write.deployAndCommit([
        env.v2.VerifiableFactory.address,
        stack.hcaImplementation.address,
        salt,
        encodeHCAInitializeCall(owner.address),
        env.v2.ETHRegistrar.address,
        commitment,
      ]),
    );

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

    return { hca, salt };
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

    return [
      {
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
      },
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
    ];
  }

  async function prepareRegistration(label: string, owner: Account) {
    const hcaSalt = computeStandaloneHcaSalt(label);
    const hca = env.computeVerifiableProxyAddress(
      stack.bootstrapper.address,
      hcaSalt,
    );
    const resolverSalt = env.computeOwnedResolverSalt(hca);
    const resolver = env.computeVerifiableProxyAddress(hca, resolverSalt);

    const [basePrice, premiumPrice] =
      await env.v2.ETHRegistrar.read.getRegisterPrice([
        label,
        REGISTRATION_DURATION,
        env.erc20.MockUSDC.address,
      ]);
    const price = basePrice + premiumPrice;

    await deployHCAAndCommit({ label, owner, resolver });
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
    executions,
    signature,
  }: {
    hca: Address;
    executions: HCAExecution[];
    signature: Hex;
  }) {
    await env.waitFor(
      stack.executor.write.execute([hca, executions, signature]),
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

    const registryResolver = await env.v2.ETHRegistry.read.getResolver([
      label,
    ]);
    expectVar({ registryResolver }).toEqualAddress(resolver);

    const resolverImplementation = await env.v2.VerifiableFactory.read.verifyContract([
      resolver,
    ]);
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

    const defaultPrimary = await env.shared.DefaultReverseRegistrar.read.nameForAddr([
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

  it("deploys a standalone HCA and commits through the registration bootstrapper", async () => {
    const owner = env.namedAccounts.user;
    const label = "hcastandalone";
    const hcaSalt = computeStandaloneHcaSalt(label);
    const hca = env.computeVerifiableProxyAddress(
      stack.bootstrapper.address,
      hcaSalt,
    );
    const resolverSalt = env.computeOwnedResolverSalt(hca);
    const resolver = env.computeVerifiableProxyAddress(hca, resolverSalt);

    await deployHCAAndCommit({ label, owner, resolver });

    const implementation = await env.v2.VerifiableFactory.read.verifyContract([
      hca,
    ]);
    expectVar({ implementation }).toEqualAddress(stack.hcaImplementation.address);
  });

  it("registers and configures an .eth name with a direct owner signature", async () => {
    const owner = env.namedAccounts.user;
    const label = "hcadirectowner";
    const { executions, hca, price, resolver } = await prepareRegistration(
      label,
      owner,
    );

    const signature = await buildHcaSignature({
      hca,
      owner,
      resolver,
      executions,
    });
    await executeHcaIntent({ hca, executions, signature });

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
  });

  it("reuses one owner-granted session for registration and a later primary change", async () => {
    const owner = env.namedAccounts.user;
    const sessionKey = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const label = "hcasessionkey";
    const { executions, hca, price, resolver } = await prepareRegistration(
      label,
      owner,
    );
    const currentBlock = await env.client.getBlock();
    const validUntil = Number(currentBlock.timestamp + 3600n);
    const sessionGrantSignature = await signLegacySessionGrant({
      hca,
      owner,
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
    const blockedSignature = await buildHcaSignature({
      hca,
      owner,
      sessionKey,
      validUntil,
      resolver,
      executions: blockedExecutions,
    });
    await expect(
      stack.executor.write.execute([
        hca,
        blockedExecutions,
        blockedSignature,
      ]),
    ).rejects.toThrow();

    const signature = await buildHcaSignature({
      hca,
      owner,
      sessionKey,
      validUntil,
      resolver,
      executions,
      sessionGrantSignature,
    });
    await executeHcaIntent({ hca, executions, signature });

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
    const laterSignature = await buildHcaSignature({
      hca,
      owner,
      sessionKey,
      validUntil,
      resolver,
      executions: laterExecutions,
      sessionGrantSignature,
    });
    await executeHcaIntent({
      hca,
      executions: laterExecutions,
      signature: laterSignature,
    });

    const laterPrimary = await env.shared.DefaultReverseRegistrar.read.nameForAddr([
      owner.address,
    ]);
    expectVar({ laterPrimary }).toStrictEqual(laterName);
  });

  it("registers with a Permit2-originated session key and rejects a resolver outside the grant", async () => {
    const owner = env.namedAccounts.user;
    const sessionKey = privateKeyToAccount(BURNER_SESSION_SIGNER_KEY);
    const label = "hcapermit2session";
    const { executions, hca, price, resolver } = await prepareRegistration(
      label,
      owner,
    );
    const currentBlock = await env.client.getBlock();
    const validUntil = Number(currentBlock.timestamp + 3600n);
    const permit2 = {
      sourceChainId: PERMIT2_SOURCE_CHAIN_ID,
      permit2Contract: PERMIT2_ADDRESS as Address,
      arbiter: hca,
      nonce: 7n,
      expires: currentBlock.timestamp + 3600n,
    };

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
    const blockedSignature = await buildHcaSignature({
      hca,
      owner,
      sessionKey,
      validUntil,
      resolver,
      executions: blockedExecutions,
      permit2,
    });
    await expect(
      stack.executor.write.execute([
        hca,
        blockedExecutions,
        blockedSignature,
      ]),
    ).rejects.toThrow();

    const signature = await buildHcaSignature({
      hca,
      owner,
      sessionKey,
      validUntil,
      resolver,
      executions,
      permit2,
    });
    await executeHcaIntent({ hca, executions, signature });

    await expectRegistered({ label, owner, hca, price, resolver });
  });
});
