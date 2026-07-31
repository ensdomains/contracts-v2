import { describe, expect, it } from "bun:test";
import type { Address } from "viem";

import {
  RHINESTONE_INTENT_EXECUTOR,
  SEPOLIA_USDC,
} from "../../script/deploy-constants.js";
import deployDefaultReverseRegistrarAdapter from "../../deploy/02_DefaultReverseRegistrarAdapter.js";
import deployReverseRegistrarAdapter from "../../deploy/02_ReverseRegistrarAdapter.js";
import deployHCAOwnerAndSessionValidator from "../../deploy/hca/01_HCAOwnerAndSessionValidator.js";
import {
  controllerAddressHistory,
  isHCAOnlyDeployment,
  replacedDeploymentAddresses,
  resolveHCAIntentExecutor,
  resolveHCAPaymentToken,
  resolveHCASecondaryPaymentToken,
  SUPERSEDED_CONTROLLER_ADDRESSES,
} from "../../deploy/hca/_helpers.js";

const MOCK_EXECUTOR = "0x0000000000000000000000000000000000000101" as Address;
const EXISTING_EXECUTOR =
  "0x0000000000000000000000000000000000000102" as Address;
const MOCK_USDC = "0x0000000000000000000000000000000000000201" as Address;
const MOCK_DAI = "0x0000000000000000000000000000000000000202" as Address;
const OVERRIDE_EXECUTOR =
  "0x0000000000000000000000000000000000000301" as Address;
const OVERRIDE_USDC = "0x0000000000000000000000000000000000000302" as Address;
const OVERRIDE_DAI = "0x0000000000000000000000000000000000000303" as Address;
const CURRENT_DEPLOYMENT =
  "0x0000000000000000000000000000000000000401" as Address;
const PREVIOUS_DEPLOYMENT =
  "0x0000000000000000000000000000000000000402" as Address;
const LEGACY_DEPLOYMENT =
  "0x0000000000000000000000000000000000000403" as Address;

const mockDeployments = (name: string) => {
  if (name === "MockUSDC") return { address: MOCK_USDC };
  if (name === "MockDAI") return { address: MOCK_DAI };
  return null;
};

describe("HCA deployment address resolution", () => {
  it("uses fixed production addresses on Sepolia before mock artifacts", () => {
    const tags = { hca: true, sepolia: true };
    const paymentToken = resolveHCAPaymentToken({
      getOrNull: mockDeployments,
      tags,
      env: {},
    });

    expect(
      resolveHCAIntentExecutor({
        tags,
        localExecutor: MOCK_EXECUTOR,
        existingExecutor: EXISTING_EXECUTOR,
        env: {},
      }),
    ).toBe(RHINESTONE_INTENT_EXECUTOR);
    expect(paymentToken).toBe(SEPOLIA_USDC);
    expect(
      resolveHCASecondaryPaymentToken({
        getOrNull: mockDeployments,
        tags,
        paymentToken: paymentToken!,
        env: {},
      }),
    ).toBe(SEPOLIA_USDC);
  });

  it("uses the same Sepolia defaults for the live dev environment", () => {
    const tags = { hca: true, sepolia: true, dev: true };

    expect(resolveHCAIntentExecutor({ tags, env: {} })).toBe(
      RHINESTONE_INTENT_EXECUTOR,
    );
    expect(
      resolveHCAPaymentToken({
        getOrNull: mockDeployments,
        tags,
        env: {},
      }),
    ).toBe(SEPOLIA_USDC);
  });

  it("keeps local mocks for clean-testnet deployments", () => {
    const tags = { hca: true, sepolia: true, "clean-testnet": true };
    const paymentToken = resolveHCAPaymentToken({
      getOrNull: mockDeployments,
      tags,
      env: {},
    });

    expect(
      resolveHCAIntentExecutor({
        tags,
        localExecutor: MOCK_EXECUTOR,
        existingExecutor: EXISTING_EXECUTOR,
        env: {},
      }),
    ).toBe(MOCK_EXECUTOR);
    expect(paymentToken).toBe(MOCK_USDC);
    expect(
      resolveHCASecondaryPaymentToken({
        getOrNull: mockDeployments,
        tags,
        paymentToken: paymentToken!,
        env: {},
      }),
    ).toBe(MOCK_DAI);
  });

  it("allows explicit environment overrides", () => {
    const tags = { hca: true, sepolia: true };
    const env = {
      HCA_INTENT_EXECUTOR: OVERRIDE_EXECUTOR,
      HCA_PAYMENT_TOKEN: OVERRIDE_USDC,
      HCA_SECONDARY_PAYMENT_TOKEN: OVERRIDE_DAI,
    };
    const paymentToken = resolveHCAPaymentToken({
      getOrNull: mockDeployments,
      tags,
      env,
    });

    expect(resolveHCAIntentExecutor({ tags, env })).toBe(OVERRIDE_EXECUTOR);
    expect(paymentToken).toBe(OVERRIDE_USDC);
    expect(
      resolveHCASecondaryPaymentToken({
        getOrNull: mockDeployments,
        tags,
        paymentToken: paymentToken!,
        env,
      }),
    ).toBe(OVERRIDE_DAI);
  });
});

describe("HCA deployment script scope", () => {
  it("includes both reverse adapters in an HCA-only deploy", () => {
    expect(isHCAOnlyDeployment(["hca"])).toBe(true);
    expect(deployDefaultReverseRegistrarAdapter.tags).toContain("hca");
    expect(deployReverseRegistrarAdapter.tags).toContain("hca");
  });

  it("pins the HCA validator to the canonical default reverse adapter", () => {
    expect(deployHCAOwnerAndSessionValidator.dependencies).toContain(
      "DefaultReverseRegistrarAdapter",
    );
    expect(deployHCAOwnerAndSessionValidator.dependencies).not.toContain(
      "DefaultReverseRegistrarHCAAdapter",
    );
  });

  it("identifies unique prior adapter addresses for controller revocation", () => {
    const priorDeployment = {
      address: PREVIOUS_DEPLOYMENT,
      linkedData: {
        [SUPERSEDED_CONTROLLER_ADDRESSES]: [LEGACY_DEPLOYMENT],
      },
    };

    expect(
      controllerAddressHistory([
        priorDeployment,
        { address: LEGACY_DEPLOYMENT },
      ]),
    ).toEqual([PREVIOUS_DEPLOYMENT, LEGACY_DEPLOYMENT]);
    expect(
      replacedDeploymentAddresses({ address: CURRENT_DEPLOYMENT }, [
        { address: CURRENT_DEPLOYMENT },
        priorDeployment,
        { address: LEGACY_DEPLOYMENT },
        null,
      ]),
    ).toEqual([PREVIOUS_DEPLOYMENT, LEGACY_DEPLOYMENT]);
  });

  it("preserves prior controller addresses across an interrupted resume", () => {
    const replacementDeployment = {
      address: CURRENT_DEPLOYMENT,
      linkedData: {
        [SUPERSEDED_CONTROLLER_ADDRESSES]: [
          PREVIOUS_DEPLOYMENT,
          LEGACY_DEPLOYMENT,
        ],
      },
    };

    expect(
      replacedDeploymentAddresses(replacementDeployment, [
        replacementDeployment,
      ]),
    ).toEqual([PREVIOUS_DEPLOYMENT, LEGACY_DEPLOYMENT]);
  });
});
