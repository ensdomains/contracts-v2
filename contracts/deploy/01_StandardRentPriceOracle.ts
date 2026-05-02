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
} from "../script/deploy-constants.js";

type MockERC20 =
  (typeof artifacts)["test/mocks/MockERC20.sol/MockERC20"]["abi"];

export default execute(
  async ({ deploy, read, get, namedAccounts: { deployer, owner } }) => {
    const paymentTokens = [
      get<MockERC20>("MockUSDC"),
      get<MockERC20>("MockDAI"),
    ];

    const baseRates = BASE_RATE_PER_CP.flatMap((rate, i) => {
      const yearly = Number(rate * SEC_PER_YEAR) / Number(PRICE_SCALE);
      return rate ? { cp: 1 + i, rate, yearly } : [];
    }).reverse();

    const paymentFactors = await Promise.all(
      paymentTokens.map(async (x) => {
        const [symbol, decimals] = await Promise.all([
          read(x, { functionName: "symbol" }),
          read(x, { functionName: "decimals" }),
        ]);
        return {
          MockERC20: symbol,
          paymentToken: x.address,
          decimals,
          Δ: decimals - PRICE_DECIMALS,
          numer: 10n ** BigInt(Math.max(decimals - PRICE_DECIMALS, 0)),
          denom: 10n ** BigInt(Math.max(PRICE_DECIMALS - decimals, 0)),
        };
      }),
    );

    console.table(paymentFactors);

    console.table(
      baseRates.map((x) => ({ ...x, yearly: x.yearly.toFixed(2) })),
    );

    const standardRentPriceOracle = await deploy("StandardRentPriceOracle", {
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
      ],
    });

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
    tags: ["StandardRentPriceOracle", "v2"],
    dependencies: ["MockTokens"],
  },
);
