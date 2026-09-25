/**
 * Runtime configuration. Everything is environment-driven and validated once at
 * boot (fail fast, never mid-flight). `loadConfig()` is exported pure so the
 * test-suite can assert defaults without touching `process.env`.
 */

import { z } from 'zod';
import os from 'node:os';
import path from 'node:path';

const booleanish = z
  .union([z.boolean(), z.string()])
  .transform((value) => (typeof value === 'boolean' ? value : /^(1|true|yes|on)$/i.test(value.trim())));

const positiveInt = (fallback: number, max?: number) =>
  z.coerce
    .number()
    .int()
    .positive()
    .max(max ?? Number.MAX_SAFE_INTEGER)
    .catch(fallback)
    .default(fallback);

const durationSeconds = (fallback: number) =>
  z.coerce.number().min(1).max(86_400).catch(fallback).default(fallback);

const schema = z.object({
  // ── Supabase ────────────────────────────────────────────────────────────
  supabaseUrl: z.string().url().transform((url) => url.replace(/\/+$/, '')),
  serviceRoleKey: z.string().min(20),
  anonKey: z.string().min(20).optional(),

  /**
   * 'function' (default) pushes every inbound batch through the signed
   * `telegram-ingest` edge function — the documented production path, because
   * it centralises auth, rate limiting and idempotency.
   * 'rpc' calls Postgres directly, which is handy on a local `supabase start`
   * where the function bundle is not deployed.
   */
  ingestMode: z.enum(['function', 'rpc']).catch('function').default('function'),
  ingestFunctionUrl: z.string().url().optional(),
  ingestTimeoutMs: positiveInt(7_500),
  /** Maximum events per webhook call; must be <= the function's INGEST_MAX_EVENTS. */
  ingestBatchSize: positiveInt(60, 200),
  /** How long an event may wait in the queue before it is force-flushed. */
  ingestFlushMs: positiveInt(250),

  bridgeToken: z.string().min(16).optional(),
  bridgeHmacSecret: z.string().min(16).optional(),
  clockSkewSeconds: durationSeconds(60),

  /** Shared with the edge functions: unwraps sealed Telegram login codes. */
  sealKey: z.string().min(16).optional(),

  // ── TDLib ───────────────────────────────────────────────────────────────
  transport: z.enum(['koffi', 'websocket', 'memory']).catch('koffi').default('koffi'),
  tdlibLibraryPath: z.string().default('libtdjson.so'),
  websocketUrl: z.string().url().optional(),
  dataDir: z.string().default(os.tmpdir() + '/messengerx-bridge'),
  // Required for a real Telegram connection; `loadConfig` substitutes harmless
  // dummies in memory (simulator) mode so `npm run bridge` works before an
  // api_id exists — a production boot still cannot forget them.
  apiId: z.coerce.number().int().positive(),
  apiHash: z
    .string()
    .regex(/^[0-9a-f]{32}$/i, 'TELEGRAM_API_HASH must be the 32 hex characters from my.telegram.org'),
  useTestDc: booleanish.default(false),
  useSecretChats: booleanish.default(false),
  applicationVersion: z.string().default('1.0.0'),
  deviceModel: z.string().default('MessengerX Bridge'),
  systemLanguageCode: z.string().default('en'),
  /**
   * Optional base64 of 32 random bytes. When set, TDLib encrypts its session
   * database at rest — the disk then holds neither the Telegram auth key nor
   * plaintext message history, which matters because the bridge host also stores
   * nothing else about the user.
   */
  databaseEncryptionKey: z.string()
    .refine((value) => {
      const bytes = Buffer.from(value, 'base64');
      return bytes.length === 32 && bytes.toString('base64') === value;
    }, 'TDLIB_DB_KEY must be base64 encoding of exactly 32 random bytes')
    .optional().transform((value) => value ?? undefined),
  tdVerbosity: z.coerce.number().min(0).max(10).catch(1).default(1),
  requestTimeoutMs: positiveInt(45_000),

  // ── Pool / scheduling ───────────────────────────────────────────────────
  workerId: z.string().default(`${os.hostname()}:${process.pid}`),
  maxSessions: positiveInt(64, 4096),
  /** Poll fallback for the queues; Realtime normally wins. */
  pollIntervalMs: positiveInt(3_000),
  outboxBatchSize: positiveInt(10, 200),
  /** Leases handed to Postgres; must exceed the worst-case send time. */
  outboxLeaseSeconds: durationSeconds(180),
  linkPollIntervalMs: positiveInt(1_000),
  heartbeatSeconds: durationSeconds(20),
  /** Retire an idle session after this long (it restarts lazily). */
  sessionIdleSeconds: durationSeconds(600),
  /** Per-user send spacing: Telegram is unforgiving about bursts. */
  minSendIntervalMs: positiveInt(120),
  maxSendPerMinute: positiveInt(20, 1000),

  // ── Media ──────────────────────────────────────────────────────────────
  mediaTempDir: z.string().optional(),
  maxMediaBytes: positiveInt(25 * 1024 * 1024),
  maxVoiceSeconds: positiveInt(300),
  downloadPriorities: z
    .object({
      voice: z.coerce.number().int().min(0).max(32).catch(1).default(1),
      photo: z.coerce.number().int().min(0).max(32).catch(1).default(1),
      other: z.coerce.number().int().min(0).max(32).catch(3).default(3),
    })
    .optional()
    .transform((value) => value ?? { voice: 1, photo: 1, other: 3 }),

  // ── Ops ────────────────────────────────────────────────────────────────
  /** 0 means "any free port", which is what the test-suite and local runs use. */
  healthPort: z.coerce.number().int().min(0).max(65_535).catch(8787).default(8787),
  healthHost: z.string().default('0.0.0.0'),
  /** Comma-separated origins allowed on /internal/wake (browsers only; the
   * caller there is a Supabase edge function, so this is defence in depth). */
  allowedOrigins: z
    .string()
    .optional()
    .transform((value) =>
      value
        ? value
            .split(',')
            .map((entry) => entry.trim())
            .filter((entry) => entry.length > 0)
        : undefined,
    ),
  // Never turn a typo (or missing label) into an insecure development worker.
  messengerxEnv: z.enum(['development', 'staging', 'production']).default('production'),
  logLevel: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).catch('info').default('info'),
  gracefulShutdownMs: positiveInt(15_000),
});

type Resolved = z.infer<typeof schema> & {
  /** Where batches are pushed: the signed edge function, or the RPC directly. */
  ingestEndpoint: string;
  mediaTempDir: string;
};

export type BridgeConfig = Resolved;

export class ConfigError extends Error {
  readonly issues: string[];

  constructor(issues: string[]) {
    super(`invalid bridge configuration:\n  - ${issues.join('\n  - ')}`);
    this.name = 'ConfigError';
    this.issues = issues;
  }
}

export function loadConfig(source: NodeJS.ProcessEnv = process.env): BridgeConfig {
  const simulated = (source.BRIDGE_TRANSPORT ?? 'koffi') === 'memory';

  const apiHashCandidate = (source.TELEGRAM_API_HASH ?? '').trim();
  const apiIdCandidate = Number.parseInt(source.TELEGRAM_API_ID ?? '', 10);

  const parsed = schema.safeParse({
    supabaseUrl: source.SUPABASE_URL,
    serviceRoleKey: source.SUPABASE_SERVICE_ROLE_KEY ?? source.SUPABASE_SERVICE_KEY,
    anonKey: source.SUPABASE_ANON_KEY,
    ingestMode: source.INGEST_MODE,
    ingestTimeoutMs: source.INGEST_TIMEOUT_MS,
    ingestBatchSize: source.INGEST_BATCH_SIZE,
    ingestFlushMs: source.INGEST_FLUSH_MS,
    bridgeToken: source.BRIDGE_TOKEN,
    bridgeHmacSecret: source.BRIDGE_HMAC_SECRET,
    clockSkewSeconds: source.CLOCK_SKEW_SECONDS,
    sealKey: source.SEAL_KEY ?? source.LINK_PAYLOAD_KEY,
    transport: source.BRIDGE_TRANSPORT,
    tdlibLibraryPath: source.TDLIB_LIBRARY_PATH,
    websocketUrl: source.TD_WS_URL,
    dataDir: source.BRIDGE_DATA_DIR,
    apiId:
      Number.isSafeInteger(apiIdCandidate) && apiIdCandidate > 0
        ? String(apiIdCandidate)
        : simulated
          ? '1'
          : (source.TELEGRAM_API_ID ?? ''),
    apiHash: /^[0-9a-f]{32}$/i.test(apiHashCandidate)
      ? apiHashCandidate
      : simulated
        ? '0'.repeat(32)
        : apiHashCandidate,
    useTestDc: source.TELEGRAM_TEST_DC,
    useSecretChats: source.TELEGRAM_SECRET_CHATS,
    applicationVersion: source.MESSENGERX_VERSION,
    deviceModel: source.TELEGRAM_DEVICE_MODEL,
    systemLanguageCode: source.TELEGRAM_LANGUAGE_CODE,
    databaseEncryptionKey: source.TDLIB_DB_KEY,
    tdVerbosity: source.TD_VERBOSITY,
    requestTimeoutMs: source.TD_REQUEST_TIMEOUT_MS,
    workerId: source.BRIDGE_WORKER_ID,
    maxSessions: source.BRIDGE_MAX_SESSIONS,
    pollIntervalMs: source.BRIDGE_POLL_INTERVAL_MS,
    outboxBatchSize: source.BRIDGE_OUTBOX_BATCH_SIZE,
    outboxLeaseSeconds: source.BRIDGE_OUTBOX_LEASE_SECONDS,
    linkPollIntervalMs: source.BRIDGE_LINK_POLL_MS,
    heartbeatSeconds: source.BRIDGE_HEARTBEAT_SECONDS,
    sessionIdleSeconds: source.BRIDGE_SESSION_IDLE_SECONDS,
    minSendIntervalMs: source.BRIDGE_MIN_SEND_INTERVAL_MS,
    maxSendPerMinute: source.BRIDGE_MAX_SEND_PER_MINUTE,
    maxMediaBytes: source.BRIDGE_MAX_MEDIA_BYTES,
    maxVoiceSeconds: source.BRIDGE_MAX_VOICE_SECONDS,
    healthPort: source.BRIDGE_HEALTH_PORT,
    healthHost: source.BRIDGE_HEALTH_HOST,
    logLevel: source.LOG_LEVEL,
    allowedOrigins: source.ALLOWED_ORIGINS,
    messengerxEnv: source.MESSENGERX_ENV,
    gracefulShutdownMs: source.BRIDGE_GRACEFUL_SHUTDOWN_MS,
  });

  if (!parsed.success) {
    throw new ConfigError(
      parsed.error.issues.map((issue) => `${issue.path.join('.') || '(root)'}: ${issue.message}`),
    );
  }
  if (source.TELEGRAM_EXPORT_LOGIN_TOKEN === 'true') {
    throw new ConfigError(['TELEGRAM_EXPORT_LOGIN_TOKEN: TDLib has no JSON login-token export for worker failover; keep BRIDGE_DATA_DIR persistent instead']);
  }

  const value = parsed.data as z.infer<typeof schema> & {
    ingestFunctionUrl?: string;
    mediaTempDir?: string;
  };
  if (value.messengerxEnv === 'production' || value.messengerxEnv === 'staging') {
    const issues: string[] = [];
    if (!value.supabaseUrl.startsWith('https://')) issues.push('SUPABASE_URL: hosted workers require HTTPS');
    if (!value.bridgeToken || value.bridgeToken.length < 32 || !value.bridgeHmacSecret || value.bridgeHmacSecret.length < 32) {
      issues.push('BRIDGE_TOKEN and BRIDGE_HMAC_SECRET: hosted workers need independent random values of at least 32 characters');
    }
    if (!value.sealKey || value.sealKey.length < 32) issues.push('SEAL_KEY: hosted workers need the same 32-byte key as the functions');
    if (!value.databaseEncryptionKey) issues.push('TDLIB_DB_KEY: hosted workers need an encrypted, restorable session database');
    if (!source.BRIDGE_DATA_DIR || !path.isAbsolute(value.dataDir) ||
        path.resolve(value.dataDir) === os.tmpdir() || path.resolve(value.dataDir).startsWith(`${os.tmpdir()}/`)) {
      issues.push('BRIDGE_DATA_DIR: set a persistent absolute path outside the system temp directory');
    }
    if (value.transport === 'memory') issues.push('BRIDGE_TRANSPORT: hosted workers cannot use the memory simulator');
    if (value.ingestMode !== 'function') issues.push('INGEST_MODE: hosted workers must use signed telegram-ingest');
    if (issues.length > 0) throw new ConfigError(issues);
  }
  return {
    ...value,
    ingestEndpoint:
      value.ingestFunctionUrl ??
      (value.ingestMode === 'rpc'
        ? `${value.supabaseUrl}/rest/v1/rpc/bridge_ingest_message`
        : `${value.supabaseUrl}/functions/v1/telegram-ingest`),
    mediaTempDir: value.mediaTempDir ?? `${value.dataDir}/media`,
  } as BridgeConfig;
}
