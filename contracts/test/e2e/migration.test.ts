import { describe, expect, it } from "bun:test";
import type { AbiParameter, AbiParameterToPrimitiveType } from "abitype";
import {
  type Account,
  type Address,
  encodeAbiParameters,
  type Hex,
  namehash,
  zeroAddress,
} from "viem";
import { STATUS, MAX_EXPIRY, FUSES } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import {
  dnsEncodeName,
  getLabelAt,
  getParentName,
  idFromLabel,
} from "../utils/utils.js";
import {
  bundleCalls,
  COIN_TYPE_ETH,
  type KnownProfile,
  makeResolutions,
} from "../utils/resolutions.js";

// see: LibMigration.sol
const migrationDataComponents = [
  { name: "label", type: "string" },
  { name: "owner", type: "address" },
  { name: "subregistry", type: "address" },
  { name: "resolver", type: "address" },
] as const satisfies AbiParameter[];

type MigrationData = AbiParameterToPrimitiveType<{
  type: "tuple";
  components: typeof migrationDataComponents;
}>;

const defaultProfile = {
  addresses: [
    {
      coinType: COIN_TYPE_ETH,
      value: "0x8000000000000000000000000000000000000001",
    },
  ],
  texts: [{ key: "url", value: "https://ens.domains" }],
  contenthash: { value: "0x12345678" },
} as const satisfies Partial<KnownProfile>;

describe("Migration", () => {
  const { env, setupEnv } = process.env.TEST_GLOBALS!;

  setupEnv({
    resetOnEach: true,
    async initialize() {
      // hack: add controller so we can register() directly
      await env.v1.BaseRegistrar.write.addController(
        [env.namedAccounts.deployer.address],
        { account: env.namedAccounts.owner },
      );
      // set fallback resolver
      await env.v1.BaseRegistrar.write.setResolver(
        [env.v2.ENSV2Resolver.address],
        { account: env.namedAccounts.owner },
      );
    },
  });

  async function ensurePremigration(label: string) {
    const tokenId = idFromLabel(label);
    const expiry = await env.v1.BaseRegistrar.read.nameExpires([tokenId]);
    await env.v2.ETHRegistry.write.register([
      label,
      zeroAddress, // owner (must be null)
      zeroAddress, // registry
      env.v2.ENSV1Resolver.address, // fallback resolver
      0n, // roleBitmap (must be null)
      expiry,
    ]);
  }

  abstract class TokenV1 {
    constructor(
      readonly name: string,
      readonly account: Account,
    ) {}
    get namehash() {
      return namehash(this.name);
    }
    get label() {
      return getLabelAt(this.name);
    }
    abstract get tokenId(): bigint;
    abstract setResolver(address: Address): Promise<void>;
    async makeData(data: Partial<MigrationData> = {}): Promise<MigrationData> {
      const resolver = await env.v1.ENSRegistry.read.resolver([this.namehash]);
      return {
        label: this.label,
        owner: this.account.address,
        subregistry: zeroAddress,
        resolver,
        ...data,
      };
    }
    async setupPublicResolver() {
      await this.setResolver(env.v1.PublicResolver.address);
      const { name, account } = this;
      await env.v1.PublicResolver.write.multicall(
        [makeResolutions({ name, ...defaultProfile }).map((x) => x.write)],
        { account },
      );
    }
    async checkMigrated() {
      const parentRegistry = await env.findPermissionedRegistry({
        name: getParentName(this.name),
      });
      const { status, latestOwner } = await parentRegistry.read.getState([
        idFromLabel(this.label),
      ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(this.account.address);
    }
    async checkResolution() {
      const bundle = bundleCalls(
        makeResolutions({ name: this.name, ...defaultProfile }),
      );
      const [answer1] = await env.v1.UniversalResolver.read.resolve([
        dnsEncodeName(this.name),
        bundle.call,
      ]);
      bundle.expect(answer1);
      const [answer2] = await env.v2.UniversalResolver.read.resolve([
        dnsEncodeName(this.name),
        bundle.call,
      ]);
      bundle.expect(answer2);
    }
  }

  class UnwrappedToken extends TokenV1 {
    get tokenId() {
      return idFromLabel(this.label);
    }
    async setResolver(address: Address) {
      const { name, account } = this;
      await env.v1.ENSRegistry.write.setResolver([namehash(name), address], {
        account,
      });
    }
    async wrap(fuses: number = FUSES.CAN_DO_EVERYTHING) {
      // i think this is simpler than doing it via transfer
      // TODO: check that this is equivalent to transfer
      const { name, account, tokenId, label } = this;
      await env.v1.BaseRegistrar.write.approve(
        [env.v1.NameWrapper.address, tokenId],
        { account },
      );
      await env.v1.NameWrapper.write.wrapETH2LD(
        [label, account.address, fuses, zeroAddress],
        { account },
      );
      return new WrappedToken(name, account);
    }
  }

  class WrappedToken extends TokenV1 {
    get tokenId() {
      return BigInt(this.namehash);
    }
    async setResolver(address: Address) {
      const { name, account } = this;
      await env.v1.NameWrapper.write.setResolver([namehash(name), address], {
        account,
      });
    }
    async createChild({
      label = "sub",
      fuses = FUSES.CAN_DO_EVERYTHING,
      account = this.account,
      expiry = MAX_EXPIRY,
    }: {
      label?: string;
      fuses?: number;
      account?: Account;
      expiry?: bigint;
    } = {}) {
      await env.v1.NameWrapper.write.setSubnodeOwner(
        [this.namehash, label, account.address, fuses, expiry],
        { account: this.account },
      );
      return new WrappedToken(`${label}.${this.name}`, account);
    }
  }

  type BaseRegistrarArgs = {
    label?: string;
    account?: Account;
    duration?: bigint;
  };

  async function registerUnwrapped({
    label = "test",
    account = env.namedAccounts.user,
    duration = 86400n,
  }: BaseRegistrarArgs = {}) {
    await env.v1.BaseRegistrar.write.register([
      idFromLabel(label),
      account.address,
      duration,
    ]);
    await ensurePremigration(label);
    return new UnwrappedToken(`${label}.eth`, account);
  }

  async function registerWrapped(
    args: BaseRegistrarArgs & {
      fuses?: number;
    } = {},
  ) {
    const unwrapped = await registerUnwrapped(args);
    return unwrapped.wrap(args.fuses);
  }

  function encodeMigrationData(v: MigrationData | MigrationData[]): Hex {
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

  describe("helpers", () => {
    it("registerUnwrapped()", async () => {
      await registerUnwrapped();
    });
    it("registerWrapped()", async () => {
      await registerWrapped();
    });
    it("createChild()", async () => {
      const wrapped = await registerWrapped();
      await wrapped.createChild();
    });
  });

  describe("unwrapped", () => {
    it("by owner", async () => {
      const unwrapped = await registerUnwrapped();
      await unwrapped.setupPublicResolver();
      await unwrapped.checkResolution();
      await env.v1.BaseRegistrar.write.safeTransferFrom(
        [
          unwrapped.account.address,
          env.v2.UnlockedMigrationController.address,
          unwrapped.tokenId,
          encodeMigrationData(await unwrapped.makeData()),
        ],
        { account: unwrapped.account },
      );
      await unwrapped.checkMigrated();
      await unwrapped.checkResolution();
    });

    it("wrong controller", async () => {
      const unwrapped = await registerUnwrapped();
      expect(
        env.v1.BaseRegistrar.write.safeTransferFrom(
          [
            unwrapped.account.address,
            env.v2.LockedMigrationController.address, // wrong
            unwrapped.tokenId,
            encodeMigrationData(await unwrapped.makeData()),
          ],
          { account: unwrapped.account },
        ),
      ).rejects.toThrow("ERC721: transfer to non ERC721Receiver implementer");
    });
  });

  describe("unlocked", () => {
    it("by owner", async () => {
      const wrapped = await registerWrapped();
      await wrapped.setupPublicResolver();
      await wrapped.checkResolution();
      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          wrapped.account.address,
          env.v2.UnlockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(await wrapped.makeData()),
        ],
        { account: wrapped.account },
      );
      await wrapped.checkMigrated();
      await wrapped.checkResolution();
    });

    it("wrong controller", async () => {
      const wrapped = await registerWrapped();
      expect(
        env.v1.NameWrapper.write
          .safeTransferFrom(
            [
              wrapped.account.address,
              env.v2.LockedMigrationController.address, // wrong
              wrapped.tokenId,
              1n,
              encodeMigrationData(await wrapped.makeData()),
            ],
            { account: wrapped.account },
          )
          .catch(env.unwrapError),
      ).rejects.toThrow("NameNotLocked");
    });

    it("invalid data", async () => {
      const wrapped = await registerWrapped();
      expect(
        env.v1.NameWrapper.write
          .safeTransferFrom(
            [
              wrapped.account.address,
              env.v2.UnlockedMigrationController.address,
              wrapped.tokenId,
              1n,
              "0x", // wrong
            ],
            { account: wrapped.account },
          )
          .catch(env.unwrapError),
      ).rejects.toThrow("InvalidData");
    });

    it("data mismatch", async () => {
      const wrapped = await registerWrapped();
      expect(
        env.v1.NameWrapper.write
          .safeTransferFrom(
            [
              wrapped.account.address,
              env.v2.UnlockedMigrationController.address,
              wrapped.tokenId,
              1n,
              encodeMigrationData(
                await wrapped.makeData({
                  label: "wrong",
                }),
              ),
            ],
            { account: wrapped.account },
          )
          .catch(env.unwrapError),
      ).rejects.toThrow("NameDataMismatch");
    });
  });

  describe("locked", () => {
    it("by owner", async () => {
      const wrapped = await registerWrapped({ fuses: FUSES.CANNOT_UNWRAP });
      await wrapped.setupPublicResolver();
      await wrapped.checkResolution();
      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          wrapped.account.address,
          env.v2.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(await wrapped.makeData()),
        ],
        { account: wrapped.account },
      );
      await wrapped.checkMigrated();
      await wrapped.checkResolution();
    });

    it("wrong controller", async () => {
      const wrapped = await registerWrapped({ fuses: FUSES.CANNOT_UNWRAP });
      expect(
        env.v1.NameWrapper.write
          .safeTransferFrom(
            [
              wrapped.account.address,
              env.v2.UnlockedMigrationController.address, // wrong
              wrapped.tokenId,
              1n,
              encodeMigrationData(await wrapped.makeData()),
            ],
            { account: wrapped.account },
          )
          .catch(env.unwrapError),
      ).rejects.toThrow("NameIsLocked");
    });

    it("migrated emancipated child", async () => {
      const wrapped = await registerWrapped({ fuses: FUSES.CANNOT_UNWRAP });
      const wrappedChild = await wrapped.createChild({
        fuses: FUSES.PARENT_CANNOT_CONTROL | FUSES.CANNOT_UNWRAP,
      });
      await wrappedChild.setupPublicResolver();
      await wrappedChild.checkResolution();

      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          wrapped.account.address,
          env.v2.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(await wrapped.makeData()),
        ],
        { account: wrapped.account },
      );
      const wrapperRegistry = await env.findWrapperRegistry(wrapped);

      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          wrappedChild.account.address,
          wrapperRegistry.address,
          wrappedChild.tokenId,
          1n,
          encodeMigrationData(await wrappedChild.makeData()),
        ],
        { account: wrappedChild.account },
      );
      await wrappedChild.checkMigrated();
      await wrappedChild.checkResolution();
    });

    it("unmigrated emancipated child", async () => {
      const wrapped = await registerWrapped({ fuses: FUSES.CANNOT_UNWRAP });
      const wrappedChild = await wrapped.createChild({
        fuses: FUSES.PARENT_CANNOT_CONTROL | FUSES.CANNOT_UNWRAP,
      });
      await wrappedChild.setupPublicResolver();

      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          wrapped.account.address,
          env.v2.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(await wrapped.makeData()),
        ],
        { account: wrapped.account },
      );

      // name has fallback resolver
      const wrapperRegistry = await env.findWrapperRegistry(wrapped);
      const resolver = await wrapperRegistry.read.getResolver([
        wrappedChild.label,
      ]);
      expectVar({ resolver }).toEqualAddress(env.v2.ENSV1Resolver.address);

      // name cannot be registered
      expect(
        wrapperRegistry.write.register([
          wrappedChild.label,
          wrappedChild.account.address,
          zeroAddress,
          zeroAddress,
          0n,
          MAX_EXPIRY,
        ]),
      ).rejects.toThrow("NameRequiresMigration");
    });

    it("unmigrated controlled child", async () => {
      const wrapped = await registerWrapped({ fuses: FUSES.CANNOT_UNWRAP });
      const wrappedChild = await wrapped.createChild();
      await wrappedChild.setupPublicResolver();

      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          wrapped.account.address,
          env.v2.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(await wrapped.makeData()),
        ],
        { account: wrapped.account },
      );

      // name has null resolver
      const wrapperRegistry = await env.findWrapperRegistry(wrapped);
      const resolver = await wrapperRegistry.read.getResolver([
        wrappedChild.label,
      ]);
      expectVar({ resolver }).toEqualAddress(zeroAddress);

      // name can be clobbered
      await wrapperRegistry.write.register([
        wrappedChild.label,
        wrappedChild.account.address,
        zeroAddress,
        zeroAddress,
        0n,
        MAX_EXPIRY,
      ]);
    });
  });
});
