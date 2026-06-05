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

function rootTLDs(suffixes: string[]) {
  return suffixes.filter((suffix) =>
    !suffix.startsWith("!") &&
    !suffix.startsWith("*.") &&
    !suffix.includes(".")
  );
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
    const publicSuffixList = await getV1<
      (typeof artifacts.SimplePublicSuffixList)["abi"]
    >("SimplePublicSuffixList");

    const rootRegistry =
      get<(typeof artifacts.PermissionedRegistry)["abi"]>("RootRegistry");

    const ensV1Resolver =
      get<(typeof artifacts.ENSV1Resolver)["abi"]>("ENSV1Resolver");

    if (tags["clean-testnet"]) {
      console.warn("  - No suffixes found");
      return;
    }

    const candidates = tags.local
      ? ["com", "org", "net", "xyz"]
      : rootTLDs(await fetchPublicSuffixes());
    const suffixes: string[] = [];
    for (let i = 0; i < candidates.length; i += 25) {
      const batch = candidates.slice(i, i + 25);
      const available = await Promise.all(batch.map(async (suffix) => {
        const publicSuffix = await read(publicSuffixList, {
          functionName: "isPublicSuffix",
          args: [dnsEncodeName(suffix)],
        });
        if (!publicSuffix) return "";
        const status = await read(rootRegistry, {
          functionName: "getStatus",
          args: [BigInt(labelhash(suffix))],
        });
        return status === 0 ? suffix : "";
      }));
      suffixes.push(...available.filter(Boolean));
    }

    if (suffixes.length === 0) {
      console.warn("  - No suffixes found");
      return;
    }

    const batchRegistrar = await deploy("DNSV1MirrorRootBatchRegistrar", {
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

    for (let i = 0; i < suffixes.length; i += 25) {
      const batch = suffixes.slice(i, i + 25);
      console.log(`  - Registering ${batch.length} suffixes (${Math.min(i + 25, suffixes.length)}/${suffixes.length})`);
      await write(batchRegistrar, {
        account: deployer,
        functionName: "batchRegister",
        args: [
          zeroAddress,
          ensV1Resolver.address,
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
    tags: ["DNSV1MirrorTLDs", "migration:phase1:deploy-v2"],
    dependencies: [
      "RootRegistry",
      "ENSV1Resolver",
      "SimplePublicSuffixList",
    ],
  },
);
