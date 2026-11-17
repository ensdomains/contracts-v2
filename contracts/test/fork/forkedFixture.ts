import hre from "hardhat";
import { readFileSync } from "node:fs";
import { join } from "node:path";
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
  getAddress,
  parseAbi,
  toFunctionSignature,
} from "viem/utils";
import { loadLatestAddresses } from "../../script/addressDocs.js";
import { DAO_WALLET, DAO_TOKEN_SAFE } from "../../script/deploy-constants.js";

const rootDir = join(import.meta.dirname, "../../");

// USAGE: bun run test:hardhat test/fork/<Test>.test.ts

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

  const v1Dir = join(rootDir, `lib/ens-contracts/deployments/${network}`);
  const v2 = await loadLatestAddresses(join(rootDir, "deployments"), network);

  const connection = await hre.network.connect(`${network}Fork`);

  const forkedFixture = async () => {
    const ENSRegistry = await connection.viem.getContractAt(
      "ENSRegistry",
      getV1DeploymentAddress("ENSRegistry"),
    );
    const Root = await connection.viem.getContractAt(
      "Root",
      getV1DeploymentAddress("Root"),
    );
    const OffchainDNSResolver = await connection.viem.getContractAt(
      "OffchainDNSResolver",
      getV1DeploymentAddress("OffchainDNSResolver"),
    );
    const DNSRegistrar = await connection.viem.getContractAt(
      "DNSRegistrar",
      getV1DeploymentAddress("DNSRegistrar"),
    );
    const SimplePublicSuffixList = await connection.viem.getContractAt(
      "SimplePublicSuffixList",
      getV1DeploymentAddress("SimplePublicSuffixList"),
    );
    const UniversalResolver = await connection.viem.getContractAt(
      "UniversalResolverV2",
      getV2DeploymentAddress("UpgradableUniversalResolverProxy"),
    );
    const RootRegistry = await connection.viem.getContractAt(
      "PermissionedRegistry",
      getV2DeploymentAddress("RootRegistry"),
    );
    const DNSTLDResolver = await connection.viem.getContractAt(
      "DNSTLDResolver",
      getV2DeploymentAddress("DNSTLDResolver"),
    );
    const ContractNamer = await connection.viem.getContractAt(
      "ContractNamer",
      getV2DeploymentAddress("ContractNamer"),
    );
    const TemporaryDNSRegistrar = await connection.viem.getContractAt(
      "TemporaryDNSRegistrar",
      getV2DeploymentAddress("TemporaryDNSRegistrar"),
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
    getV1DeploymentAddress,
    getV2DeploymentAddress,
  };

  function getV1DeploymentAddress(name: string) {
    try {
      const { address } = JSON.parse(
        readFileSync(join(v1Dir, `${name}.json`), "utf8"),
      ) as { address: Address };
      return getAddress(address);
    } catch {
      throw new Error(`missing V1 deployment: ${name}`);
    }
  }

  function getV2DeploymentAddress(name: string) {
    const address = v2[name];
    if (!address) {
      throw new Error(`missing V2 deployment: ${name}`);
    }
    return address;
  }
}
