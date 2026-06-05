import { artifacts, execute } from "@rocketh";
import { labelhash, zeroAddress } from "viem";
import { MAX_EXPIRY, ROLES } from "../script/deploy-constants.js";
import { dnsEncodeName } from "../test/utils/utils.js";

async function fetchPublicSuffixes() {
  const res = await fetch(
    "https://publicsuffix.org/list/public_suffix_list.dat",
    { headers: { Connection: "close" } },
  );
  if (!res.ok) throw new Error(`expected suffixes: ${res.status}`);
  return (await res.text())
    .split("\n")
    .map((x) => x.trim())
    .filter((x) => x && !x.startsWith("//"));
}

export default execute(
  async ({
    deploy,
    execute: write,
    get,
    getV1,
    read,
    namedAccounts: { deployer },
    tags,
  }) => {
    const ensRegistry =
      await getV1<(typeof artifacts.ENSRegistry)["abi"]>("ENSRegistry");

    const dnsTLDResolverV1 = await getV1<
      (typeof artifacts.OffchainDNSResolver)["abi"]
    >("OffchainDNSResolver");

    const publicSuffixList = await getV1<
      (typeof artifacts.SimplePublicSuffixList)["abi"]
    >("SimplePublicSuffixList");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const dnssecOracle =
      await getV1<(typeof artifacts.DNSSECImpl)["abi"]>("DNSSECImpl");

    const batchGatewayProvider =
      await getV1<(typeof artifacts.GatewayProvider)["abi"]>(
        "BatchGatewayProvider",
      );

    const dnssecGatewayProvider =
      get<(typeof artifacts.GatewayProvider)["abi"]>("DNSSECGatewayProvider");

    const contractNamer =
      get<(typeof artifacts.IContractNamer)["abi"]>("ContractNamer");

    const dnsTLDResolver = await deploy("DNSTLDResolver", {
      account: deployer,
      artifact: artifacts.DNSTLDResolver,
      args: [
        ensRegistry.address,
        dnsTLDResolverV1.address,
        rootRegistry.address,
        dnssecOracle.address,
        dnssecGatewayProvider.address,
        batchGatewayProvider.address,
        contractNamer.address,
      ],
    });

    let suffixes = tags.local
      ? ["com", "org", "net", "xyz"]
      : await fetchPublicSuffixes();
    const eligibleSuffixes = await Promise.all(
      suffixes.map(async (suffix) => {
        const isPublicSuffix = await read(publicSuffixList, {
          functionName: "isPublicSuffix",
          args: [dnsEncodeName(suffix)],
        });
        if (!isPublicSuffix) return undefined;

        const status = await read(rootRegistry, {
          functionName: "getStatus",
          args: [BigInt(labelhash(suffix))],
        });
        return status === 0 ? suffix : undefined;
      }),
    );
    suffixes = eligibleSuffixes.filter((suffix): suffix is string =>
      Boolean(suffix),
    );

    if (suffixes.length === 0) {
      console.warn("  - No suffixes found");
      return;
    }

    const batchRegistrar = await deploy("RootBatchRegistrar", {
      account: deployer,
      artifact: artifacts.BatchRegistrar,
      args: [rootRegistry.address, deployer],
    });

    await write(rootRegistry, {
      account: deployer,
      functionName: "grantRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        batchRegistrar.address,
      ],
    });

    const suffixBatchSize = 25;
    for (let i = 0; i < suffixes.length; i += suffixBatchSize) {
      const batch = suffixes.slice(i, i + suffixBatchSize);
      const progress = Math.min(i + suffixBatchSize, suffixes.length);
      console.log(
        `  - Registering ${batch.length} suffixes (${progress}/${suffixes.length})`,
      );
      await write(batchRegistrar, {
        account: deployer,
        functionName: "batchRegister",
        args: [
          zeroAddress,
          dnsTLDResolver.address,
          batch,
          new Array(batch.length).fill(MAX_EXPIRY),
        ],
      });
    }

    await write(rootRegistry, {
      account: deployer,
      functionName: "revokeRootRoles",
      args: [
        ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW,
        batchRegistrar.address,
      ],
    });
  },
  {
    tags: ["DNSTLDResolver", "v2"],
    dependencies: [
      "RootRegistry",
      "ENSRegistry",
      "DNSSECImpl",
      "OffchainDNSResolver",
      "SimplePublicSuffixList",
      "BatchGatewayProvider",
      "DNSSECGatewayProvider",
      "ContractNamer",
    ],
  },
);
