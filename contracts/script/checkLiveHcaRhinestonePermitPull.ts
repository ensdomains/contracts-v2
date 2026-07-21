import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { generatePrivateKey } from "viem/accounts";

const contractsRoot = fileURLToPath(new URL("..", import.meta.url));
const suppliedOwnerKey = process.env.HCA_OWNER_KEY?.trim();
const generatedOwnerKey = !suppliedOwnerKey;
const ownerKey = suppliedOwnerKey ?? generatePrivateKey();
const sourceChain = process.env.HCA_SOURCE_CHAIN ?? "base-sepolia";
if (!new Set(["base-sepolia", "arbitrum-sepolia"]).has(sourceChain)) {
  throw new Error("HCA_SOURCE_CHAIN must be base-sepolia or arbitrum-sepolia");
}

type Refund = { token: string; exchangeRate: string; overhead: string };
type FeePayment = {
  token: string;
  balanceBefore: string;
  balanceAfter: string;
  totalCharge: string;
  protocolSpend: string;
  executionFee: string;
};
type SessionRoute = {
  transactionHash: string;
  setupOps: number;
  gasRefunds: Refund[];
  feePayment: FeePayment;
};
type CrossChainRoute = {
  claimTransactionHash: string;
  fillTransactionHash: string;
  sourceSetupOps: number;
  recipientSetupOps: number;
  sourceWalletSignatures: number;
  destinationReusesPermit2Signature: boolean;
  sourcePullViaNexus: boolean;
  sourcePermitViaEip2612: boolean;
  sourcePullAmount: string;
  sourcePermit2Amount: string;
  using7579: boolean;
  settlementLayer: string;
  fundingMethod: string;
  sponsored: boolean;
  feeAsset: string;
};
type Summary = {
  initialState: "new" | "existing";
  names: [string, string];
  owner: string;
  hca: string;
  walletInteractions: {
    sourceFundingTransactions: number;
    sourcePermitSignatures: number;
    permit2Signatures: number;
    additionalHcaOwnerSignatures: number;
    total: number;
  };
  crossChain: {
    targetAmount: string;
    targetToken: string;
    source: {
      sourceType: "nexus";
      nexusFundingMode: "permit-pull";
      wallet: string;
      sourceAccount: string;
      walletNativeBalance: string;
      walletNativeBalanceAfterClaim: string;
      walletBalanceBefore: string;
      walletBalanceAfter: string;
      walletBalanceAfterClaim: string;
      sourceAccountBalanceBefore: string;
      sourceAccountBalanceAfter: string;
      sourceAccountBalanceAfterClaim: string;
      routeSourceAmount: string;
      walletToSourceAllowanceBefore: string;
      walletToSourceAllowanceAfterClaim: string;
      permitNonceBefore: string;
      permitNonceAfterClaim: string;
      permitSignatureCount: number;
      fundingAction: "EIP-2612 permit";
      walletTransactions: number;
    };
  };
  flows: {
    newUser: [CrossChainRoute, SessionRoute];
    existingUser: [SessionRoute, SessionRoute];
  };
  funding: {
    source: "cross-chain USDC";
    hcaBalanceAfterCrossChain: string;
    operatorTopUp: string;
  };
  verified: {
    name: string;
    ownerHasResolverRoles: boolean;
    hcaHasResolverRoles: boolean;
    defaultPrimary: string;
    universalAddress: string;
  };
};

const env = { ...process.env };
env.DEPLOYMENT_NETWORK ??= "sepolia";
env.HCA_DEPLOYMENT_NETWORK ??= env.DEPLOYMENT_NETWORK;
env.V1_DEPLOYMENT_NETWORK ??= "sepolia";
env.HCA_SOURCE_CHAIN = sourceChain;
env.HCA_SOURCE_RPC_URL ??=
  sourceChain === "base-sepolia"
    ? env.BASE_SEPOLIA_RPC_URL
    : env.ARBITRUM_SEPOLIA_RPC_URL;
env.HCA_OWNER_KEY = ownerKey;
env.HCA_OWNER_KEY_SOURCE = generatedOwnerKey ? "generated" : "supplied";
env.HCA_EXPECT_INITIAL_STATE = "new";
env.HCA_EXPECT_DEFAULT_REVERSE_FALLBACK = "1";
env.HCA_SPONSORED = "0";
env.HCA_FEE_ASSET = "USDC";
env.HCA_USER_PAID_USDC = "1";
env.HCA_CROSS_CHAIN = "1";
env.HCA_CROSS_CHAIN_SOURCE = "nexus";
env.HCA_CROSS_CHAIN_NEXUS_FUNDING = "permit-pull";
env.HCA_CROSS_CHAIN_SOURCE_AMOUNT ??=
  sourceChain === "base-sepolia" ? "20000000" : "28000000";
env.HCA_CROSS_CHAIN_TARGET_AMOUNT ??= "14000000";
env.HCA_TEST_PAYMENT_TOKEN ??= "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
env.RHINESTONE_API_KEY ??=
  env.RHINESTONE_SDK_API_KEY ?? env.VITE_RHINESTONE_API_KEY;
delete env.HCA_GENERATE_OWNER;
delete env.HCA_DRY_RUN_ONLY;

for (const name of [
  "SEPOLIA_RPC_URL",
  "HCA_SOURCE_RPC_URL",
  "DEPLOYER_KEY",
  "RHINESTONE_API_KEY",
]) {
  if (!env[name]) throw new Error(`${name} is required for the live check`);
}

const proc = Bun.spawn(["bun", "script/liveHcaRhinestoneRegistration.ts"], {
  cwd: contractsRoot,
  env,
  stdout: "pipe",
  stderr: "pipe",
});
const timeout = setTimeout(() => proc.kill(), 1_200_000);
const [stdout, stderr, exitCode] = await Promise.all([
  new Response(proc.stdout).text(),
  new Response(proc.stderr).text(),
  proc.exited,
]);
clearTimeout(timeout);
if (exitCode !== 0) {
  throw new Error(
    `USDC-only live check failed with exit code ${exitCode}\n${stdout}\n${stderr}`,
  );
}

const trimmed = stdout.trim();
const jsonStart = trimmed.lastIndexOf("\n{");
const summary = JSON.parse(
  jsonStart === -1 ? trimmed : trimmed.slice(jsonStart + 1),
) as Summary;
assert.equal(summary.initialState, "new");
assert.deepEqual(summary.walletInteractions, {
  sourceFundingTransactions: 0,
  sourcePermitSignatures: 1,
  permit2Signatures: 1,
  additionalHcaOwnerSignatures: 0,
  total: 2,
});

const source = summary.crossChain.source;
const [crossChainCommit, firstReveal] = summary.flows.newUser;
assert.equal(source.sourceType, "nexus");
assert.equal(source.nexusFundingMode, "permit-pull");
assert.equal(source.wallet.toLowerCase(), summary.owner.toLowerCase());
assert.equal(BigInt(source.walletNativeBalance), 0n);
assert.equal(BigInt(source.walletNativeBalanceAfterClaim), 0n);
assert.equal(source.walletBalanceBefore, source.walletBalanceAfter);
assert.equal(
  BigInt(source.walletBalanceAfterClaim),
  BigInt(source.walletBalanceBefore) - BigInt(source.routeSourceAmount),
);
assert.equal(BigInt(source.sourceAccountBalanceBefore), 0n);
assert.equal(BigInt(source.sourceAccountBalanceAfter), 0n);
assert.equal(
  BigInt(source.sourceAccountBalanceAfterClaim),
  BigInt(source.routeSourceAmount) -
    BigInt(crossChainCommit.sourcePermit2Amount),
);
assert.equal(BigInt(source.walletToSourceAllowanceBefore), 0n);
assert.equal(BigInt(source.walletToSourceAllowanceAfterClaim), 0n);
assert.equal(
  BigInt(source.permitNonceAfterClaim),
  BigInt(source.permitNonceBefore) + 1n,
);
assert.equal(source.permitSignatureCount, 1);
assert.equal(source.fundingAction, "EIP-2612 permit");
assert.equal(source.walletTransactions, 0);

assert.equal(crossChainCommit.sourceSetupOps, 1);
assert.equal(crossChainCommit.recipientSetupOps, 1);
assert.equal(crossChainCommit.sourceWalletSignatures, 1);
assert.equal(crossChainCommit.destinationReusesPermit2Signature, true);
assert.equal(crossChainCommit.sourcePullViaNexus, true);
assert.equal(crossChainCommit.sourcePermitViaEip2612, true);
assert.equal(crossChainCommit.sourcePullAmount, source.routeSourceAmount);
assert(BigInt(crossChainCommit.sourcePermit2Amount) > 0n);
assert(
  BigInt(crossChainCommit.sourcePermit2Amount) <=
    BigInt(crossChainCommit.sourcePullAmount),
);
assert.equal(crossChainCommit.using7579, true);
assert.equal(crossChainCommit.settlementLayer, "ACROSS");
assert.equal(crossChainCommit.fundingMethod, "PERMIT2");
assert.equal(crossChainCommit.sponsored, false);
assert.equal(crossChainCommit.feeAsset, "USDC");
assert.match(crossChainCommit.claimTransactionHash, /^0x[0-9a-fA-F]{64}$/);
assert.match(crossChainCommit.fillTransactionHash, /^0x[0-9a-fA-F]{64}$/);

const targetToken = summary.crossChain.targetToken.toLowerCase();
for (const route of [firstReveal, ...summary.flows.existingUser]) {
  assert.match(route.transactionHash, /^0x[0-9a-fA-F]{64}$/);
  assert.equal(route.setupOps, 0);
  assert(route.gasRefunds.length > 0);
  for (const refund of route.gasRefunds) {
    assert.equal(refund.token.toLowerCase(), targetToken);
    assert(BigInt(refund.exchangeRate) > 0n);
    assert(BigInt(refund.overhead) > 0n);
  }
  assert.equal(route.feePayment.token.toLowerCase(), targetToken);
  assert(BigInt(route.feePayment.executionFee) > 0n);
  assert.equal(
    BigInt(route.feePayment.balanceBefore) -
      BigInt(route.feePayment.balanceAfter),
    BigInt(route.feePayment.totalCharge),
  );
}
assert.equal(summary.funding.source, "cross-chain USDC");
assert.equal(
  summary.funding.hcaBalanceAfterCrossChain,
  summary.crossChain.targetAmount,
);
assert.equal(BigInt(summary.funding.operatorTopUp), 0n);
assert.equal(summary.verified.name, summary.names[1]);
assert.equal(summary.verified.defaultPrimary, summary.names[1]);
assert.equal(summary.verified.ownerHasResolverRoles, true);
assert.equal(summary.verified.hcaHasResolverRoles, true);
assert.equal(
  summary.verified.universalAddress.toLowerCase(),
  summary.owner.toLowerCase(),
);

console.log(
  JSON.stringify(
    {
      owner: summary.owner,
      hca: summary.hca,
      names: summary.names,
      walletInteractions: summary.walletInteractions,
      sourceUsdcBudget: source.routeSourceAmount,
      sourceUsdcSpent: crossChainCommit.sourcePermit2Amount,
      sourceUsdcResidual: source.sourceAccountBalanceAfterClaim,
      targetUsdcDelivered: summary.crossChain.targetAmount,
      claimTransactionHash: crossChainCommit.claimTransactionHash,
      fillTransactionHash: crossChainCommit.fillTransactionHash,
      sessionTransactions: [
        firstReveal.transactionHash,
        ...summary.flows.existingUser.map(
          ({ transactionHash }) => transactionHash,
        ),
      ],
      executionFees: [
        firstReveal.feePayment.executionFee,
        ...summary.flows.existingUser.map(
          ({ feePayment }) => feePayment.executionFee,
        ),
      ],
      verified: summary.verified,
    },
    null,
    2,
  ),
);
