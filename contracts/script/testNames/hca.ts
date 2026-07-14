import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbiParameters,
  stringToHex,
  zeroAddress,
  zeroHash,
} from "viem";
import type { DevnetAccount, DevnetEnvironment } from "../setup.js";
import { trackGas } from "./gas.js";

// Matches the registration duration used by the HCA e2e pipeline.
const REGISTRATION_DURATION = 28n * 86400n;

/**
 * Deterministic salt for a user's standalone HCA proxy.
 * Mirrors `computeStandaloneHcaSalt` in test/e2e/hca.test.ts.
 */
function computeStandaloneHcaSalt(label: string): bigint {
  return BigInt(keccak256(stringToHex(`StandaloneHCA:${label}`)));
}

/**
 * Deploy a standalone HCA for each account via the RegistrationBootstrapper —
 * the same deploy-and-commit pipeline that ships to real networks — and record
 * the gas cost of each creation under `deployHCA(<account>)` in the gas report.
 *
 * @param accounts Accounts to create HCAs for (defaults to owner, user, user2).
 */
export async function deployHCA(
  env: DevnetEnvironment,
  accounts: DevnetAccount[] = [
    env.namedAccounts.owner,
    env.namedAccounts.user,
    env.namedAccounts.user2,
  ],
) {
  const bootstrapper = env.hca.RegistrationBootstrapper;
  const hcaImplementation = env.hca.StandaloneHCAImplementation;

  console.log("\n========== Deploying HCA per user ==========");

  for (const account of accounts) {
    const label = `hca-${account.name}`;
    const salt = computeStandaloneHcaSalt(label);
    const hca = env.computeVerifiableProxyAddress(bootstrapper.address, salt);

    // initializeAccount(bytes) — abi-encoded owner address as the init payload.
    const initData = encodeFunctionData({
      abi: hcaImplementation.abi,
      functionName: "initializeAccount",
      args: [
        encodeAbiParameters(parseAbiParameters("address"), [account.address]),
      ],
    });

    // Commitment the bootstrapper writes alongside the proxy deployment.
    const commitment = await env.v2.ETHRegistrar.read.makeCommitment([
      label,
      account.address,
      zeroHash,
      zeroAddress,
      account.resolver.address,
      REGISTRATION_DURATION,
      zeroHash,
    ]);

    const receipt = await env.waitFor(
      bootstrapper.write.deployAndCommit(
        [
          env.v2.VerifiableFactory.address,
          hcaImplementation.address,
          salt,
          initData,
          env.v2.ETHRegistrar.address,
          commitment,
        ],
        { account },
      ),
    );
    trackGas(`deployHCA(${account.name})`, receipt);

    console.log(`  - Deployed HCA for ${account.name} at ${hca}`);
  }
}
