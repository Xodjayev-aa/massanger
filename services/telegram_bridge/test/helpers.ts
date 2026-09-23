/**
 * Shared test scaffolding: a deterministic environment, a recording `fetch`, and
 * fixtures shaped exactly like the bridge RPCs (see 00007 / 00010).
 */

import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { loadConfig, type BridgeConfig } from '../src/config.js';
import type { AccountContext, LinkClaim, OutboxRow } from '../src/supabase.js';

export const HEX_KEY = '0f'.repeat(32);

export function testEnv(overrides: Record<string, string | undefined> = {}): NodeJS.ProcessEnv {
  const dir = mkdtempSync(path.join(tmpdir(), 'massanger-bridge-'));
  const env: Record<string, string> = {
    SUPABASE_URL: 'https://project.example.supabase.co',
    // Both must clear the min(20) length rule the real loader enforces.
    SUPABASE_SERVICE_ROLE_KEY: 'service-role-key-for-tests-only',
    SUPABASE_ANON_KEY: 'anon-key-for-tests-only-ok',
    MASSANGER_ENV: 'development',
    BRIDGE_TRANSPORT: 'memory',
    BRIDGE_DATA_DIR: dir,
    BRIDGE_HEALTH_PORT: '0',
    BRIDGE_TOKEN: 'shared-bridge-token',
    BRIDGE_HMAC_SECRET: 'hmac-secret-value-that-is-long-enough',
    SEAL_KEY: HEX_KEY,
    TELEGRAM_API_ID: '2941271',
    TELEGRAM_API_HASH: '0123456789abcdef0123456789abcdef',
    INGEST_MODE: 'function',
    LOG_LEVEL: 'silent',
    BRIDGE_POLL_INTERVAL_MS: '25',
    BRIDGE_HEARTBEAT_SECONDS: '3600',
    BRIDGE_SESSION_IDLE_SECONDS: '3600',
    BRIDGE_MIN_SEND_INTERVAL_MS: '0',
    BRIDGE_GRACEFUL_SHUTDOWN_MS: '1000',
  };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  return env as NodeJS.ProcessEnv;
}

export function testConfig(overrides: Record<string, string | undefined> = {}): BridgeConfig {
  return loadConfig(testEnv(overrides));
}

export type RecordedCall = {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
  /** Parsed JSON body when the request was JSON. */
  json: () => any;
};

export type Recorder = {
  calls: RecordedCall[];
  fetchImpl: typeof fetch;
  /** The most recent call whose URL contains `needle`, or undefined. */
  find: (needle: string) => RecordedCall | undefined;
  /** Queue a response for the next call matching `needle`. */
  reply: (needle: string, payload: unknown, status?: number) => void;
};

export function recorder(handler?: (call: RecordedCall) => Response | Promise<Response>): Recorder {
  const calls: RecordedCall[] = [];
  const queue = new Map<string, { payload: unknown; status: number }[]>();

  const api: Recorder = {
    calls,
    find: (needle) => [...calls].reverse().find((call) => call.url.includes(needle)),
    reply: (needle, payload, status = 200) => {
      const list = queue.get(needle) ?? [];
      list.push({ payload, status });
      queue.set(needle, list);
    },
    fetchImpl: async (input: any, init: any = {}) => {
      const url = String(typeof input === 'string' ? input : (input as Request).url);
      const raw = typeof init.body === 'string' ? init.body : '';
      const headers: Record<string, string> = {};
      const source = (init.headers ?? {}) as Record<string, string>;
      for (const [key, value] of Object.entries(source)) headers[key.toLowerCase()] = String(value);

      const call: RecordedCall = {
        url,
        method: String(init.method ?? 'GET'),
        headers,
        body: raw,
        json: () => (raw === '' ? null : JSON.parse(raw)),
      };
      calls.push(call);

      if (handler) return handler(call);

      const pending = queue.get(url) ?? [...queue.entries()].find(([needle]) => url.includes(needle))?.[1];
      const next = pending?.shift();
      if (next) return new Response(JSON.stringify(next.payload), { status: next.status });
      return new Response(JSON.stringify({}), { status: 200 });
    },
  };
  return api;
}

export const OWNER = 'aaaaaaaa-0000-4000-8000-000000000001';
export const PEER = 'bbbbbbbb-0000-4000-8000-000000000002';
export const CHAT_ID = 'cccccccc-0000-4000-8000-000000000003';
export const REQUEST_ID = 'dddddddd-0000-4000-8000-000000000004';
export const TG_CHAT_ID = '5001337420';

export function accountContext(overrides: Partial<AccountContext> = {}): AccountContext {
  return {
    user_id: OWNER,
    username: 'aziz',
    tg_user_id: '100200300',
    auth_state: 'linked',
    session_ref: 'worker-test:aaaaaaaa',
    login_token_enc: null,
    api_id: 2941271,
    worker_id: 'worker-test',
    sync_direction: 'both',
    auto_download_voice: true,
    auto_download_media: true,
    mirror_to_app: true,
    last_sync_at: null,
    access_state: 'active',
    ...overrides,
  };
}

export function outboxRow(overrides: Partial<OutboxRow> = {}): OutboxRow {
  return {
    outbox_id: 41,
    message_id: 'eeeeeeee-0000-4000-8000-000000000005',
    owner_user_id: OWNER,
    chat_id: CHAT_ID,
    tg_chat_id: TG_CHAT_ID,
    kind: 'text',
    payload: { text: 'salom, qalaysiz?' },
    attempts: 1,
    session_ref: 'worker-test:aaaaaaaa',
    tg_user_id: '100200300',
    ...overrides,
  };
}

export function linkClaim(overrides: Partial<LinkClaim> = {}): LinkClaim {
  return {
    request_id: REQUEST_ID,
    kind: 'link',
    step: 'queued',
    user_id: OWNER,
    payload: null,
    session_ref: 'worker-test:aaaaaaaa',
    profile: { username: 'aziz', phone_e164: '+998901112233', email: null },
    account: {
      auth_state: 'awaiting_phone',
      tg_user_id: null,
      session_ref: null,
      login_token_enc: null,
      api_id: null,
    },
    ...overrides,
  };
}

/** Waits until `check()` is true, so tests never depend on a fixed sleep. */
export async function until<T>(
  check: () => T | false | undefined | null | Promise<T | false | null | undefined>,
  timeoutMs = 3_000,
  intervalMs = 10,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value as T;
    if (Date.now() > deadline) throw new Error('until(): condition never became true');
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}
