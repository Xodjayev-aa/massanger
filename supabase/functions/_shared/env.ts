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

  /**
   * Web Push (RFC 8291/8292), the $0 path to a real OS notification. Optional:
   * a deployment that has not generated VAPID keys simply reports the feature as
   * unconfigured and the app hides the switch. It is all-or-nothing, though —
   * half a VAPID identity is a misconfiguration, not a partial feature.
   */
  webPushVapidPublicKey: string | null;
  webPushVapidPrivateKey: string | null;
  /** Contact URI (mailto: or https:) the push services page you at. Required. */
  webPushVapidSubject: string | null;
  /** Bearer token for the scheduled/webhook sweep; no user session involved. */
  webPushSweepToken: string | null;
  /** Extra push-service hosts beyond the built-in allowlist (`*.example.com`). */
  webPushEndpointHosts: string[];

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

    webPushVapidPublicKey: str('WEB_PUSH_VAPID_PUBLIC_KEY'),
    webPushVapidPrivateKey: str('WEB_PUSH_VAPID_PRIVATE_KEY'),
    webPushVapidSubject: str('WEB_PUSH_VAPID_SUBJECT'),
    webPushSweepToken: str('WEB_PUSH_SWEEP_TOKEN'),
    webPushEndpointHosts: list('WEB_PUSH_ENDPOINT_HOSTS'),

    allowedOrigins: list('ALLOWED_ORIGINS', ['*']),
    maxBodyBytes: int('MAX_BODY_BYTES', 1_500_000),
    ingestMaxEvents: int('INGEST_MAX_EVENTS', 120),
    clockSkewSeconds: int('CLOCK_SKEW_SECONDS', 60),
    logLevel: (str('LOG_LEVEL', 'info') ?? 'info') as Env['logLevel'],
    environment,
  };
  // Web Push is optional, but never half-configured: a public key without its
  // private half would sign nothing and report success until the first message,
  // and a subject is required by every push service (they use it to contact the
  // operator of a misbehaving sender). Validated in every environment so a local
  // stack cannot pass a configuration that production would reject.
  const vapidParts = [env.webPushVapidPublicKey, env.webPushVapidPrivateKey, env.webPushVapidSubject];
  const vapidSet = vapidParts.filter((part) => part !== null).length;
  if (vapidSet !== 0 && vapidSet !== vapidParts.length) {
    throw new HttpError(
      'misconfigured',
      'WEB_PUSH_VAPID_PUBLIC_KEY, WEB_PUSH_VAPID_PRIVATE_KEY and WEB_PUSH_VAPID_SUBJECT must be set together',
    );
  }
  if (env.webPushVapidSubject !== null && !/^(mailto:|https:)/.test(env.webPushVapidSubject)) {
    throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_SUBJECT must be a mailto: or https: URI');
  }
  if (env.webPushVapidPublicKey !== null && !/^[A-Za-z0-9_-]{80,120}$/.test(env.webPushVapidPublicKey)) {
    throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PUBLIC_KEY must be a base64url-encoded public key');
  }
  if (env.webPushVapidPrivateKey !== null &&
      !/^[A-Za-z0-9_-]{40,64}$/.test(env.webPushVapidPrivateKey) &&
      !env.webPushVapidPrivateKey.trimStart().startsWith('{')) {
    throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PRIVATE_KEY must be base64url or a JWK');
  }
  if (env.webPushSweepToken !== null && env.webPushSweepToken.length < 32) {
    throw new HttpError('misconfigured', 'WEB_PUSH_SWEEP_TOKEN must be at least 32 characters');
  }
  if (env.webPushEndpointHosts.some((host) => !/^(\*\.)?[a-z0-9.-]+$/i.test(host))) {
    throw new HttpError('misconfigured', 'WEB_PUSH_ENDPOINT_HOSTS must be hostnames, optionally *.prefixed');
  }

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
