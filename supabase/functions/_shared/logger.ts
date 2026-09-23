/** Structured logging. One JSON object per line → Loki/BigQuery-friendly. */

import type { Env } from './env.ts';

type Level = 'debug' | 'info' | 'warn' | 'error';
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

let threshold = ORDER.info;
let baseFields: Record<string, unknown> = {};

export function configureLogger(env: Env, functionName: string): void {
  threshold = ORDER[env.logLevel] ?? ORDER.info;
  baseFields = { fn: functionName, env: env.environment };
}

const emit = (level: Level, message: string, fields: Record<string, unknown> = {}): void => {
  if (ORDER[level] < threshold) return;
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg: message,
    ...baseFields,
    ...fields,
  });
  // deno-lint-ignore no-console
  console[level === 'debug' ? 'log' : level](line);
};

export const log = {
  debug: (message: string, fields?: Record<string, unknown>) => emit('debug', message, fields),
  info: (message: string, fields?: Record<string, unknown>) => emit('info', message, fields),
  warn: (message: string, fields?: Record<string, unknown>) => emit('warn', message, fields),
  error: (message: string, fields?: Record<string, unknown>) => emit('error', message, fields),
};

/** Never log raw credentials: scrub anything that looks like a token/secret. */
const SENSITIVE = /(token|secret|password|code|authorization|cookie|apikey|api_key|refresh)/i;

export function redact<T>(value: T, depth = 0): T {
  if (depth > 6 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1)) as unknown as T;
  const out: Record<string, unknown> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    out[key] = SENSITIVE.test(key) && raw != null ? '«redacted»' : redact(raw, depth + 1);
  }
  return out as unknown as T;
}
