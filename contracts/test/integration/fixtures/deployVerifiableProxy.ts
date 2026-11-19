import {
  type Abi,
  type Account,
  type Address,
  type Chain,
  concat,
  encodeAbiParameters,
  encodeFunctionData,
  getContract,
  getContractAddress,
  getCreateAddress,
  keccak256,
  parseAbi,
  parseEventLogs,
  stringToBytes,
  type Transport,
  type WalletClient,
} from "viem";
import { Abi_VerifiableFactory } from "generated/abis/VerifiableFactory.js";
import { waitForSuccessfulTransactionReceipt } from "../../utils/waitForSuccessfulTransactionReceipt.js";

export function computeProxyLogicAddress(factoryAddress: Address) {
  return getCreateAddress({
    from: factoryAddress,
    nonce: 1n, // https://github.com/ensdomains/verifiable-factory/blob/main/src/VerifiableFactory.sol#L15
  });
}

export async function deployVerifiableProxy<
  const abi extends Abi | readonly unknown[],
>({
  walletClient,
  factoryAddress,
  implAddress,
  salt = BigInt(keccak256(stringToBytes(new Date().toISOString()))),
  abi,
  functionName,
  args,
}: {
  walletClient: WalletClient<Transport, Chain, Account>;
  factoryAddress: Address;
  implAddress: Address;
  salt?: bigint;
  abi: abi;
  functionName: string;
  args: readonly unknown[];
}) {
  const hash = await walletClient.writeContract({
    address: factoryAddress,
    abi: Abi_VerifiableFactory,
    functionName: "deployProxy",
    args: [
      implAddress,
      salt,
      encodeFunctionData({
        abi,
        functionName,
        args,
      } as Parameters<typeof encodeFunctionData>[0]),
    ],
  });
  const receipt = await waitForSuccessfulTransactionReceipt(walletClient, {
    hash,
  });
  const [log] = parseEventLogs({
    abi: Abi_VerifiableFactory,
    eventName: "ProxyDeployed",
    logs: receipt.logs,
  });
  const contract = getContract({
    abi,
    address: log.args.proxyAddress,
    client: walletClient,
  });
  return Object.assign(contract, {
    deploymentHash: hash,
    deploymentReceipt: receipt,
  });
}

export function computeVerifiableProxyAddress({
  factoryAddress,
  proxyLogic,
  deployer,
  salt,
}: {
  factoryAddress: Address;
  proxyLogic?: Address;
  deployer: Address;
  salt: bigint;
}) {
  const outerSalt = keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [deployer, salt],
    ),
  );
  const bytecode = concat([
    "0x3d604d80600a3d3981f3363d3d373d3d3d363d73",
    proxyLogic ?? computeProxyLogicAddress(factoryAddress),
    "0x5af43d82803e903d91602b57fd5bf3",
    outerSalt,
  ]);
  return getContractAddress({
    bytecode,
    from: factoryAddress,
    opcode: "CREATE2",
    salt: outerSalt,
  });
}
