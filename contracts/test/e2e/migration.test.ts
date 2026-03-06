import { describe, it } from "bun:test";
import type { AbiParameter, AbiParameterToPrimitiveType } from "abitype";
import {
  type Account,
  encodeAbiParameters,
  type Hex,
  labelhash,
  namehash,
  zeroAddress,
} from "viem";
import { STATUS, MAX_EXPIRY, FUSES } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";
import { getLabelAt } from "../utils/utils.js";

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
      // add owner as controller so we can register() directly
      const { owner } = env.namedAccounts;
      await env.deployment.contracts.ETHRegistrarV1.write.addController(
        [owner.address],
        { account: owner },
      );
    },
  });

  async function ensurePremigration(label: string) {
    const tokenId = BigInt(labelhash(label));
    const [expiry, resolverAddress] = await Promise.all([
      env.deployment.contracts.ETHRegistrarV1.read.nameExpires([tokenId]),
      env.deployment.contracts.ENSRegistryV1.read.resolver([
        namehash(`${label}.eth`),
      ]),
    ]);
    await env.deployment.contracts.ETHRegistry.write.register([
      label,
      zeroAddress, // owner
      zeroAddress, // registry
      resolverAddress,
      0n, // roleBitmap
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
      await env.deployment.contracts.NameWrapperV1.write.setSubnodeOwner(
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
    // register using controller hack
    await env.deployment.contracts.ETHRegistrarV1.write.register(
      [unwrappedTokenId, account.address, duration],
      { account: env.namedAccounts.owner },
    );
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
      await env.deployment.contracts.ETHRegistrarV1.write.approve(
        [env.deployment.contracts.NameWrapperV1.address, unwrappedTokenId],
        { account },
      );
      await env.deployment.contracts.NameWrapperV1.write.wrapETH2LD(
        [label, account.address, fuses, zeroAddress],
        { account },
      );
      return new WrappedToken(name, account);
    }
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
  });

  describe("unwrapped", () => {
    it("by owner", async () => {
      const { account, unwrappedTokenId, makeData } = await registerUnwrapped();
      await env.deployment.contracts.ETHRegistrarV1.write.safeTransferFrom(
        [
          account.address,
          env.deployment.contracts.UnlockedMigrationController.address,
          unwrappedTokenId,
          encodeMigrationData(makeData()),
        ],
        { account },
      );
      const { status, latestOwner } =
        await env.deployment.contracts.ETHRegistry.read.getState([
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
      await env.deployment.contracts.NameWrapperV1.write.safeTransferFrom(
        [
          account.address,
          env.deployment.contracts.UnlockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(wrapped.makeData()),
        ],
        { account },
      );
      const { status, latestOwner } =
        await env.deployment.contracts.ETHRegistry.read.getState([
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
      await env.deployment.contracts.NameWrapperV1.write.safeTransferFrom(
        [
          account.address,
          env.deployment.contracts.LockedMigrationController.address,
          wrapped.tokenId,
          1n,
          encodeMigrationData(wrapped.makeData()),
        ],
        { account },
      );
      const { status, latestOwner } =
        await env.deployment.contracts.ETHRegistry.read.getState([
          unwrappedTokenId,
        ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(account.address);
    });
  });
});
