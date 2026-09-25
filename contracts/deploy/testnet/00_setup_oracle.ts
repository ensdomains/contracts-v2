import { execute } from "@rocketh";
import type { Abi_StandardRentPriceOracle } from "generated/abis/StandardRentPriceOracle.js";
import {
  ratioFromDecimals,
  SEPOLIA_USDC,
} from "../../script/deploy-constants.js";

const SEPOLIA_CHAIN_ID = 11155111;
const SEPOLIA_USDC_DECIMALS = 6;

export default execute(
  async ({
    execute: write,
    get,
    read,
    namedAccounts: { deployer, owner },
    network,
  }) => {
    if (network.chain.id !== SEPOLIA_CHAIN_ID) return;

    const oracle = get<Abi_StandardRentPriceOracle>("StandardRentPriceOracle");
    const oracleOwner = owner || deployer;

    const oracleHasSepoliaUsdc = await read(oracle, {
      functionName: "isPaymentToken",
      args: [SEPOLIA_USDC],
    });

    if (!oracleHasSepoliaUsdc) {
      await write(oracle, {
        account: oracleOwner,
        functionName: "updatePaymentToken",
        args: [SEPOLIA_USDC, ...ratioFromDecimals(SEPOLIA_USDC_DECIMALS)],
      });
    }
  },
  {
    tags: ["oracle:setup", "testnet", "v2"],
    dependencies: ["StandardRentPriceOracle"],
  },
);
