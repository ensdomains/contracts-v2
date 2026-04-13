import { execute } from "@rocketh";
import type { Abi_ETHRegistrar } from "generated/abis/ETHRegistrar.ts";
import type { Abi_StandardRentPriceOracle } from "generated/abis/StandardRentPriceOracle.ts";

const SEPOLIA_CHAIN_ID = 11155111;
const SEPOLIA_USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const PRICE_DECIMALS = 12n;
const SEPOLIA_USDC_DECIMALS = 6n;
const SEPOLIA_USDC_NUMER =
  10n **
  (SEPOLIA_USDC_DECIMALS > PRICE_DECIMALS
    ? SEPOLIA_USDC_DECIMALS - PRICE_DECIMALS
    : 0n);
const SEPOLIA_USDC_DENOM =
  10n **
  (PRICE_DECIMALS > SEPOLIA_USDC_DECIMALS
    ? PRICE_DECIMALS - SEPOLIA_USDC_DECIMALS
    : 0n);

export default execute(
  async ({
    execute: write,
    get,
    getOrNull,
    read,
    namedAccounts: { deployer, owner },
    network,
  }) => {
    if (network.chain.id !== SEPOLIA_CHAIN_ID) return;

    const oracle = get<Abi_StandardRentPriceOracle>("StandardRentPriceOracle");
    const ethRegistrar = getOrNull<Abi_ETHRegistrar>("ETHRegistrar");
    const fastEthRegistrar = getOrNull<Abi_ETHRegistrar>("FastETHRegistrar");
    const oracleOwner = owner || deployer;

    const oracleHasSepoliaUsdc = await read(oracle, {
      functionName: "isPaymentToken",
      args: [SEPOLIA_USDC],
    });

    if (!oracleHasSepoliaUsdc) {
      await write(oracle, {
        account: oracleOwner,
        functionName: "updatePaymentToken",
        args: [SEPOLIA_USDC, SEPOLIA_USDC_NUMER, SEPOLIA_USDC_DENOM],
      });
    }

    async function assertRegistrarSupportsSepoliaUsdc(
      name: string,
      registrar: ReturnType<typeof getOrNull<Abi_ETHRegistrar>>,
    ) {
      if (!registrar) return;

      const isSupported = await read(registrar, {
        functionName: "isPaymentToken",
        args: [SEPOLIA_USDC],
      });

      if (!isSupported) {
        throw new Error(`${name} does not support Sepolia USDC after oracle setup`);
      }
    }

    await assertRegistrarSupportsSepoliaUsdc("ETHRegistrar", ethRegistrar);
    await assertRegistrarSupportsSepoliaUsdc("FastETHRegistrar", fastEthRegistrar);
  },
  {
    tags: ["oracle:setup", "testnet", "v2"],
    dependencies: [], // ["StandardRentPriceOracle", "ETHRegistrar", "FastETHRegistrar"],
  },
);
