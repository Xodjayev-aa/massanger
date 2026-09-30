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

  /**
   * Video object storage: Backblaze B2 through its S3-compatible API.
   * Optional in the same all-or-nothing sense as Web Push — without these five
   * values `video-ticket` reports `configured: false` and the app hides the
   * video affordances instead of offering an upload that cannot land. Never
   * Supabase Storage: the free tier's egress and file caps make a video there
   * a suspension waiting to happen.
   */
  videoS3Endpoint: string | null;
  videoS3Region: string | null;
  videoS3AccessKeyId: string | null;
  videoS3SecretAccessKey: string | null;
  videoBucket: string | null;

  /**
   * Stripe: the paid half of the star economy. `tag.custom` is priced at $2.49
   * in `star_products`, and this is the only way real money enters the system.
   * Optional in the same all-or-nothing sense as Web Push — without it
   * `stripe-checkout` reports `configured: false` and the app hides the top-up
   * button rather than offering a checkout that cannot complete.
   */
  stripeSecretKey: string | null;
  stripeWebhookSecret: string | null;
  /** Origins a checkout may return to; must be a subset of allowedOrigins. */
  stripeReturnOrigins: string[];

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
  const allowedOrigins = list('ALLOWED_ORIGINS', ['*']);
  // An unset return-origin allowlist means "the same origins that may call us
  // at all" — derived, so those entries are validated by the ALLOWED_ORIGINS
  // rule instead, which gives the operator the message they can act on.
  const declaredReturnOrigins = str('STRIPE_RETURN_ORIGINS');
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

    videoS3Endpoint: str('VIDEO_S3_ENDPOINT'),
    videoS3Region: str('VIDEO_S3_REGION'),
    videoS3AccessKeyId: str('VIDEO_S3_ACCESS_KEY_ID'),
    videoS3SecretAccessKey: str('VIDEO_S3_SECRET_ACCESS_KEY'),
    videoBucket: str('VIDEO_BUCKET'),

    stripeSecretKey: str('STRIPE_SECRET_KEY'),
    stripeWebhookSecret: str('STRIPE_WEBHOOK_SECRET'),
    stripeReturnOrigins: list('STRIPE_RETURN_ORIGINS', allowedOrigins.filter((origin) => origin !== '*')),

    allowedOrigins,
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

  // Video storage follows the same rule as VAPID: five values, all or none.
  // Validated in every environment so a local stack cannot pass a configuration
  // that production would reject.
  const videoParts = [
    env.videoS3Endpoint,
    env.videoS3Region,
    env.videoS3AccessKeyId,
    env.videoS3SecretAccessKey,
    env.videoBucket,
  ];
  const videoSet = videoParts.filter((part) => part !== null).length;
  if (videoSet !== 0 && videoSet !== videoParts.length) {
    throw new HttpError(
      'misconfigured',
      'VIDEO_S3_ENDPOINT, VIDEO_S3_REGION, VIDEO_S3_ACCESS_KEY_ID, VIDEO_S3_SECRET_ACCESS_KEY and VIDEO_BUCKET must be set together',
    );
  }
  if (env.videoS3Endpoint !== null) {
    let endpointOk = false;
    try {
      const url = new URL(env.videoS3Endpoint);
      endpointOk = url.protocol === 'https:' && url.pathname === '/' && !url.search && !url.hash;
    } catch {
      endpointOk = false;
    }
    if (!endpointOk) {
      throw new HttpError('misconfigured', 'VIDEO_S3_ENDPOINT must be an https origin without a path, query or fragment');
    }
  }
  if (env.videoS3Region !== null && !/^[a-z0-9-]{1,64}$/.test(env.videoS3Region)) {
    throw new HttpError('misconfigured', 'VIDEO_S3_REGION must be a region slug like us-west-000');
  }
  if (env.videoBucket !== null && !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(env.videoBucket)) {
    throw new HttpError('misconfigured', 'VIDEO_BUCKET must be a valid bucket name');
  }

  // Stripe: two values, all or none, and the key must look like a Stripe key.
  // A live key in the wrong environment is a real-money mistake, so it is worth
  // refusing to boot over.
  const stripeSet = [env.stripeSecretKey, env.stripeWebhookSecret].filter((part) => part !== null).length;
  if (stripeSet !== 0 && stripeSet !== 2) {
    throw new HttpError('misconfigured', 'STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET must be set together');
  }
  if (env.stripeSecretKey !== null) {
    const prefix = env.environment === 'production' ? 'sk_live_' : 'sk_test_';
    if (!env.stripeSecretKey.startsWith(prefix)) {
      throw new HttpError('misconfigured', `${env.environment} requires a ${prefix} Stripe key`);
    }
    if (!env.stripeWebhookSecret?.startsWith('whsec_')) {
      throw new HttpError('misconfigured', 'STRIPE_WEBHOOK_SECRET must start with whsec_');
    }
  }
  // Where a checkout may send the browser back to. An origin nobody vouched for
  // turns a payment page into an open redirect, so this defaults to the already
  // validated ALLOWED_ORIGINS and can never exceed it.
  for (const origin of declaredReturnOrigins === null ? [] : env.stripeReturnOrigins) {
    if (!/^https:\/\/[a-z0-9.-]+(?::\d+)?$/i.test(origin)) {
      throw new HttpError('misconfigured', `STRIPE_RETURN_ORIGINS entry "${origin}" must be an https origin`);
    }
    if (environment !== 'development' && environment !== 'local' &&
        !env.allowedOrigins.includes(origin) && !env.allowedOrigins.includes('*')) {
      throw new HttpError('misconfigured', `STRIPE_RETURN_ORIGINS entry "${origin}" is not in ALLOWED_ORIGINS`);
    }
  }
  if (env.videoS3AccessKeyId !== null && env.videoS3AccessKeyId.length < 16) {
    throw new HttpError('misconfigured', 'VIDEO_S3_ACCESS_KEY_ID looks too short to be a real key id');
  }
  if (env.videoS3SecretAccessKey !== null && env.videoS3SecretAccessKey.length < 16) {
    throw new HttpError('misconfigured', 'VIDEO_S3_SECRET_ACCESS_KEY looks too short to be a real secret');
  }

  if ((environment === 'production' || environment === 'staging') && env.allowedOrigins.length === 0) {
    throw new HttpError('misconfigured', `${environment} ALLOWED_ORIGINS must list exact HTTPS origins, never *`);
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
