// Compares the code actually running at an address against the artifact the
// deployment claims is there.
//
// Nothing else does this. Source verification on Etherscan/Sourcify is a one-way
// submission, not a check you can re-run, and every `getCode` call in this repo is a
// liveness probe rather than a comparison. So a deployment record can name a contract
// that is not the contract at that address — from a stale artifact, a partial deploy,
// or a record copied between namespaces — and every downstream check would happily
// call the wrong code.

export type ImmutableReferences = Record<
  string,
  Array<{ start: number; length: number }>
>;

export type BytecodeComparison =
  | { kind: "match" }
  | { kind: "no-code" }
  | { kind: "length-mismatch"; expected: number; actual: number }
  | { kind: "differs"; firstDifferenceOffset: number };

function strip0x(value: string): string {
  return value.startsWith("0x") ? value.slice(2) : value;
}

// Immutable values are written into the runtime code at construction, so they differ
// between the compiler's output and the deployed copy by design. Their byte ranges
// are blanked in both before comparing, leaving only the parts that must be identical.
export function maskImmutables(
  bytecode: string,
  immutableReferences: ImmutableReferences | undefined,
): string {
  const hex = strip0x(bytecode);
  if (!immutableReferences) return hex;

  const bytes = hex.split("");
  for (const ranges of Object.values(immutableReferences)) {
    for (const { start, length } of ranges) {
      // Offsets and lengths are in bytes; the string holds two characters per byte.
      for (let index = start * 2; index < (start + length) * 2; index++) {
        if (index < bytes.length) bytes[index] = "0";
      }
    }
  }
  return bytes.join("");
}

export function compareDeployedBytecode(opts: {
  onChain: string | null | undefined;
  artifact: string | undefined;
  immutableReferences?: ImmutableReferences;
}): BytecodeComparison {
  const onChain = strip0x(opts.onChain ?? "");
  if (onChain === "") return { kind: "no-code" };

  const expected = maskImmutables(
    opts.artifact ?? "",
    opts.immutableReferences,
  ).toLowerCase();
  const actual = maskImmutables(
    onChain,
    opts.immutableReferences,
  ).toLowerCase();

  if (expected.length !== actual.length) {
    return {
      kind: "length-mismatch",
      expected: expected.length / 2,
      actual: actual.length / 2,
    };
  }
  for (let index = 0; index < expected.length; index++) {
    if (expected[index] !== actual[index]) {
      return { kind: "differs", firstDifferenceOffset: Math.floor(index / 2) };
    }
  }
  return { kind: "match" };
}

export function describeComparison(
  name: string,
  address: string,
  comparison: BytecodeComparison,
): string {
  switch (comparison.kind) {
    case "match":
      return `${name} ${address}: bytecode matches`;
    case "no-code":
      return `${name} ${address}: no code at address`;
    case "length-mismatch":
      return `${name} ${address}: bytecode length ${comparison.actual} on chain, artifact says ${comparison.expected}`;
    case "differs":
      return `${name} ${address}: bytecode differs from byte ${comparison.firstDifferenceOffset}`;
  }
}
