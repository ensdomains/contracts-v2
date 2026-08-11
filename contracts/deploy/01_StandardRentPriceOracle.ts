import type { Address } from "viem";
import { artifacts, execute } from "@rocketh";
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

    const paymentTokens: Address[] = [];
    let wethAddress: Address;
    let ethOracleAddress: Address;
    if (tags.hasDao) {
      ethOracleAddress = MAINNET_ETH_ORACLE;
      wethAddress = MAINNET_WETH;
      paymentTokens.push(MAINNET_USDC);
      paymentTokens.push(MAINNET_DAI);
    } else if (tags.sepolia) {
      ethOracleAddress = SEPOLIA_ETH_ORACLE;
      wethAddress = SEPOLIA_WETH;
      paymentTokens.push(SEPOLIA_USDC);
    } else {
      ethOracleAddress = get("MockChainlinkETHUSD").address;
      wethAddress = get("MockWETH").address;
      paymentTokens.push(get("MockUSDC").address);
      paymentTokens.push(get("MockDAI").address);
    }
    paymentTokens.push(wethAddress);

    const baseRates = BASE_RATE_PER_CP.flatMap((rate, i) => {
      const yearly = Number(rate * SEC_PER_YEAR) / Number(PRICE_SCALE);
      return rate ? { cp: 1 + i, rate, yearly } : [];
    }).reverse();

    const paymentFactors = await Promise.all(
      paymentTokens.map(async (address) => {
        const { abi } = artifacts["test/mocks/MockERC20.sol/MockERC20"];
        const [symbol, decimalsResult] = await Promise.all([
          read({ address, abi }, { functionName: "symbol" }),
          read({ address, abi }, { functionName: "decimals" }),
        ]);
        const decimals = Number(decimalsResult);
        return {
          MockERC20: symbol,
          paymentToken: address,
          decimals,
          Δ: decimals - PRICE_DECIMALS,
          numer: 10n ** BigInt(Math.max(decimals - PRICE_DECIMALS, 0)),
          denom: 10n ** BigInt(Math.max(PRICE_DECIMALS - decimals, 0)),
        };
      }),
    );

    const wethIndex = paymentTokens.indexOf(wethAddress);
    if (wethIndex >= 0) {
      paymentFactors.push({
        ...paymentFactors[wethIndex],
        MockERC20: "[ether]",
        paymentToken: NATIVE_ETH,
      });
    }

    console.table(paymentFactors);

    console.table(
      baseRates.map((x) => ({ ...x, yearly: x.yearly.toFixed(2) })),
    );

    const standardRentPriceOracle =
      getOrNull<typeof artifacts.StandardRentPriceOracle.abi>(
        "StandardRentPriceOracle",
      ) ??
      (await deploy("StandardRentPriceOracle", {
        account: deployer,
        artifact: artifacts.StandardRentPriceOracle,
        args: [
          owner,
          BASE_RATE_PER_CP,
          DISCOUNT_POINTS,
          DISCOUNT_DENOMINATOR,
          PREMIUM_PRICE_INITIAL,
          PREMIUM_HALVING_PERIOD,
          PREMIUM_PERIOD,
          paymentFactors,
          wethAddress,
          ethOracleAddress,
        ],
      }));

    // sync ratios
    for (const paymentFactor of paymentFactors) {
      const [numer, denom] = (await read(standardRentPriceOracle, {
        functionName: "getPaymentTokenRatio",
        args: [paymentFactor.paymentToken],
      })) as [bigint, bigint];
      if (numer === paymentFactor.numer && denom === paymentFactor.denom) {
        continue;
      }
      await write(standardRentPriceOracle, {
        account: owner,
        functionName: "updatePaymentToken",
        args: [
          paymentFactor.paymentToken,
          paymentFactor.numer,
          paymentFactor.denom,
        ],
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
