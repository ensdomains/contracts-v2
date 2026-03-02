import { labelhash } from "viem";
// note: viem's labelhash() has long-label support, which ENSv2 is not using
// we should eventually replace all labelhash(*) usage with keccak256(toBytes(*)).

export { dnsEncodeName } from "../../lib/ens-contracts/test/fixtures/dnsEncodeName.js";

// LibLabel.id()
export function idFromLabel(label: string): bigint {
  return BigInt(labelhash(label));
}

// LibLabel.withVersion()
export function idWithVersion(id: bigint, version = 0) {
  return id ^ BigInt.asUintN(32, id ^ BigInt(version));
}

//      "" => []
// "a.b.c" => ["a", "b", "c"]
export function splitName(name: string): string[] {
  return name ? name.split(".") : [];
}

//      "" => ""
// "a.b.c" => "b.c"
export function getParentName(name: string) {
  const i = name.indexOf(".");
  return i == -1 ? "" : name.slice(i + 1);
}

// "a.b.c"  0 => "a" aka firstLabel()
//         -1 => "c"
//          5 => ""
export function getLabelAt(name: string, index = 0) {
  return splitName(name).at(index) ?? "";
}
