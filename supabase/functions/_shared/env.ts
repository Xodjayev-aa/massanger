/**
 * Typed, fail-fast configuration for the MessengerX edge functions.
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

  /** Bridge ⇄ edge trust */
  bridgeHmacSecret: string | null;
  bridgeToken: string | null;
  bridgeBaseUrl: string | null;
  /** AES-256-GCM key shared with the bridge: seals Telegram login codes. */
  sealKey: string | null;

  /** Misc */
  allowedOrigins: string[];
  maxBodyBytes: number;
  ingestMaxEvents: number;
  clockSkewSeconds: number;
  logLevel: 'debug' | 'info' | 'warn' | 'error';
  environment: 'development' | 'local' | 'staging' | 'production';
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
  // An accidental MESSENGERX_ENV=prod must not disable hosted safety checks.
  const selected = str('MESSENGERX_ENV', 'production');
  if (selected !== 'production' && selected !== 'staging' && selected !== 'local' && selected !== 'development') {
    throw new HttpError('misconfigured', 'MESSENGERX_ENV must be production, staging, local or development');
  }
  const environment: Env['environment'] = selected;
  const env: Env = {
    supabaseUrl: (str('SUPABASE_URL') ?? 'http://host.docker.internal:54321').replace(/\/+$/, ''),
    serviceRoleKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    anonKey: required('SUPABASE_ANON_KEY'),
    jwtSecret: str('SUPABASE_JWT_SECRET'),

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
  if (environment === 'production' || environment === 'staging') {
    if (!env.supabaseUrl.startsWith('https://')) {
      throw new HttpError('misconfigured', `${environment} SUPABASE_URL must use HTTPS`);
    }
    if (!sealingAvailable(env) || !env.bridgeToken || env.bridgeToken.length < 32 ||
        !env.bridgeHmacSecret || env.bridgeHmacSecret.length < 32) {
      throw new HttpError('misconfigured', `${environment} requires SEAL_KEY, BRIDGE_TOKEN and BRIDGE_HMAC_SECRET (independent random secrets of at least 32 characters)`);
    }
    if (env.allowedOrigins.length === 0 || env.allowedOrigins.some((raw) => {
      try {
        const url = new URL(raw);
        return url.protocol !== 'https:' || url.origin !== raw;
      } catch {
        return true;
      }
    })) {
      throw new HttpError('misconfigured', `${environment} ALLOWED_ORIGINS must list exact HTTPS origins, never *`);
    }
  }
  return env;
}

/** True when the deployment is configured for end-to-end sealed payloads. */
export function sealingAvailable(env: Env): boolean {
  return env.sealKey !== null && env.sealKey.length >= 32;
}
