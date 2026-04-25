import { artifacts, execute } from "@rocketh";
import { MAX_EXPIRY } from "../script/deploy-constants.ts";

export default execute(
  async ({ deploy, read, get, namedAccounts: { deployer, owner } }) => {
    const ethRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("ETHRegistry");

    type MockERC20 =
      (typeof artifacts)["test/mocks/MockERC20.sol/MockERC20"]["abi"];
    const mockUSDC = get<MockERC20>("MockUSDC");
    const mockDAI = get<MockERC20>("MockDAI");
    const paymentTokens = [mockUSDC, mockDAI];

    // see: StandardPricing.sol
    const SEC_PER_YEAR = 31_557_600n; // 365.25
    const SEC_PER_DAY = 86400n;
    const PRICE_DECIMALS = 12;
    const PRICE_SCALE = 10n ** BigInt(PRICE_DECIMALS);
    const PREMIUM_PRICE_INITIAL = PRICE_SCALE * 100_000_000n;
    const PREMIUM_HALVING_PERIOD = SEC_PER_DAY;
    const PREMIUM_PERIOD = SEC_PER_DAY * 21n;

    const baseRatePerCp = [
      0n,
      0n,
      PRICE_SCALE * 640n,
      PRICE_SCALE * 160n,
      PRICE_SCALE * 8n,
    ].map((x) => (x + SEC_PER_YEAR - 1n) / SEC_PER_YEAR);

    const DISCOUNT_SCALE = (1n << 128n) - 1n; // type(uint128).max
    function discountRatio(numer: bigint, denom: bigint) {
      return (DISCOUNT_SCALE * numer + denom - 1n) / denom;
    }
    const discountPoints: [bigint, bigint][] = [
      [SEC_PER_YEAR, 0n],
      [SEC_PER_YEAR, discountRatio(1n, 4n)], //       25.00%
      [SEC_PER_YEAR, discountRatio(11n, 16n)], //     68.75%
      [SEC_PER_YEAR * 3n, discountRatio(9n, 16n)], // 56.25%
    ];

    const paymentFactors = await Promise.all(
      paymentTokens.map(async (x) => {
        const [symbol, decimals] = await Promise.all([
          read(x, { functionName: "symbol" }),
          read(x, { functionName: "decimals" }),
        ]);
        return {
          MockERC20: symbol,
          decimals,
          token: x.address,
          numer: 10n ** BigInt(Math.max(decimals - PRICE_DECIMALS, 0)),
          denom: 10n ** BigInt(Math.max(PRICE_DECIMALS - decimals, 0)),
        };
      }),
    );

    console.table(paymentFactors);

    console.table(
      baseRatePerCp.flatMap((rate, i) => {
        const yearly = (
          Number(rate * SEC_PER_YEAR) / Number(PRICE_SCALE)
        ).toFixed(2);
        return rate ? { cp: 1 + i, rate, yearly } : [];
      }),
    );

    const standardRentPriceOracle = await deploy("StandardRentPriceOracle", {
      account: deployer,
      artifact: artifacts.StandardRentPriceOracle,
      args: [
        owner,
        ethRegistry.address,
        baseRatePerCp,
        discountPoints.map(([t, value]) => ({ t, value })),
        PREMIUM_PRICE_INITIAL,
        PREMIUM_HALVING_PERIOD,
        PREMIUM_PERIOD,
        paymentFactors,
      ],
    });

    console.table(
      await Promise.all(
        [
          ...new Set([
            ...discountPoints.map((x) => x[0]),
            ...Array.from(
              { length: 10 },
              (_, yr) => BigInt(yr + 1) * SEC_PER_YEAR,
            ),
            100n * SEC_PER_YEAR,
          ]),
        ]
          .sort((a, b) => Number(a - b))
          .map(async (t) => {
            const x = await read(standardRentPriceOracle, {
              functionName: "integratedDiscount",
              args: [t],
            });
            return {
              years: (Number(t) / Number(SEC_PER_YEAR)).toFixed(2),
              discount: `${((100 * Number(x / t)) / Number(DISCOUNT_SCALE)).toFixed(2)}%`,
              ...Object.fromEntries(
                baseRatePerCp.flatMap((rate, i) =>
                  rate
                    ? [
                        [
                          `${i + 1}cp/yr`,
                          `${(Number((rate * (DISCOUNT_SCALE * t - x)) / DISCOUNT_SCALE) / Number(PRICE_SCALE) / Number(t / SEC_PER_YEAR)).toFixed(2)}`,
                        ],
                      ]
                    : [],
                ),
              ),
            };
          }),
      ),
    );
  },
  {
    tags: ["StandardRentPriceOracle", "v2"],
    dependencies: ["MockTokens", "ETHRegistry"],
  },
);
