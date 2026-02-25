import { COIN_TYPE_ETH, type KnownProfile } from "../../utils/resolutions.js";

export const KNOWN_DNS: KnownProfile[] = [
  {
    name: "taytems.xyz",
    addresses: [
      {
        coinType: COIN_TYPE_ETH,
        value: "0x8e8Db5CcEF88cca9d624701Db544989C996E3216",
      },
    ],
  },
  {
    name: "raffy.xyz",
    texts: [{ key: "avatar", value: "https://raffy.xyz/ens.jpg" }],
    addresses: [
      {
        coinType: COIN_TYPE_ETH,
        value: "0x51050ec063d393217B436747617aD1C2285Aeeee",
      },
    ],
  },
];
