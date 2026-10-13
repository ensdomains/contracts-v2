import { execute } from "@rocketh";
import { formatGwei, zeroAddress, type Address } from "viem";
import { Artifact_MockERC20 } from "generated/artifacts/test/mocks/MockERC20.sol/MockERC20.js";
import { Artifact_StandardRentPriceOracle } from "generated/artifacts/StandardRentPriceOracle.js";
import {
  SEC_PER_YEAR,
  PRICE_SCALE,
  PRICE_DECIMALS,
  BASE_RATE_PER_CP,
  DISCOUNT_POINTS,
  DISCOUNT_DENOMINATOR,
  PREMIUM_PRICE_INITIAL,
  PREMIUM_HALVING_PERIOD,
  PREMIUM_PERIOD,
  SEPOLIA_USDC,
  MAINNET_USDC,
  MAINNET_DAI,
  MAINNET_WETH,
  MAINNET_ETH_ORACLE,
  SEPOLIA_WETH,
  SEPOLIA_ETH_ORACLE,
  NATIVE_ETH,
  ratioFromDecimals,
} from "../script/deploy-constants.js";

export default execute(
  async ({
    deploy,
    execute: write,
    read,
    get,
    getOrNull,
    namedAccounts: { deployer, owner },
    tags,
  }) => {
    // Mainnet whitelists the real payment tokens; the free-mint mocks are only
    // deployed (and only accepted) on test/dev networks. The ERC20 metadata
    // reads below (symbol/decimals) work against the real tokens too.

    type OracleConfig = { oracle: Address; flip: boolean; maxAge: bigint };

    const paymentTokens: Address[] = [];
    const oracles: Record<Address, OracleConfig> = {};
    const noOracle: OracleConfig = {
      oracle: zeroAddress,
      flip: false,
      maxAge: 0n,
    };
    const maxAge = 3n * 3600n; // safetyFactory * (1 hour) => https://docs.chain.link/data-feeds/overview#check-the-timestamp-of-the-latest-answer
    let wethAddress: Address;
    if (tags.hasDao) {
      wethAddress = MAINNET_WETH;
      oracles[wethAddress] = {
        oracle: MAINNET_ETH_ORACLE,
        flip: true,
        maxAge,
      };
      paymentTokens.push(MAINNET_USDC);
      paymentTokens.push(MAINNET_DAI);
    } else if (tags.sepolia || tags["clean-testnet"]) {
      wethAddress = SEPOLIA_WETH;
      oracles[wethAddress] = {
        oracle: SEPOLIA_ETH_ORACLE,
        flip: true,
        maxAge,
      };
      paymentTokens.push(SEPOLIA_USDC);
    } else {
      wethAddress = get("MockWETH").address;
      oracles[wethAddress] = {
        oracle: get("MockChainlinkETHUSD").address,
        flip: true,
        maxAge,
      };
      paymentTokens.push(get("MockUSDC").address);
      paymentTokens.push(get("MockDAI").address);
    }
    paymentTokens.push(wethAddress);

    const baseRates = BASE_RATE_PER_CP.flatMap((rate, i) => {
      const yearly = Number(rate * SEC_PER_YEAR) / Number(PRICE_SCALE);
      return rate ? { cp: 1 + i, rate, yearly } : [];
    }).reverse();

    const paymentConfigs = await Promise.all(
      paymentTokens.map(async (address) => {
        const { abi } = Artifact_MockERC20;
        const [symbol, decimalsResult] = await Promise.all([
          read({ address, abi }, { functionName: "symbol" }),
          read({ address, abi }, { functionName: "decimals" }),
        ]);
        const decimals = Number(decimalsResult);
        const [numer, denom] = ratioFromDecimals(decimals);
        return {
          MockERC20: symbol,
          paymentToken: address,
          decimals,
          Δ: decimals - PRICE_DECIMALS,
          numer,
          denom,
          ...(oracles[address] ?? noOracle),
        };
      }),
    );

    const wethIndex = paymentTokens.indexOf(wethAddress);
    if (wethIndex >= 0) {
      paymentConfigs.push({
        ...paymentConfigs[wethIndex],
        MockERC20: "[ether]",
        paymentToken: NATIVE_ETH,
      });
    }

    console.table(paymentConfigs);

    console.table(
      baseRates.map((x) => ({ ...x, yearly: x.yearly.toFixed(2) })),
    );

    const standardRentPriceOracle =
      getOrNull<(typeof Artifact_StandardRentPriceOracle)["abi"]>(
        "StandardRentPriceOracle",
      ) ??
      (await deploy("StandardRentPriceOracle", {
        account: deployer,
        artifact: Artifact_StandardRentPriceOracle,
        args: [
          owner,
          BASE_RATE_PER_CP,
          DISCOUNT_POINTS,
          DISCOUNT_DENOMINATOR,
          PREMIUM_PRICE_INITIAL,
          PREMIUM_HALVING_PERIOD,
          PREMIUM_PERIOD,
          paymentConfigs,
        ],
      }));

    // sync ratios
    for (const cfg of paymentConfigs) {
      const cfg0 = await read(standardRentPriceOracle, {
        functionName: "getPaymentTokenConfiguration",
        args: [cfg.paymentToken],
      });
      if (
        cfg0.numer === cfg.numer &&
        cfg0.denom === cfg.denom &&
        cfg0.oracle === cfg.oracle &&
        cfg0.flip === cfg.flip &&
        cfg0.maxAge === cfg.maxAge
      ) {
        continue;
      }
      await write(standardRentPriceOracle, {
        account: owner,
        functionName: "updatePaymentToken",
        args: [cfg.paymentToken, cfg],
      });
    }

    const denom = 100000n;
    const durations = [
      ...new Set([
        ...DISCOUNT_POINTS.map((x) => x.duration),
        ...Array.from({ length: 10 }, (_, yr) => BigInt(yr + 1) * SEC_PER_YEAR),
        ...[25n, 100n].map((yr) => yr * SEC_PER_YEAR),
      ]),
    ].sort((a, b) => Number(a - b));
    const numers = await Promise.all(
      durations.map((t) =>
        read(standardRentPriceOracle, {
          functionName: "applyDiscount",
          args: [denom, t - 1n],
        }),
      ),
    );
    console.table(
      await Promise.all(
        durations.map(async (t, i) => {
          const years = Number(t) / Number(SEC_PER_YEAR);
          const ratio = Number(numers[i]) / Number(denom);
          return {
            years: `<${years.toFixed(2)}`,
            discount: `${(100 * (1 - ratio)).toFixed(2)}%`,
            ...Object.fromEntries(
              baseRates.flatMap((x) => {
                const perYear =
                  (ratio * Number(x.rate * SEC_PER_YEAR)) / Number(PRICE_SCALE);
                return [
                  [`${x.cp}cp/yr`, `${perYear.toFixed(2)}`],
                  [`${x.cp}cp`, `${(perYear * years).toFixed(2)}`],
                ];
              }),
            ),
          };
        }),
      ),
    );
  },
  {
    tags: ["StandardRentPriceOracle", "migration:phase1:deploy-v2", "v2"],
    dependencies: ["MockTokens"],
  },
);
