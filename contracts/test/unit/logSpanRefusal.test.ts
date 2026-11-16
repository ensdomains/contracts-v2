import { describe, expect, it } from "bun:test";

import {
  isLogSpanRefusal,
  isLogSpanRefusalMessage,
} from "../../script/migrations/logSpanRefusal.js";

// The messages real providers answer an over-wide `eth_getLogs` with. Getting one
// wrong in either direction is costly: a refusal read as fatal aborts an audit the
// freeze depends on, and a throttle read as a refusal bisects the range toward single
// blocks, hundreds of doomed requests at a time.
describe("log span refusals", () => {
  const refusals = [
    // Infura
    "query returned more than 10000 results",
    "Log response size exceeded. this block range should work: [0x1, 0x2]",
    // Alchemy
    "Logs matched by query exceeds limit of 10000",
    // QuickNode / Ankr, which pluralise the noun
    "eth_getLogs is limited to a 1000 blocks range",
    // Cloudflare / others
    "block range is too large",
    "please narrow your filter",
    "query timeout exceeded",
  ];
  for (const message of refusals) {
    it(`treats a span refusal as one: ${message.slice(0, 40)}`, () => {
      expect(isLogSpanRefusalMessage(message)).toBe(true);
    });
  }

  const failures = [
    // The one a keyword match gets wrong. Bisecting answers nothing here; the
    // request has to be retried or slowed, and the error has to reach the caller.
    "rate limit exceeded",
    "429 Too Many Requests",
    "daily request limit reached",
    "execution reverted",
    "invalid params: unknown block",
    "socket hang up",
  ];
  for (const message of failures) {
    it(`leaves a real failure alone: ${message.slice(0, 40)}`, () => {
      expect(isLogSpanRefusalMessage(message)).toBe(false);
    });
  }
});

describe("log span refusal errors", () => {
  // viem's shape: the provider's error object is the innermost cause, and each
  // wrapper repeats a generic message.
  function wrapped(message: string, data?: unknown): Error {
    const rpc = Object.assign(new Error("RPC Request failed."), {
      data,
      cause: { code: -32602, message, data },
    });
    return new Error(
      "Invalid parameters were provided to the RPC method.\n\nDetails: " +
        message,
      { cause: rpc },
    );
  }

  it("reads a refusal given only in the error's data", () => {
    const error = wrapped(
      "invalid params",
      "Query returned more than 20000 results. Try with this block range [0xb71b00, 0xbaeb8f].",
    );
    expect(isLogSpanRefusalMessage((error as Error).message)).toBe(false);
    expect(isLogSpanRefusal(error)).toBe(true);
  });

  it("reads a refusal given in a message down the chain", () => {
    expect(isLogSpanRefusal(wrapped("block range is too large"))).toBe(true);
  });

  it("leaves a real failure alone", () => {
    expect(isLogSpanRefusal(wrapped("rate limit exceeded"))).toBe(false);
    expect(isLogSpanRefusal(new Error("socket hang up"))).toBe(false);
    expect(isLogSpanRefusal(undefined)).toBe(false);
  });
});
