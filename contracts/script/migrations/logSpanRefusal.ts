/// Recognising a provider's refusal of a log query's *span*, as opposed to a failure
/// of the query itself.
///
/// A span refusal means "ask for less" and is answered by bisecting the range; every
/// other error is a real failure. A read may ask for the same blocks again after one,
/// as `queryRetry.ts` describes, but must never step past them, because a scan that
/// quietly narrows past an unrelated fault returns a partial view of the chain and the
/// audits built on it are explicit that a partial result must never pass for a
/// complete one.
///
/// The distinction is drawn on an allowlist of phrasings rather than on keywords.
/// Matching a bare `limit` or `too many` sweeps in `rate limit exceeded`, and a
/// throttled endpoint is then bisected toward single blocks — hundreds of doomed
/// requests — instead of surfacing the throttle.

/// Phrasings that mean the block range or the result count exceeded a server-side cap.
/// Each is a substring match against the lower-cased message chain.
const LOG_SPAN_REFUSALS = [
  "block range",
  // Some providers pluralise it: "eth_getLogs is limited to a 1000 blocks range".
  "blocks range",
  "range exceeds",
  // Some put the offending count between the words, e.g. Infura's
  // "range 11390003 exceeds limit of 10000", which "range exceeds" misses.
  "exceeds limit",
  "exceed maximum block range",
  "narrow your filter",
  "query returned more than",
  "more than 10000 results",
  "log response size",
  "response size exceeded",
  "query timeout exceeded",
  "query exceeds max results",
];

/// Whether a message describes a refusal of the span rather than of the query.
export function isLogSpanRefusalMessage(message: string): boolean {
  const normalized = message.toLowerCase();
  return LOG_SPAN_REFUSALS.some((refusal) => normalized.includes(refusal));
}

/// Whether an error, or anything that caused it, refuses the span.
///
/// Some providers give the reason only in the JSON-RPC error's `data`, under a generic
/// message: Tenderly answers "invalid params" and says in `data` that the query
/// returned more results than it serves. So the data of each error in the chain is
/// read along with its message.
export function isLogSpanRefusal(error: unknown): boolean {
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; current != null && depth < 10; depth++) {
    if (current instanceof Error) {
      parts.push(current.message);
      const data = (current as { data?: unknown }).data;
      if (typeof data === "string") parts.push(data);
      current = current.cause;
    } else {
      parts.push(
        typeof current === "string" ? current : JSON.stringify(current),
      );
      current = undefined;
    }
  }
  return isLogSpanRefusalMessage(parts.join("\n"));
}
