/** Retry / pacing helpers. Kept dependency-free and deterministic-testable. */

export const sleep = (ms: number, signal?: AbortSignal): Promise<void> =>
  new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new AbortError('aborted before sleep'));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = (): void => {
      clearTimeout(timer);
      reject(new AbortError('aborted during sleep'));
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });

export class AbortError extends Error {
  constructor(message = 'aborted') {
    super(message);
    this.name = 'AbortError';
  }
}

export const isAbort = (error: unknown): boolean =>
  error instanceof AbortError ||
  (error instanceof Error && (error.name === 'AbortError' || error.name === 'TimeoutError'));

export type BackoffOptions = {
  baseMs: number;
  maxMs: number;
  factor?: number;
  jitter?: number;
};

/**
 * Exponential backoff with full jitter (AWS "backoff with jitter" recipe), which
 * is what keeps 50 sessions retrying a Telegram outage from synchronising.
 */
export function backoffDelay(attempt: number, options: BackoffOptions, random: () => number = Math.random): number {
  const factor = options.factor ?? 2;
  const ceiling = Math.min(options.maxMs, options.baseMs * factor ** Math.max(0, attempt - 1));
  const jitter = options.jitter ?? 0.5;
  return Math.round(ceiling * (1 - jitter + jitter * random()));
}

export type RetryResult<T> = { ok: true; value: T; attempts: number } | { ok: false; error: Error; attempts: number };

/**
 * Bounded retry with a classifier, because "retry" is the wrong answer for most
 * TDLib errors: FLOOD_WAIT_* carries its own required delay, and
 * AUTH_FAILED / CONTACT_NOT_FOUND must surface immediately.
 */
export async function retry<T>(
  operation: (attempt: number) => Promise<T>,
  options: BackoffOptions & {
    attempts: number;
    signal?: AbortSignal;
    shouldRetry?: (error: unknown, attempt: number) => boolean | Promise<boolean>;
    onRetry?: (error: Error, attempt: number, delayMs: number) => void;
  },
): Promise<RetryResult<T>> {
  let lastError: Error = new Error('retry(): no attempts made');
  for (let attempt = 1; attempt <= options.attempts; attempt++) {
    try {
      return { ok: true, value: await operation(attempt), attempts: attempt };
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      const retryable = options.shouldRetry ? await options.shouldRetry(error, attempt) : true;
      if (!retryable || attempt === options.attempts || options.signal?.aborted) {
        return { ok: false, error: lastError, attempts: attempt };
      }
      const delay = backoffDelay(attempt, options);
      options.onRetry?.(lastError, attempt, delay);
      await sleep(delay, options.signal);
    }
  }
  return { ok: false, error: lastError, attempts: options.attempts };
}

/** Telegram's `FLOOD_WAIT_x` / `RETRY_AFTER_x` error payloads. */
export function floodWaitSeconds(message: string | undefined | null): number | null {
  if (!message) return null;
  const match = /(?:FLOOD_WAIT|RETRY_AFTER)_(\d{1,7})/i.exec(message);
  return match?.[1] ? Math.min(Number.parseInt(match[1], 10), 86_400) : null;
}

/**
 * Token bucket for per-session send pacing: Telegram rate-limits per account,
 * so the bucket lives with the session, not the process.
 */
export class TokenBucket {
  private tokens: number;
  private last: number;

  constructor(
    private readonly perMinute: number,
    private readonly now: () => number = () => Date.now(),
  ) {
    this.tokens = perMinute;
    this.last = now();
  }

  private refill(): void {
    const now = this.now();
    const elapsed = Math.max(0, now - this.last);
    this.last = now;
    this.tokens = Math.min(this.perMinute, this.tokens + (elapsed / 60_000) * this.perMinute);
  }

  tryTake(count = 1): boolean {
    this.refill();
    if (this.tokens >= count) {
      this.tokens -= count;
      return true;
    }
    return false;
  }

  /** Milliseconds until `count` tokens are available (0 when it is now). */
  msUntilAvailable(count = 1): number {
    this.refill();
    if (this.tokens >= count) return 0;
    return Math.ceil(((count - this.tokens) / this.perMinute) * 60_000);
  }
}

/**
 * Serialises async work per key. Chats must be sent to in order (Telegram
 * assigns ids by arrival), but different chats are independent, so the unit of
 * serialization is the chat, not the worker.
 */
export class KeyedQueue<T = void> {
  #tails = new Map<string, Promise<void>>();

  enqueue(key: string, task: () => Promise<T>): Promise<T> {
    const tail = this.#tails.get(key) ?? Promise.resolve();
    const run = tail.then(task, task);
    const settled: Promise<void> = run.then(
      () => undefined,
      () => undefined,
    );
    this.#tails.set(key, settled);
    settled.then(() => {
      if (this.#tails.get(key) === settled) this.#tails.delete(key);
    });
    return run;
  }

  get pending(): number {
    return this.#tails.size;
  }
}
