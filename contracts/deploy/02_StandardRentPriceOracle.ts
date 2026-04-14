import { artifacts, execute } from "@rocketh";

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
      PRICE_SCALE * 5n,
    ].map((x) => (x + SEC_PER_YEAR - 1n) / SEC_PER_YEAR);

    const DISCOUNT_SCALE = (1n << 128n) - 1n; // type(uint128).max
    function discountRatio(numer: bigint, denom: bigint) {
      return (DISCOUNT_SCALE * numer + denom - 1n) / denom;
    }
    const discountPoints: [bigint, bigint][] = [
      [SEC_PER_YEAR, 0n],
      [SEC_PER_YEAR, discountRatio(1n, 5n)], //      20.00%
      [SEC_PER_YEAR, discountRatio(11n, 20n)], //    55.00%
      [SEC_PER_YEAR * 2n, discountRatio(5n, 8n)], // 62.50%
      [SEC_PER_YEAR * 5n, discountRatio(3n, 5n)], // 60.00%
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
        discountPoints.map(async (_, i, v) => {
          const sum = v.slice(0, i + 1).reduce((a, x) => a + x[0], 0n);
          const acc = v.slice(0, i + 1).reduce((a, x) => a + x[0] * x[1], 0n);
          const ref = await read(standardRentPriceOracle, {
            functionName: "integratedDiscount",
            args: [sum],
          });
          return {
            years: (Number(sum) / Number(SEC_PER_YEAR)).toFixed(2),
            discount: `${((100 * Number(acc / sum)) / Number(DISCOUNT_SCALE)).toFixed(2)}%`,
            diff: acc - ref,
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
