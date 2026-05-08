import { artifacts, execute } from "@rocketh";
import type { Address } from "viem";

export default execute(
  async ({ deploy, execute: write, get, namedAccounts: { deployer } }) => {
    const hcaFactory =
      get<(typeof artifacts.MockHCAFactoryBasic)["abi"]>("HCAFactory");

    const publicResolverSet = await deploy("PublicResolverSet", {
      account: deployer,
      artifact: artifacts.PermissionedAddressSet,
      args: [hcaFactory.address, deployer], // TODO: ownership
    });

    const publicResolverV1 =
      get<(typeof artifacts.PublicResolver)["abi"]>("PublicResolver");

    // TODO: update these addresses
    const wrapperAwarePublicResolvers: Address[] = [
      // devnet
      publicResolverV1.address,
      // mainnet
      // "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", // PublicResolverV3: https://etherscan.io/address/0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63
      // "0xF29100983E058B709F3D539b0c765937B804AC15", // PublicResolverV4: https://etherscan.io/address/0xF29100983E058B709F3D539b0c765937B804AC15
    ];
    for (const addr of wrapperAwarePublicResolvers) {
      await write(publicResolverSet, {
        account: deployer,
        functionName: "approve",
        args: [addr, true],
      });
    }

    console.log("Wrapper-aware PublicResolvers:");
    console.table(wrapperAwarePublicResolvers);
  },
  {
    tags: ["PublicResolverSet", "v2"],
    dependencies: ["HCAFactory", "PublicResolver"],
  },
);
