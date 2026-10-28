import { parseArgs } from "node:util";
import { toHex } from "viem/utils";
import { ROLES } from "./deploy-constants.js";
import { xch } from "@ensdomains/address-encoder/coins";
import { aD } from "vitest/dist/chunks/reporters.d.DG9VKi4m.js";

const KINDS = Object.entries(ROLES).flatMap(([contract, v]) => {
  if (typeof v !== "object") return []; // remove ALL
  const m = Object.entries(v);
  if (!m.every(([, x]) => typeof x === "bigint")) return []; // remove ADMIN
  const regular = m.reduce((a, [, x]) => a | x, 0n);
  const names = m.reduce<string[]>((a, [k, x]) => {
    const [i] = nibbleShifts(x);
    a[i] = k;
    return a;
  }, []);
  return {
    contract,
    known: regular | (regular << 128n),
    names,
  };
});

const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  options: {
    json: { type: "boolean" },
    strict: { type: "boolean", default: true },
  },
  strict: true,
  allowPositionals: true,
});

if (!positionals.length) {
  console.log(ROLES);
  console.log(KINDS);
  console.log();
  console.log("Usage: [roles...]");
  console.log(`eg. bun script/roles.ts 0x101 257`);
}

const output = positionals.map((input) => {
  let roleBitmap: bigint;
  try {
    roleBitmap = BigInt(input);
    if (roleBitmap & ~ROLES.ALL) throw new Error("invalid bitmap");
  } catch (err: unknown) {
    return { input, error: String(err) };
  }
  const matches = KINDS.flatMap((kind) => {
    const unknown = roleBitmap & (ROLES.ALL ^ kind.known);
    if (values.strict && unknown) return [];
    const roles = kind.names.flatMap((role, index) => {
      const bit = roleBit(index);
      const regular = !!(roleBitmap & bit);
      const admin = !!((roleBitmap >> 128n) & bit);
      if (!regular && !admin) return [];
      return { role, index, regular, admin };
      // const regular = roleBitmap & bit;
      // const admin = (roleBitmap >> 128n) & bit;
      // if (regular && admin) {
      //   return ansi(35, `${x}+ADMIN`); // purple
      // } else if (admin) {
      //   return ansi(31, `${x}_ADMIN`); // red
      // } else if (regular) {
      //   return ansi(36, x); // blue
      // } else {
      // }
    }, []);
    return { contract: kind.contract, unknown, matrix: roles };
  });

  return {
    input,
    parsed: {
      bytes32: toHex(roleBitmap, { size: 32 }),
      uint256: roleBitmap,
      nibbles: nibbleShifts(roleBitmap),
    },
    matches,
  };
});

if (values.json) {
  console.log(
    JSON.stringify(
      output,
      (_, x) => (typeof x === "bigint" ? `${x}n` : x),
      "  ",
    ),
  );
} else {
  const X = ansi(92, "X");
  output.forEach((out, i) => {
    if (output.length > 1) {
      if (i) console.log();
      console.log(`[${i + 1}] "${out.input}"`);
    }
    if (!out.parsed) {
      console.log(ansi(31, out.error));
      return;
    }
    console.table([
      { form: "bytes32", value: ansi(32, out.parsed.bytes32) },
      { form: "uint256", value: out.parsed.uint256 },
      { form: "nibbles", value: out.parsed.nibbles },
    ]);
    out.matches.forEach((match) => {
      console.table(
        match.matrix.flatMap((x, i) => {
          return {
            [`${match.contract} role`]: x.role,
            regular: x.regular ? `   ${X}` : "",
            admin: x.admin ? `  ${X}` : "",
          };
        }),
      );
    });
  });
}

function nibbleShifts(u: bigint): number[] {
  const v = [];
  for (let i = 0; u; u >>= 4n, ++i) {
    if (u & 1n) v.push(i);
  }
  return v.reverse();
}

function roleBit(i: number): bigint {
  return 1n << BigInt(i << 2);
}

function ansi(c: any, x: any) {
  return `\x1b[${c}m${x}\x1b[0m`;
}
