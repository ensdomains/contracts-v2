import { describe, it } from "bun:test";
import type { AbiParameter, AbiParameterToPrimitiveType } from "abitype";
import {
  type Account,
  type Address,
  encodeAbiParameters,
  getContract,
  type Hex,
  labelhash,
  namehash,
  zeroAddress,
} from "viem";
import { STATUS, MAX_EXPIRY, FUSES } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import { getLabelAt, idFromLabel } from "../utils/utils.js";

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
    },
  });

  async function ensurePremigration(label: string) {
    const tokenId = BigInt(labelhash(label));
    const expiry = await env.v1.BaseRegistrar.read.nameExpires([tokenId]);
    await env.v2.ETHRegistry.write.register([
      label,
      zeroAddress, // owner (must be null)
      zeroAddress, // registry
      env.v2.ENSV1Resolver.address,
      0n, // roleBitmap (must be null)
      expiry,
    ]);
  }

  class WrappedToken {
    constructor(
      readonly name: string,
      readonly account: Account,
    ) {}
    get namehash() {
      return namehash(this.name);
    }
    get tokenId() {
      return BigInt(this.namehash);
    }
    label(i = 0) {
      return getLabelAt(this.name, i);
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
    makeData(data: Partial<MigrationData> = {}): MigrationData {
      return {
        label: this.label(),
        owner: this.account.address,
        subregistry: zeroAddress,
        resolver: zeroAddress,
        ...data,
      };
    }
  }

  async function registerUnwrapped({
    label = "test",
    account = env.namedAccounts.user,
    duration = 86400n,
  }: {
    label?: string;
    account?: Account;
    duration?: bigint;
  } = {}) {
    const unwrappedTokenId = BigInt(labelhash(label));
    await env.v1.BaseRegistrar.write.register([
      unwrappedTokenId,
      account.address,
      duration,
    ]);
    await ensurePremigration(label);
    const name = `${label}.eth`;
    return {
      label,
      name,
      account,
      unwrappedTokenId,
      makeData,
      wrap,
    };
    function makeData(data: Partial<MigrationData> = {}) {
      return {
        label,
        owner: account.address,
        subregistry: zeroAddress,
        resolver: zeroAddress,
        ...data,
      };
    }
    async function wrap(fuses: number = FUSES.CAN_DO_EVERYTHING) {
      // i think this is simpler than doing it via transfer
      // TODO: check that this is equivalent to transfer
      await env.v1.BaseRegistrar.write.approve(
        [env.v1.NameWrapper.address, unwrappedTokenId],
        { account },
      );
      await env.v1.NameWrapper.write.wrapETH2LD(
        [label, account.address, fuses, zeroAddress],
        { account },
      );
      return new WrappedToken(name, account);
    }
  }

  function asWrapperRegistry(address: Address, account: Account) {
    return getContract({
      abi: env.v2.WrapperRegistryImpl.abi,
      address,
      client: env.createClient(account),
    });
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
    it("wrap()", async () => {
      const { wrap } = await registerUnwrapped();
      await wrap();
    });
    it("createChild()", async () => {
      const { wrap } = await registerUnwrapped();
      const wrapped = await wrap();
      await wrapped.createChild();
    });
  });

  describe("unwrapped", () => {
    it("by owner", async () => {
      const { account, unwrappedTokenId, makeData } = await registerUnwrapped();
      await env.v1.BaseRegistrar.write.safeTransferFrom(
        [
          account.address,
          env.v2.UnlockedMigrationController.address,
          unwrappedTokenId,
          encodeMigrationData(makeData()),
        ],
        { account },
      );
      const { status, latestOwner } = await env.v2.ETHRegistry.read.getState([
        unwrappedTokenId,
      ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(account.address);
    });
  });

  describe("unlocked", () => {
    it("by owner", async () => {
      const { account, unwrappedTokenId, wrap } = await registerUnwrapped();
      const wrapped = await wrap();
      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          account.address,
          env.v2.UnlockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(wrapped.makeData()),
        ],
        { account },
      );
      const { status, latestOwner } = await env.v2.ETHRegistry.read.getState([
        unwrappedTokenId,
      ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(account.address);
    });
  });

  describe("locked", () => {
    it("by owner", async () => {
      const { account, unwrappedTokenId, wrap } = await registerUnwrapped();
      const wrapped = await wrap(FUSES.CANNOT_UNWRAP);
      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          account.address,
          env.v2.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(wrapped.makeData()),
        ],
        { account },
      );
      const { status, latestOwner } = await env.v2.ETHRegistry.read.getState([
        unwrappedTokenId,
      ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(account.address);
    });

    it("emancipated children", async () => {
      const { account, wrap } = await registerUnwrapped();
      const wrapped = await wrap(FUSES.CANNOT_UNWRAP);
      const wrappedChild = await wrapped.createChild({
        fuses: FUSES.PARENT_CANNOT_CONTROL | FUSES.CANNOT_UNWRAP,
      });

      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          account.address,
          env.v2.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(wrapped.makeData()),
        ],
        { account },
      );

      const wrapperRegistry = asWrapperRegistry(
        await env.v2.ETHRegistry.read.getSubregistry([wrapped.label()]),
        wrapped.account,
      );

      await env.v1.NameWrapper.write.safeTransferFrom(
        [
          account.address,
          wrapperRegistry.address,
          wrappedChild.tokenId,
          1n,
          encodeMigrationData(wrappedChild.makeData()),
        ],
        { account },
      );

      const { status, latestOwner } = await wrapperRegistry.read.getState([
        idFromLabel(wrappedChild.label()),
      ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(account.address);
    });
  });
});
