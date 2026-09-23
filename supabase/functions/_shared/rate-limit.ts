/**
 * Per-isolate sliding-window limiter.
 *
 * Edge runtimes are short-lived and horizontally scaled, so this is a
 * first-price-fight-back rather than a quota system: it stops a single device
 * (or a single leaked token) from hammering the age-gate and the ingest webhook
 * for free. Anything that must be exact lives in Postgres instead (e.g.
 * `profiles.eligibility_attempts`, which the gate also decrements).
 */

import { HttpError } from './types.ts';

type Bucket = { hits: number[] };

const buckets = new Map<string, Bucket>();
let lastSweep = Date.now();

const SWEEP_EVERY_MS = 30_000;
const WINDOW_MS = 60_000;

function sweep(now: number, windowMs: number): void {
  if (now - lastSweep < SWEEP_EVERY_MS) return;
  lastSweep = now;
  const cutoff = now - windowMs;
  for (const [key, bucket] of buckets) {
    bucket.hits = bucket.hits.filter((ts) => ts > cutoff);
    if (bucket.hits.length === 0) buckets.delete(key);
  }
}

export type LimitResult = { allowed: true } | { allowed: false; retryAfterSeconds: number };

export function consume(
  scope: string,
  key: string,
  limit: number,
  windowMs: number = WINDOW_MS,
): LimitResult {
  const now = Date.now();
  const bucketKey = `${scope}:${key}`;
  sweep(now, windowMs);

  const bucket = buckets.get(bucketKey) ?? { hits: [] };
  bucket.hits = bucket.hits.filter((ts) => ts > now - windowMs);
  if (bucket.hits.length >= limit) {
    buckets.set(bucketKey, bucket);
    const oldest = bucket.hits[0] ?? now;
    const retryAfterSeconds = Math.max(1, Math.ceil((oldest + windowMs - now) / 1000));
    return { allowed: false, retryAfterSeconds };
  }
  bucket.hits.push(now);
  buckets.set(bucketKey, bucket);
  return { allowed: true };
}

/** Throws a 429 envelope when the caller is over budget. */
export function enforce(scope: string, key: string, limit: number, windowMs?: number): void {
  const result = consume(scope, key, limit, windowMs);
  if (!result.allowed) {
    throw new HttpError('rate_limited', 'too many requests', {
      retryAfterSeconds: result.retryAfterSeconds,
    });
  }
}
