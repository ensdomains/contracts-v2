import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { generatePrivateKey } from "viem/accounts";

const CROSS_CHAIN = process.env.HCA_CROSS_CHAIN === "1";
const SAME_CHAIN_USER_PAID_USDC =
  process.env.HCA_SAME_CHAIN_USER_PAID_USDC === "1";
const LIVE_RUN_TIMEOUT_MS = CROSS_CHAIN ? 900_000 : 420_000;
const contractsRoot = fileURLToPath(new URL("..", import.meta.url));
const SEPOLIA_USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const suppliedOwnerKey = process.env.HCA_OWNER_KEY?.trim();
const generatedOwnerKey = !suppliedOwnerKey;
const liveOwnerKey = suppliedOwnerKey ?? generatePrivateKey();

type SameChainRoute = {
  transactionHash: string;
  setupOps: number;
  mode: string;
  gasUsed: string;
  gasRefunds: Array<{
    token: string;
    exchangeRate: string;
    overhead: string;
  }>;
  feePayment?: {
    token: string;
    balanceBefore: string;
    fundedBeforeExecution: string;
    balanceAfter: string;
    totalCharge: string;
    protocolSpend: string;
    executionFee: string;
  };
};

type CrossChainRoute = {
  claimTransactionHash: string;
  fillTransactionHash: string;
  sourceSetupOps: number;
  recipientSetupOps: number;
  sourceWalletSignatures: number;
  destinationReusesPermit2Signature: boolean;
  using7579: boolean;
  mode: string;
  settlementLayer: string;
  fundingMethod: string;
  claimGasUsed: string;
  fillGasUsed: string;
  gasUsed: string;
};

type CrossChainPreparation = {
  deploymentTransactionHash: string;
  commitTransactionHash: string;
  deploymentGasUsed: string;
  commitGasUsed: string;
  gasUsed: string;
};

type LiveRegistrationSummary = {
  initialState: "new" | "existing";
  names: [string, string];
  owner: string;
  hca: string;
  resolver: string;
  ownerKeySource: string;
  wallet?: {
    address: string;
    nativeBalanceBefore: string;
    nativeBalanceAfter: string;
    transactionCountBefore: number;
    transactionCountAfter: number;
  };
  sameChainFunding: {
    source: "wallet EIP-2612 permit";
    amountPulled: string;
    walletBalanceBeforePull: string;
    walletBalanceAfter: string;
    hcaBalanceBefore: string;
    hcaBalanceAfter: string;
    executionCharge: string;
    allowanceAfter: string;
  };
  walletInteractions:
    | {
        paymentPermitSignatures: number;
        ownerIntentSignatures: number;
        postCommitWalletInteractions: number;
        total: number;
      }
    | {
        sourceFundingTransactions: number;
        permit2Signatures: number;
        additionalHcaOwnerSignatures: number;
        total: number;
      };
  crossChain?: {
    sourceChain: number;
    targetChain: number;
    sourceToken: string;
    targetToken: string;
    source: {
      wallet: string;
      sourceAccount: string;
      circleFaucetRequested: boolean;
      provisioningSource: "existing" | "circle" | "operator";
      provisioningTransactionHashes: string[];
      provisioningGasUsed: string;
      walletNativeBalance: string;
      walletBalanceBefore: string;
      walletBalanceAfter: string;
      sourceAccountBalanceBefore: string;
      sourceAccountBalanceAfter: string;
      permit2AllowanceBefore: string;
      fundingTransactionHash: string;
      fundingGasUsed: string;
      walletTransactions: number;
    };
  };
  funding?: {
    source: "Base Sepolia Permit2 + Across";
    amount: string;
    crossChainBalance: string;
    testProvisionedAmount: string;
    provisioningTransactionHash?: string;
    gasUsed: string;
  };
  flows: {
    newUser:
      | [SameChainRoute, SameChainRoute]
      | [CrossChainPreparation, CrossChainRoute];
    existingUser: [SameChainRoute, SameChainRoute];
  };
  verified: {
    name: string;
    ownerHasResolverRoles: boolean;
    hcaHasResolverRoles: boolean;
    defaultPrimary: string;
    universalAddress: string;
  };
};

function requireEnv(env: NodeJS.ProcessEnv, name: string) {
  if (!env[name]) throw new Error(`${name} is required for the live HCA check`);
}

function liveEnv() {
  const env = { ...process.env };
  if (CROSS_CHAIN && SAME_CHAIN_USER_PAID_USDC) {
    throw new Error(
      "HCA_SAME_CHAIN_USER_PAID_USDC cannot be used with HCA_CROSS_CHAIN",
    );
  }
  if (SAME_CHAIN_USER_PAID_USDC && generatedOwnerKey) {
    throw new Error(
      "HCA_OWNER_KEY must be a fresh Sepolia wallet funded with USDC for the user-paid same-chain check",
    );
  }
  env.DEPLOYMENT_NETWORK ??= "sepolia";
  env.HCA_DEPLOYMENT_NETWORK ??= env.DEPLOYMENT_NETWORK;
  env.V1_DEPLOYMENT_NETWORK ??= "sepolia";
  env.HCA_OWNER_KEY = liveOwnerKey;
  env.HCA_OWNER_KEY_SOURCE = generatedOwnerKey ? "generated" : "supplied";
  env.HCA_EXPECT_INITIAL_STATE =
    generatedOwnerKey || SAME_CHAIN_USER_PAID_USDC ? "new" : "either";
  env.HCA_EXPECT_DEFAULT_REVERSE_FALLBACK = "1";
  env.HCA_SPONSORED = SAME_CHAIN_USER_PAID_USDC ? "0" : "1";
  env.RHINESTONE_API_KEY ??= env.RHINESTONE_SDK_API_KEY;
  if (SAME_CHAIN_USER_PAID_USDC) {
    env.HCA_FEE_ASSET = "USDC";
    env.HCA_TEST_PAYMENT_TOKEN ??= SEPOLIA_USDC;
    env.HCA_SAME_CHAIN_USDC_BUDGET ??= "20000000";
    env.HCA_MAX_REFUND_AMOUNT ??= "50000000";
    env.HCA_SESSION_GAS_LIMIT ??= "1200000";
  }
  if (CROSS_CHAIN) {
    env.HCA_TEST_PAYMENT_TOKEN ??= SEPOLIA_USDC;
    requireEnv(env, "BASE_SEPOLIA_RPC_URL");
    requireEnv(env, "CIRCLE_API_KEY");
  }
  delete env.HCA_GENERATE_OWNER;
  delete env.HCA_DRY_RUN_ONLY;

  requireEnv(env, "SEPOLIA_RPC_URL");
  requireEnv(env, "DEPLOYER_KEY");
  requireEnv(env, "RHINESTONE_API_KEY");
  return env;
}

function parseSummary(stdout: string): LiveRegistrationSummary {
  const trimmed = stdout.trim();
  const start = trimmed.lastIndexOf("\n{");
  return JSON.parse(start === -1 ? trimmed : trimmed.slice(start + 1));
}

const proc = Bun.spawn(["bun", "script/liveHcaRhinestoneRegistration.ts"], {
  cwd: contractsRoot,
  env: liveEnv(),
  stdout: "pipe",
  stderr: "pipe",
});
const timeout = setTimeout(() => proc.kill(), LIVE_RUN_TIMEOUT_MS);
const [stdout, stderr, exitCode] = await Promise.all([
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text(),
  proc.exited,
]);
clearTimeout(timeout);

if (exitCode !== 0) {
  throw new Error(
    `live HCA registration failed with exit code ${exitCode}\n${stdout}\n${stderr}`,
  );
}

const summary = parseSummary(stdout);
if (generatedOwnerKey) assert.equal(summary.initialState, "new");
assert.equal(
  summary.ownerKeySource,
  generatedOwnerKey ? "generated" : "supplied",
);
if (CROSS_CHAIN) {
  assert.deepEqual(summary.walletInteractions, {
    sourceFundingTransactions: 1,
    permit2Signatures: 1,
    additionalHcaOwnerSignatures: 0,
    total: 2,
  });
  assert(summary.crossChain);
  assert.equal(BigInt(summary.crossChain.source.walletBalanceAfter), 0n);
  assert.equal(
    BigInt(summary.crossChain.source.sourceAccountBalanceBefore),
    0n,
  );
  assert.equal(BigInt(summary.crossChain.source.permit2AllowanceBefore), 0n);
  assert.equal(summary.crossChain.source.walletTransactions, 1);
  assert.equal(
    BigInt(summary.crossChain.source.sourceAccountBalanceAfter),
    BigInt(summary.crossChain.source.walletBalanceBefore),
  );
  assert.equal(
    summary.crossChain.source.wallet.toLowerCase(),
    summary.owner.toLowerCase(),
  );
  assert.match(
    summary.crossChain.source.fundingTransactionHash,
    /^0x[0-9a-fA-F]{64}$/,
  );
  assert(BigInt(summary.crossChain.source.fundingGasUsed) > 0n);

  const preparation = summary.flows.newUser[0] as CrossChainPreparation;
  assert.match(preparation.deploymentTransactionHash, /^0x[0-9a-fA-F]{64}$/);
  assert.match(preparation.commitTransactionHash, /^0x[0-9a-fA-F]{64}$/);
  assert(BigInt(preparation.deploymentGasUsed) > 0n);
  assert(BigInt(preparation.commitGasUsed) > 0n);

  const registration = summary.flows.newUser[1] as CrossChainRoute;
  assert.equal(registration.sourceSetupOps, 1);
  assert.equal(registration.recipientSetupOps, 0);
  assert.equal(registration.sourceWalletSignatures, 1);
  assert.equal(registration.destinationReusesPermit2Signature, true);
  assert.equal(registration.using7579, true);
  assert.equal(registration.settlementLayer, "ACROSS");
  assert.equal(registration.fundingMethod, "PERMIT2");
  assert.equal(registration.mode.slice(4, 6), "01");
  assert.match(registration.claimTransactionHash, /^0x[0-9a-fA-F]{64}$/);
  assert.match(registration.fillTransactionHash, /^0x[0-9a-fA-F]{64}$/);
  assert(summary.funding);
  assert.equal(
    BigInt(summary.funding.crossChainBalance) +
      BigInt(summary.funding.testProvisionedAmount),
    BigInt(summary.funding.amount),
  );
  if (BigInt(summary.funding.testProvisionedAmount) > 0n) {
    assert.match(
      summary.funding.provisioningTransactionHash!,
      /^0x[0-9a-fA-F]{64}$/,
    );
    assert(BigInt(summary.funding.gasUsed) > 0n);
  }

  for (const route of summary.flows.existingUser) {
    assert.equal(route.setupOps, 0);
    assert.match(route.transactionHash, /^0x[0-9a-fA-F]{64}$/);
  }
} else {
  assert.deepEqual(summary.walletInteractions, {
    paymentPermitSignatures: 1,
    ownerIntentSignatures: 1,
    postCommitWalletInteractions: 0,
    total: 2,
  });
  const amountPulled = BigInt(summary.sameChainFunding.amountPulled);
  assert(amountPulled > 0n);
  assert.equal(
    BigInt(summary.sameChainFunding.walletBalanceBeforePull) -
      BigInt(summary.sameChainFunding.walletBalanceAfter),
    amountPulled,
  );
  assert.equal(
    BigInt(summary.sameChainFunding.hcaBalanceAfter) -
      BigInt(summary.sameChainFunding.hcaBalanceBefore) +
      BigInt(summary.sameChainFunding.executionCharge),
    amountPulled,
  );
  assert.equal(BigInt(summary.sameChainFunding.allowanceAfter), 0n);
  const routes = [
    ...summary.flows.newUser,
    ...summary.flows.existingUser,
  ] as SameChainRoute[];
  assert.deepEqual(
    routes.map(({ setupOps }) => setupOps),
    [1, 0, 0, 0],
  );
  for (const route of routes) {
    assert.match(route.transactionHash, /^0x[0-9a-fA-F]{64}$/);
  }
  if (SAME_CHAIN_USER_PAID_USDC) {
    assert(summary.wallet);
    assert.equal(
      summary.wallet.address.toLowerCase(),
      summary.owner.toLowerCase(),
    );
    assert.equal(BigInt(summary.wallet.nativeBalanceBefore), 0n);
    assert.equal(BigInt(summary.wallet.nativeBalanceAfter), 0n);
    assert.equal(summary.wallet.transactionCountBefore, 0);
    assert.equal(summary.wallet.transactionCountAfter, 0);
    assert.equal(
      BigInt(routes[0]!.feePayment!.totalCharge),
      BigInt(summary.sameChainFunding.executionCharge),
    );
    for (const route of routes) {
      assert(route.gasRefunds.length > 0);
      assert(BigInt(route.feePayment!.executionFee) > 0n);
      assert.equal(
        BigInt(route.feePayment!.balanceBefore) +
          BigInt(route.feePayment!.fundedBeforeExecution) -
          BigInt(route.feePayment!.balanceAfter),
        BigInt(route.feePayment!.totalCharge),
      );
    }
  }
}
assert.equal(summary.verified.name, summary.names[1]);
assert.equal(summary.verified.defaultPrimary, summary.names[1]);
assert.equal(summary.verified.ownerHasResolverRoles, true);
assert.equal(summary.verified.hcaHasResolverRoles, true);
assert.equal(
  summary.verified.universalAddress.toLowerCase(),
  summary.owner.toLowerCase(),
);

if (CROSS_CHAIN) {
  const preparation = summary.flows.newUser[0] as CrossChainPreparation;
  const registration = summary.flows.newUser[1] as CrossChainRoute;
  console.log(
    JSON.stringify(
      {
        owner: summary.owner,
        hca: summary.hca,
        resolver: summary.resolver,
        names: summary.names,
        walletInteractions: summary.walletInteractions,
        sourceFundingTransactionHash:
          summary.crossChain!.source.fundingTransactionHash,
        permissionlessPreparation: {
          deploymentTransactionHash: preparation.deploymentTransactionHash,
          commitTransactionHash: preparation.commitTransactionHash,
        },
        crossChainRegistration: {
          claimTransactionHash: registration.claimTransactionHash,
          fillTransactionHash: registration.fillTransactionHash,
          claimGasUsed: registration.claimGasUsed,
          fillGasUsed: registration.fillGasUsed,
        },
        existingUserFunding: summary.funding,
        sessionTransactions: {
          secondCommit: summary.flows.existingUser[0].transactionHash,
          secondReveal: summary.flows.existingUser[1].transactionHash,
        },
        verified: summary.verified,
      },
      null,
      2,
    ),
  );
} else {
  const [firstCommit, firstReveal] = summary.flows.newUser as SameChainRoute[];
  const [secondCommit, secondReveal] = summary.flows
    .existingUser as SameChainRoute[];
  console.log(
    JSON.stringify(
      {
        owner: summary.owner,
        hca: summary.hca,
        resolver: summary.resolver,
        names: summary.names,
        walletInteractions: summary.walletInteractions,
        transactions: {
          firstCommit: firstCommit!.transactionHash,
          firstReveal: firstReveal!.transactionHash,
          secondCommit: secondCommit!.transactionHash,
          secondReveal: secondReveal!.transactionHash,
        },
        verified: summary.verified,
      },
      null,
      2,
    ),
  );
}
console.log(`live HCA check passed for ${summary.names.join(" and ")}`);
