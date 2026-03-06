import { describe, it } from "bun:test";
import type { AbiParameter, AbiParameterToPrimitiveType } from "abitype";
import {
  type Account,
  encodeAbiParameters,
  type Hex,
  labelhash,
  zeroAddress,
} from "viem";
import { STATUS } from "../../script/deploy-constants.js";
import { expectVar } from "../utils/expectVar.js";

// see: LibMigration.sol
const migrationDataComponents = [
  { name: "label", type: "string" },
  { name: "owner", type: "address" },
  { name: "subregistry", type: "address" },
  { name: "resolver", type: "address" },
  { name: "salt", type: "uint256" },
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

  async function reserve(label: string, resolverAddress = zeroAddress) {
    const tokenId = BigInt(labelhash(label));
    const expiry =
      await env.deployment.contracts.ETHRegistrarV1.read.nameExpires([tokenId]);
    await env.deployment.contracts.ETHRegistry.write.register([
      label,
      zeroAddress, // owner
      zeroAddress, // registry
      resolverAddress,
      0n, // roleBitmap
      expiry,
    ]);
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
    await reserve(label);
    const name = `${label}.eth`;
    return {
      label,
      name,
      account,
      unwrappedTokenId,
      makeData,
    };
    function makeData(data: Partial<MigrationData> = {}) {
      return {
        label,
        owner: account.address,
        subregistry: zeroAddress,
        resolver: zeroAddress,
        salt: 0n, // not used
        ...data,
      };
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

  describe("unwrapped", () => {
    it("registerUnwrapped", async () => {
      await registerUnwrapped();
    });

    it("by owner", async () => {
      const {
        account,
        unwrappedTokenId,
        makeData: migrationData,
      } = await registerUnwrapped();
      await env.deployment.contracts.ETHRegistrarV1.write.safeTransferFrom(
        [
          account.address,
          env.deployment.contracts.UnlockedMigrationController.address,
          unwrappedTokenId,
          encodeMigrationData(migrationData()),
        ],
        { account },
      );

      const { latestOwner, status } =
        await env.deployment.contracts.ETHRegistry.read.getState([
          unwrappedTokenId,
        ]);
      expectVar({ status }).toStrictEqual(STATUS.REGISTERED);
      expectVar({ latestOwner }).toStrictEqual(account.address);
    });
  });

  describe("unlocked", () => {});

  describe("locked", () => {});
});
