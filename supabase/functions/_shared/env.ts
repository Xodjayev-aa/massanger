/**
 * Typed, fail-fast configuration for the Massanger edge functions.
 *
 * Every secret is read from the runtime environment (`supabase secrets set`),
 * never from a file, and never echoed back into a response or a log line.
 */

import { HttpError } from './types.ts';

export type Env = Readonly<{
  supabaseUrl: string;
  serviceRoleKey: string;
  anonKey: string;
  jwtSecret: string | null;

  /** Age gate */
  googleClientId: string | null;
  googleClientIds: string[];
  googleClientSecret: string | null;
  minAccountAgeDays: number;
  maxEligibilityAttempts: number;
  eligibilityCacheDays: number;
  blockTooYoung: 'restrict' | 'delete';

  /** Bridge ⇄ edge trust */
  bridgeHmacSecret: string | null;
  bridgeToken: string | null;
  bridgeBaseUrl: string | null;
  /** AES-256-GCM key shared with the bridge: seals Telegram login codes and
   *  wraps stored Google refresh tokens at rest. */
  sealKey: string | null;

  /** Misc */
  allowedOrigins: string[];
  maxBodyBytes: number;
  ingestMaxEvents: number;
  clockSkewSeconds: number;
  logLevel: 'debug' | 'info' | 'warn' | 'error';
  environment: 'local' | 'staging' | 'production';
}>;

const str = (name: string, fallback?: string): string | null => {
  const raw = Deno.env.get(name);
  if (raw === undefined || raw === '') return fallback ?? null;
  return raw;
};

const required = (name: string): string => {
  const value = str(name);
  if (value === null) {
    throw new HttpError('misconfigured', `missing required secret ${name}`, { status: 500 });
  }
  return value;
};

const int = (name: string, fallback: number): number => {
  const raw = str(name);
  if (raw === null) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

const list = (name: string, fallback: string[] = []): string[] => {
  const raw = str(name);
  if (raw === null) return fallback;
  return raw.split(',').map((part) => part.trim()).filter((part) => part.length > 0);
};

export function readEnv(): Env {
  const environment = (str('MASSANGER_ENV', 'production') ?? 'production') as Env['environment'];
  const primary = str('GOOGLE_CLIENT_ID');
  return {
    supabaseUrl: (str('SUPABASE_URL') ?? 'http://host.docker.internal:54321').replace(/\/+$/, ''),
    serviceRoleKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    anonKey: required('SUPABASE_ANON_KEY'),
    jwtSecret: str('SUPABASE_JWT_SECRET'),

    googleClientId: primary,
    googleClientIds: [
      ...primary ? [primary] : [],
      ...list('GOOGLE_CLIENT_IDS'),
      ...str('GOOGLE_IOS_CLIENT_ID') ? [str('GOOGLE_IOS_CLIENT_ID')!] : [],
      ...str('GOOGLE_ANDROID_CLIENT_ID') ? [str('GOOGLE_ANDROID_CLIENT_ID')!] : [],
      ...str('GOOGLE_WEB_CLIENT_ID') ? [str('GOOGLE_WEB_CLIENT_ID')!] : [],
    ],
    googleClientSecret: str('GOOGLE_CLIENT_SECRET'),
    minAccountAgeDays: int('MIN_ACCOUNT_AGE_DAYS', 366),
    maxEligibilityAttempts: int('MAX_ELIGIBILITY_ATTEMPTS', 5),
    eligibilityCacheDays: int('ELIGIBILITY_CACHE_DAYS', 30),
    blockTooYoung: (str('AGE_GATE_ON_FAILURE', 'restrict') ?? 'restrict') as 'restrict' | 'delete',

    bridgeHmacSecret: str('BRIDGE_HMAC_SECRET'),
    bridgeToken: str('BRIDGE_TOKEN'),
    bridgeBaseUrl: str('BRIDGE_BASE_URL'),
    sealKey: str('SEAL_KEY') ?? str('LINK_PAYLOAD_KEY'),

    allowedOrigins: list('ALLOWED_ORIGINS', ['*']),
    maxBodyBytes: int('MAX_BODY_BYTES', 1_500_000),
    ingestMaxEvents: int('INGEST_MAX_EVENTS', 120),
    clockSkewSeconds: int('CLOCK_SKEW_SECONDS', 60),
    logLevel: (str('LOG_LEVEL', 'info') ?? 'info') as Env['logLevel'],
    environment,
  };
}

/** True when the deployment is configured for end-to-end sealed payloads. */
export function sealingAvailable(env: Env): boolean {
  return env.sealKey !== null && env.sealKey.length >= 32;
}
