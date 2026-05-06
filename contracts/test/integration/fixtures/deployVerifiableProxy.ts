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
  keccak256,
  parseAbi,
  parseEventLogs,
  stringToBytes,
  type Transport,
  type WalletClient,
} from "viem";
import { waitForSuccessfulTransactionReceipt } from "../../utils/waitForSuccessfulTransactionReceipt.ts";

const verifiableFactoryAbi = parseAbi([
  "function deployProxy(address implementation, uint256 salt, bytes data)",
  "event ProxyDeployed(address indexed sender, address indexed proxyAddress, uint256 salt, address implementation)",
]);

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
    abi: verifiableFactoryAbi,
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
    abi: verifiableFactoryAbi,
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
  proxyLogic: Address;
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
    proxyLogic,
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
