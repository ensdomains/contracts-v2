/// Retrying a log query that failed for a reason other than its span.
///
/// A provider that balances load across nodes fails some queries at random, more
/// often the wider the span, with errors that name no cap: drpc answers "Temporary
/// internal error. Please retry" or "request timed out" to a query the next node
/// serves. Such a query is asked again after a wait that grows with each failure in a
/// row, and a read gives up past a set number in a row, so an endpoint that is down or
/// throttling still surfaces.
///
/// Asking again never skips blocks: a read moves past a range only once a query for
/// it is served, so a partial result still cannot pass for a complete one. A span
/// refusal is answered apart, by asking for fewer blocks at once, as
/// `logSpanRefusal.ts` describes.

import { setTimeout as sleep } from "node:timers/promises";
import { BaseError } from "viem";

/// Failed queries in a row after which a read gives up.
export const FAILED_QUERY_LIMIT = 8;

/// The run of failed queries of one read.
export class QueryRetry {
  #failures = 0;
  readonly #delayMs: number;

  /// `delayMs` is the wait before the first retry; each failure in a row adds as
  /// much again.
  constructor(delayMs = 1_000) {
    this.#delayMs = delayMs;
  }

  /// Records a served query, which ends a run of failures.
  served(): void {
    this.#failures = 0;
  }

  /// Waits before a failed query is asked again, or rethrows its error when the run
  /// of failures has reached the limit.
  async failed(error: unknown): Promise<void> {
    if (this.#failures >= FAILED_QUERY_LIMIT) throw error;
    this.#failures++;
    await sleep(this.#delayMs * this.#failures);
  }
}

/// Reads until `read` returns a complete result, asking again as `retry` allows
/// while `incomplete` gives a reason it is not. Past the limit, throws that reason.
export async function readUntilComplete<T>(
  read: () => Promise<T>,
  incomplete: (value: T) => string | undefined,
  retry: QueryRetry = new QueryRetry(),
): Promise<T> {
  for (;;) {
    try {
      const value = await read();
      const reason = incomplete(value);
      if (reason === undefined) {
        retry.served();
        return value;
      }
      throw new Error(reason);
    } catch (error) {
      await retry.failed(error);
    }
  }
}

/// The multicall option that sends a batch as one call. Split into many small calls
/// sent at once, as viem does by default, a large batch bursts past a provider's
/// rate limit, which then fails parts of it.
export const ONE_CALL_PER_BATCH = { batchSize: 0 } as const;

/// An error's one-line summary. A viem error's full text repeats the request that
/// failed, and kept once per name across a large read it runs to gigabytes.
export function briefError(error: unknown): string {
  return error instanceof BaseError ? error.shortMessage : String(error);
}
