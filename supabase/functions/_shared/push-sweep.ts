/**
 * Sweep policy for `web-push-send` — the arithmetic, separated from the I/O so
 * it can be tested without a Deno runtime.
 *
 * Two numbers decide how a sweep behaves, and both exist to protect something
 * different:
 *
 *   • **limit** protects the database and our budget. A user's tab asking for a
 *     sweep must not be able to drain an arbitrarily large slice of the queue;
 *     the scheduled caller may take more because it is the one that runs when
 *     nobody is looking.
 *   • **wait_ms** protects *latency*, and it exists because of an ordering
 *     detail that is easy to get wrong: a notice is held for a 2 s quiet window
 *     so a burst folds into one notification, but the webhook that announces it
 *     fires at INSERT time — before the row is due. A sweep that arrives, finds
 *     nothing due and returns would leave every webhook-only deployment waiting
 *     for the next heartbeat. So the scheduled caller is allowed to hold the
 *     invocation briefly and claim again.
 *
 * The wait is never granted to a user's request: a person's tab should not be
 * held open to improve somebody else's delivery latency.
 */

/** A sweep may be held for at most this long; the fold window is 2 s. */
export const WAIT_MS_MAX = 5_000;

export type SweepPlan = {
  /** Rows to claim in one pass. */
  limit: number;
  /** Milliseconds to hold the invocation (and re-claim) if nothing was due. */
  waitMs: number;
};

const clampInt = (value: unknown, min: number, max: number, fallback: number): number => {
  const parsed = typeof value === 'number' ? value : Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(Math.max(Math.trunc(parsed), min), max);
};

/**
 * `maxLimit` is the caller's ceiling — a user's tab and the scheduled caller do
 * not get the same one — and `isScheduled` decides whether waiting is allowed at
 * all.
 */
export function resolveSweepPlan(
  body: unknown,
  options: { maxLimit: number; isScheduled: boolean },
): SweepPlan {
  const source = (body && typeof body === 'object' ? body : {}) as Record<string, unknown>;
  return {
    limit: clampInt(source.limit, 1, options.maxLimit, options.maxLimit),
    waitMs: options.isScheduled ? clampInt(source.wait_ms, 0, WAIT_MS_MAX, 0) : 0,
  };
}
