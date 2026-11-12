import hre from "hardhat";
import {
  type Account,
  type Address,
  type Abi,
  type AbiFunction,
  type Hex,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type AbiStateMutability,
  getContract,
  zeroAddress,
} from "viem";
import {
  encodeFunctionData,
  encodePacked,
  parseAbi,
  toFunctionSignature,
} from "viem/utils";
import {
  DAO_WALLET,
  DAO_TOKEN_SAFE,
  DEPLOYED_UNIVERSAL_RESOLVER_PROXY,
} from "../../script/deploy-constants.js";

// USAGE: bun run test:hardhat test/fork/<Test>.test.ts

// TODO: make this robust once deployments are consolidated

// https://docs.safe.global/reference-smart-account/transactions/execTransaction
const SAFE_PROXY_ABI = parseAbi([
  "function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) payable returns (bool success)",
]);

// https://docs.safefoundation.org/smart-account/signatures#pre-validated-signatures
function safeProxyPrevalidatedSignature(caller: Address) {
  return encodePacked(
    ["uint96", "bytes20", "uint256", "uint8"],
    [0n, caller, 0n, 1],
  );
}

export async function forkAndAttach(network = "mainnet") {
  if (network !== "mainnet") {
    throw new Error(`unsupported fork: ${network}`);
  }

  const connection = await hre.network.connect(`${network}Fork`);

  const forkedFixture = async () => {
    const ENSRegistry = await connection.viem.getContractAt(
      "ENSRegistry",
      "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e",
    );
    const Root = await connection.viem.getContractAt(
      "Root",
      "0xaB528d626EC275E3faD363fF1393A41F581c5897",
    );
    const OffchainDNSResolver = await connection.viem.getContractAt(
      "OffchainDNSResolver",
      "0x965e1eC7510E9fEDE8F754A6e8662e068c770388",
    );
    const DNSRegistrar = await connection.viem.getContractAt(
      "DNSRegistrar",
      "0x941DE2288fa17886fD5e0dCE9341954612c90aeF",
    );
    const SimplePublicSuffixList = await connection.viem.getContractAt(
      "SimplePublicSuffixList",
      "0x823BDa9cA8c47d072376eCD595530c8fb2fAa3ED",
    );
    const UniversalResolver = await connection.viem.getContractAt(
      "UniversalResolverV2",
      DEPLOYED_UNIVERSAL_RESOLVER_PROXY,
    );
    const RootRegistry = await connection.viem.getContractAt(
      "PermissionedRegistry",
      "0x2553c09bE6447BeFfdB86FA622ad41fB8f77A91e",
    );
    const DNSTLDResolver = await connection.viem.getContractAt(
      "DNSTLDResolver",
      "0x6695327EE70F41151d2cBADC3ABBb6e4a58e739c",
    );
    const ContractNamer = await connection.viem.getContractAt(
      "ContractNamer",
      "0x5cdaf63d4c2a01218149dde707e5bc239c68730c",
    );
    const TemporaryDNSRegistrar = await connection.viem.getContractAt(
      "TemporaryDNSRegistrar",
      "0x9d6D535f08be25A9A2FdA1a1C21217D27d81cC61",
    );

    // derivable
    const [
      ethRegistry,
      batchGatewayProvider,
      dnssecGatewayProvider,
      dnssecImpl,
    ] = await Promise.all([
      RootRegistry.read.getSubregistry(["eth"]),
      DNSTLDResolver.read.BATCH_GATEWAY_PROVIDER(),
      DNSTLDResolver.read.ORACLE_GATEWAY_PROVIDER(),
      DNSTLDResolver.read.DNSSEC_ORACLE(),
    ]);
    const EthRegistry = await connection.viem.getContractAt(
      "PermissionedRegistry",
      ethRegistry,
    );
    const BatchGatewayProvider = await connection.viem.getContractAt(
      "GatewayProvider",
      batchGatewayProvider,
    );
    const DNSSECGatewayProvider = await connection.viem.getContractAt(
      "GatewayProvider",
      dnssecGatewayProvider,
    );
    const DNSSECImpl = await connection.viem.getContractAt(
      "DNSSECImpl",
      dnssecImpl,
    );

    const namedAccounts = {
      DAO_WALLET: await impersonate(DAO_WALLET),
      DAO_TOKEN_SAFE: await impersonate(DAO_TOKEN_SAFE),
    };

    const DAOTokenSafe = getContract({
      address: DAO_TOKEN_SAFE,
      abi: SAFE_PROXY_ABI,
      client: {
        wallet: await connection.viem.getWalletClient(DAO_WALLET),
      },
    });

    return {
      v1: {
        ENSRegistry,
        Root,
        DNSRegistrar,
        OffchainDNSResolver,
      },
      SimplePublicSuffixList,
      DNSSECImpl,
      RootRegistry,
      EthRegistry,
      DNSTLDResolver,
      TemporaryDNSRegistrar,
      UniversalResolver,
      BatchGatewayProvider,
      DNSSECGatewayProvider,
      ContractNamer,
      DAOTokenSafe,
      namedAccounts,
      impersonate,
      executeDAO,
      safeProxyCallArguments,
    };

    async function impersonate(address: Address): Promise<Account> {
      await connection.networkHelpers.impersonateAccount(address);
      await connection.networkHelpers.setBalance(address, 1e18);
      return { type: "json-rpc", address };
    }

    async function executeDAO<
      const abi extends Abi,
      name extends ContractFunctionName<abi, writeable>,
      writeable extends AbiStateMutability,
    >({
      contract,
      functionName,
      args,
      reason,
    }: {
      contract: { abi: abi; address: Address; write: any };
      functionName: name;
      args: ContractFunctionArgs<abi, writeable, name>;
      reason?: string;
    }) {
      const hash: Hex = await contract.write[functionName](args, {
        account: namedAccounts.DAO_WALLET,
      });
      console.log(
        "\x1b[31mDAO\x1b[0m",
        JSON.stringify(
          {
            reason,
            fn: toFunctionSignature(
              contract.abi.find(
                (x): x is AbiFunction =>
                  x.type === "function" && x.name === functionName,
              )!,
            ),
            args,
            to: contract.address,
            calldata: encodeFunctionData({
              abi: contract.abi,
              functionName,
              args,
            } as never),
          },
          (_, x) => (typeof x === "bigint" ? `0x${x.toString(16)}` : x),
          "\t",
        ),
      );
      return hash;
    }

    function safeProxyCallArguments(
      target: Address,
      calldata: Hex,
    ): ContractFunctionArgs<
      typeof SAFE_PROXY_ABI,
      AbiStateMutability,
      "execTransaction"
    > {
      return [
        target,
        0n,
        calldata,
        0, // CALL
        0n,
        0n,
        0n,
        zeroAddress, // gas token
        zeroAddress, // refund
        safeProxyPrevalidatedSignature(DAO_WALLET),
      ];
    }
  };

  return {
    connection,
    forkedFixture,
  };
}
