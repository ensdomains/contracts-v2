import { artifacts, execute } from "@rocketh";
import { encodeAbiParameters, parseAbiParameters } from "viem";

export default execute(
  async ({ deploy, get, namedAccounts: { deployer } }) => {
    const hcaFactory = get<(typeof artifacts.HCAFactory)["abi"]>("HCAFactory");
    const entryPoint = get<(typeof artifacts.EntryPoint)["abi"]>("Entrypoint");
    const hcaModule = get<(typeof artifacts.HCAModule)["abi"]>("HCAModule");
    const intentExecutor =
      get<(typeof artifacts.IntentExecutor)["abi"]>("IntentExecutor");

    await deploy("HCAImplementation", {
      account: deployer,
      artifact: artifacts.HCA,
      args: [
        hcaFactory.address,
        entryPoint.address,
        hcaModule.address,
        intentExecutor.address,
        encodeAbiParameters(
          parseAbiParameters(
            "uint256 threshold, (address addr, uint48 expiration)[] owners",
          ),
          [
            1n,
            [
              {
                addr: "0x0000000000000000000000000000000000000001",
                expiration: 281474976710655,
              },
            ],
          ],
        ),
      ],
    });
  },
  {
    tags: ["HCAImplementation", "v2"],
    dependencies: [
      "HCAFactoryBase",
      "Entrypoint",
      "HCAModule",
      "IntentExecutor",
    ],
  },
);
