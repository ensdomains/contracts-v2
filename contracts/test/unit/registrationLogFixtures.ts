// Registrar and controller logs as a node returns them, for tests of the code that
// reads the v1 registrar's history.

import {
  type AbiEvent,
  type Address,
  encodeAbiParameters,
  encodeEventTopics,
  getAddress,
  type Hex,
  keccak256,
  stringToBytes,
} from "viem";

import {
  CONTROLLER_LABEL_EVENTS,
  type RawLog,
  REGISTRAR_EVENTS,
} from "../../script/migrations/registrationLogs.js";

export const REGISTRAR = getAddress(
  "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85",
);
export const CONTROLLER = getAddress(
  "0x253553366Da8546fC250F225fe3d25d0C782303b",
);
export const HOLDER = getAddress("0x00000000000000000000000000000000000000b0");

const [NAME_REGISTERED, NAME_RENEWED] = REGISTRAR_EVENTS;

export const idOf = (label: string) => BigInt(keccak256(stringToBytes(label)));

// A log of `event` as a node returns it: indexed arguments in the topics, the rest
// ABI-encoded in the data.
export function logOf(
  address: Address,
  event: AbiEvent,
  args: Record<string, unknown>,
): RawLog {
  const topics = encodeEventTopics({
    abi: [event],
    args: Object.fromEntries(
      event.inputs
        .filter((input) => input.indexed)
        .map((input) => [input.name, args[input.name as string]]),
    ),
  } as never) as Hex[];
  const unindexed = event.inputs.filter((input) => !input.indexed);
  const data = encodeAbiParameters(
    unindexed,
    unindexed.map((input) => args[input.name as string]),
  );
  return { address, topics, data };
}

export const registered = (label: string, expires: bigint, owner = HOLDER) =>
  logOf(REGISTRAR, NAME_REGISTERED, { id: idOf(label), owner, expires });
export const renewed = (label: string, expires: bigint) =>
  logOf(REGISTRAR, NAME_RENEWED, { id: idOf(label), expires });

// A controller event of the given shape, carrying `label` beside `labelhash`.
export function controllerLog(
  shape: number,
  label: string,
  labelhash: Hex = keccak256(stringToBytes(label)),
): RawLog {
  return logOf(CONTROLLER, CONTROLLER_LABEL_EVENTS[shape] as AbiEvent, {
    label,
    labelhash,
    owner: HOLDER,
    cost: 1n,
    baseCost: 1n,
    premium: 0n,
    expires: 1n,
    referrer: `0x${"00".repeat(32)}`,
  });
}

// A chain whose logs sit at the given blocks, served oldest first like a node.
export function chainOf(entries: Array<[bigint, RawLog]>) {
  const requests: Array<[bigint, bigint]> = [];
  return {
    requests,
    read: async (fromBlock: bigint, toBlock: bigint) => {
      requests.push([fromBlock, toBlock]);
      return entries
        .filter(([block]) => block >= fromBlock && block <= toBlock)
        .map(([, log]) => log);
    },
  };
}
