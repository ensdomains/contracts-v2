import hre from "hardhat";
import type { Account, Address } from "viem";
import {
  DAO_WALLET,
  DAO_TOKEN_SAFE,
  DEPLOYED_UNIVERSAL_RESOLVER_PROXY,
} from "../../script/deploy-constants.js";

// TODO: make this robust once deployments are consolidated
export async function forkAndAttach(network = "mainnet") {
  if (network !== "mainnet") {
    throw new Error(`unsupported fork: ${network}`);
  }

  const connection = await hre.network.connect(`${network}Fork`);

  const forkedFixture = async () => {
    // v1
    const SimplePublicSuffixList = await connection.viem.getContractAt(
      "SimplePublicSuffixList",
      "0x823BDa9cA8c47d072376eCD595530c8fb2fAa3ED",
    );
    const OffchainDNSResolver = await connection.viem.getContractAt(
      "OffchainDNSResolver",
      "0xEbBcBFBE4A8F3357e7d1d444406C28cFa34f1261",
    );
    // v2
    const RootRegistry = await connection.viem.getContractAt(
      "PermissionedRegistry",
      "0x2553c09bE6447BeFfdB86FA622ad41fB8f77A91e",
    );
    const EthRegistry = await connection.viem.getContractAt(
      "PermissionedRegistry",
      await RootRegistry.read.getSubregistry(["eth"]),
    );
    const DNSTLDResolver = await connection.viem.getContractAt(
      "DNSTLDResolver",
      "0x6695327EE70F41151d2cBADC3ABBb6e4a58e739c",
    );
    const UniversalResolver = await connection.viem.getContractAt(
      "UniversalResolverV2",
      DEPLOYED_UNIVERSAL_RESOLVER_PROXY,
    );

    const namedAccounts = {
      DAO_WALLET: await impersonate(DAO_WALLET),
      DAO_TOKEN_SAFE: await impersonate(DAO_TOKEN_SAFE),
    };

    return {
      v1: { SimplePublicSuffixList, OffchainDNSResolver },
      v2: { RootRegistry, EthRegistry, DNSTLDResolver },
      UniversalResolver,
      namedAccounts,
      impersonate,
    };

    async function impersonate(address: Address): Promise<Account> {
      await connection.networkHelpers.impersonateAccount(address);
      await connection.networkHelpers.setBalance(address, 1e18);
      return { type: "json-rpc", address };
    }
  };

  return {
    connection,
    forkedFixture,
  };
}
