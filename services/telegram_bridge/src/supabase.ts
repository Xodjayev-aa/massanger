/**
 * Postgres + Storage access for the bridge, over Supabase's REST interface.
 *
 * Deliberately a thin, hand-written client instead of `supabase-js`:
 *   • every call is one RPC with an explicit, typed contract (see
 *     supabase/migrations/00007_bridge_rpc.sql) — no query builder drift;
 *   • Postgres SQLSTATEs survive to the caller, which is what the retry
 *     classifier needs (42501 = policy refused, 23505 = duplicate, 55P03 =
 *     lock not available …);
 *   • `fetchImpl` is injectable, so the whole queue protocol is unit-testable
 *     without a database.
 */

import { logger } from './logging.js';
import type { BridgeConfig } from './config.js';
import type { InboundEvent, InboundResult } from './protocol.js';
import { buildSignatureHeader } from './util/envelope.js';

/** undici's `BodyInit` is not a global in @types/node; narrow it once. */
type FetchBody = NonNullable<NonNullable<Parameters<typeof fetch>[1]>['body']>;

export class SupabaseError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'SupabaseError';
  }

  /** `FOR UPDATE SKIP LOCKED` returned nothing useful: not an error, just busy. */
  get isLockUnavailable(): boolean {
    return this.code === '55P03' || this.status === 409;
  }

  get isDuplicate(): boolean {
    return this.code === '23505';
  }

  get retryable(): boolean {
    return this.status >= 500 || this.status === 408 || this.status === 429;
  }
}

export type LinkClaim = {
  request_id: string;
  kind: 'link' | 'reauth' | 'unlink';
  step: string;
  user_id: string;
  payload: Record<string, unknown> | null;
  session_ref: string | null;
  profile: { username: string; phone_e164: string | null; email: string | null };
  account: {
    auth_state: string;
    tg_user_id: string | number | null;
    session_ref: string | null;
    login_token_enc: string | null;
    api_id: number | null;
  };
};

export type OutboxRow = {
  /** `telegram_outbox.id` (bigint sequence; doubles as TDLib's `sending_id`). */
  outbox_id: number;
  message_id: string;
  owner_user_id: string;
  chat_id: string;
  tg_chat_id: string | number | null;
  kind: 'text' | 'image' | 'voice' | 'system';
  payload: {
    text?: string;
    media?: {
      bucket?: string;
      path?: string;
      url?: string;
      mime?: string;
      duration_ms?: number;
      waveform?: number[];
      width?: number;
      height?: number;
      size_bytes?: number;
      caption?: string;
    };
    reply_to?: string;
    tg_reply_to?: string;
    created_at?: string;
  };
  attempts: number;
  session_ref: string | null;
  tg_user_id: string | null;
};

export type AccountContext = {
  user_id: string;
  username: string;
  tg_user_id: string | number | null;
  auth_state: string;
  session_ref: string | null;
  login_token_enc: string | null;
  api_id: number | null;
  worker_id: string | null;
  sync_direction: 'both' | 'to_telegram' | 'from_telegram' | 'off';
  auto_download_voice: boolean;
  auto_download_media: boolean;
  mirror_to_app: boolean;
  last_sync_at: string | null;
  access_state: string;
};

export class SupabaseBridge {
  readonly #headers: Record<string, string>;

  constructor(
    private readonly config: BridgeConfig,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
  ) {
    this.#headers = {
      'content-type': 'application/json',
      accept: 'application/json',
     apikey: config.serviceRoleKey,
      authorization: `Bearer ${config.serviceRoleKey}`,
      'x-application-name': 'massanger-bridge',
    };
  }

  get baseUrl(): string {
    return this.config.supabaseUrl;
  }

  /**
   * PostgREST shapes: `returns table` → array of rows, `returns jsonb` → the
   * object itself, any other scalar → `[{"result": …}]`. `shape` says which one
   * to expect, so a zero-row set and a NULL scalar are never confused.
   */
  async rpc<T>(
    fn: string,
    args: Record<string, unknown>,
    options: { shape?: 'set' | 'scalar' } = {},
  ): Promise<T> {
    const url = `${this.baseUrl}/rest/v1/rpc/${fn}`;
    const response = await this.fetchImpl(url, {
      method: 'POST',
      headers: this.#headers,
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(20_000),
    });

    const text = await response.text();
    if (!response.ok) {
      let parsed: { code?: string; message?: string; details?: unknown; hint?: string } = {};
      try {
        parsed = JSON.parse(text) as typeof parsed;
      } catch {
        /* an HTML error page from a proxy: keep the raw text out of logs */
      }
      throw new SupabaseError(
        `${fn}() failed: ${parsed.message ?? response.status}`,
        response.status,
        parsed.code,
        parsed.details,
      );
    }
    if (text.trim() === '' || text.trim() === 'null') {
      return (options.shape === 'set' ? [] : null) as T;
    }

    const parsed = JSON.parse(text) as unknown;
    // A `returns table` RPC is always a JSON array; anything else (notably a
    // PostgREST error object) is "no rows", never a phantom row.
    if (options.shape === 'set') return (Array.isArray(parsed) ? parsed : []) as T;

    if (Array.isArray(parsed)) {
      if (parsed.length === 0) return null as T;
      const only = parsed[0] as Record<string, unknown>;
      if (only && typeof only === 'object' && 'result' in only && Object.keys(only).length === 1) {
        return only.result as T;
      }
      return (parsed.length === 1 ? only : parsed) as T;
    }
    return parsed as T;
  }

  // ── link handshake ───────────────────────────────────────────────────────
  claimLinkRequest(leaseSeconds = 120): Promise<LinkClaim | null> {
    return this.rpc<LinkClaim | null>(
      'bridge_claim_link_request',
      { p_worker: this.config.workerId, p_lease: `${leaseSeconds} seconds` },
      { shape: 'scalar' },
    );
  }

  linkProgress(input: {
    requestId: string;
    status: 'queued' | 'claimed' | 'awaiting_user' | 'succeeded' | 'failed' | 'expired';
    step?: string | null;
    qrCode?: string | null;
    note?: string | null;
    error?: string | null;
    authState?: string | null;
    sessionRef?: string | null;
  }): Promise<boolean> {
    return this.rpc<boolean>('bridge_link_progress', {
      p_request_id: input.requestId,
      p_status: input.status,
      p_step: input.step ?? null,
      p_qr_code: input.qrCode ?? null,
      p_note: input.note ?? null,
      p_error: input.error ?? null,
      p_auth_state: input.authState ?? null,
      p_session_ref: input.sessionRef ?? null,
    });
  }

  linkComplete(input: {
    requestId: string;
    tgUserId: string;
    tgUsername?: string | null;
    displayName?: string | null;
    phoneCountryCode?: string | null;
    sessionRef?: string | null;
    loginTokenEnc?: string | null;
    apiId?: number | null;
  }): Promise<unknown> {
    return this.rpc('bridge_link_complete', {
      p_request_id: input.requestId,
      p_tg_user_id: input.tgUserId,
      p_tg_username: input.tgUsername ?? null,
      p_display_name: input.displayName ?? null,
      p_phone_cc: input.phoneCountryCode ?? null,
      p_session_ref: input.sessionRef ?? null,
      p_login_token_enc: input.loginTokenEnc ?? null,
      p_api_id: input.apiId ?? null,
    });
  }

  accountContext(userId: string): Promise<AccountContext | null> {
    return this.rpc<AccountContext | null>('bridge_account_context', { p_user_id: userId }, { shape: 'scalar' });
  }

  setAccountState(input: {
    userId: string;
    authState: string;
    note?: string | null;
    error?: string | null;
    sessionRef?: string | null;
    lastSync?: boolean;
  }): Promise<boolean> {
    return this.rpc<boolean>('bridge_set_account_state', {
      p_user_id: input.userId,
      p_auth_state: input.authState,
      p_note: input.note ?? null,
      p_error: input.error ?? null,
      p_worker_id: this.config.workerId,
      p_session_ref: input.sessionRef ?? null,
      p_last_sync: input.lastSync ?? false,
    });
  }

  // ── outbox ────────────────────────────────────────────────────────────────
  claimOutbox(ownerUserId: string | null = null, limit = this.config.outboxBatchSize): Promise<OutboxRow[]> {
    return this.rpc<OutboxRow[]>('bridge_claim_outbox', {
      p_worker: this.config.workerId,
      p_owner: ownerUserId,
      p_limit: limit,
      p_lease: `${this.config.outboxLeaseSeconds} seconds`,
    }, { shape: 'set' }).then((rows) => rows ?? []);
  }

  completeOutbox(input: {
    outboxId: number;
    state: 'sent' | 'failed' | 'skipped' | 'queued';
    tgMessageId?: string | null;
    error?: string | null;
    retrySeconds?: number;
  }): Promise<unknown> {
    return this.rpc('bridge_complete_outbox', {
      p_outbox_id: input.outboxId,
      p_state: input.state,
      p_tg_message_id: input.tgMessageId ?? null,
      p_error: input.error ? input.error.slice(0, 480) : null,
      p_retry_in: `${Math.max(1, input.retrySeconds ?? 30)} seconds`,
    });
  }

  failPendingSends(ownerUserId: string, reason: string): Promise<number> {
    return this.rpc<number>(
      'bridge_fail_pending_sends',
      { p_owner: ownerUserId, p_error: reason.slice(0, 480) },
      { shape: 'scalar' },
    );
  }

  resolveChat(input: {
    ownerUserId: string;
    tgChatId: string | number;
    tgChatType?: string;
    title?: string | null;
    peerUserId?: string | null;
    peerUsername?: string | null;
    peerFirstName?: string | null;
    peerLastName?: string | null;
    peerAvatarUrl?: string | null;
    create?: boolean;
  }): Promise<{ chat_id: string | null; created: boolean; mapping_id: string | null; peer_id?: string | null }> {
    return this.rpc('bridge_resolve_chat', {
      p_owner_user_id: input.ownerUserId,
      p_tg_chat_id: input.tgChatId,
      p_tg_chat_type: input.tgChatType ?? 'private',
      p_title: input.title ?? null,
      p_peer_user_id: input.peerUserId ?? null,
      p_peer_username: input.peerUsername ?? null,
      p_peer_first_name: input.peerFirstName ?? null,
      p_peer_last_name: input.peerLastName ?? null,
      p_peer_avatar_url: input.peerAvatarUrl ?? null,
      p_create: input.create ?? true,
    }, { shape: 'scalar' });
  }

  // ── inbound: function webhook (default) or direct RPC ─────────────────────
  async pushEvents(events: InboundEvent[], signal?: AbortSignal): Promise<InboundResult[]> {
    if (events.length === 0) return [];
    const batch = { worker_id: this.config.workerId, ts: Math.floor(Date.now() / 1000), events };
    const body = JSON.stringify(batch);
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.config.bridgeToken) headers.authorization = `Bearer ${this.config.bridgeToken}`;
    if (this.config.bridgeHmacSecret) {
      const { header } = buildSignatureHeader(this.config.bridgeHmacSecret, body);
      headers['x-bridge-signature'] = header;
    }

    if (this.config.ingestMode === 'rpc') {
      const results: InboundResult[] = [];
      for (const [index, event] of events.entries()) {
        try {
          const outcome: Record<string, unknown> =
            event.type === 'read'
              ? ((await this.rpc<{ applied?: number }>('bridge_update_delivery', { p_event: event }, {
                  shape: 'scalar',
                })) ?? {})
              : ((await this.rpc<Record<string, unknown>>('bridge_ingest_message', { p_event: event }, {
                  shape: 'scalar',
                })) ?? {});
          results.push({
            index,
            dedupe_key: event.dedupe_key,
            status: (outcome?.status as InboundResult['status']) ?? 'processed',
            message_id: outcome?.message_id as string | undefined,
            chat_id: outcome?.chat_id as string | undefined,
          });
        } catch (error) {
          results.push({ index, dedupe_key: event.dedupe_key, status: 'error', detail: (error as Error).message });
        }
      }
      return results;
    }

    const response = await this.fetchImpl(this.config.ingestEndpoint, {
      method: 'POST',
      headers,
      body,
      signal: signal ?? AbortSignal.timeout(this.config.ingestTimeoutMs),
    });
    const text = await response.text();
    if (!response.ok) {
      throw new SupabaseError(`telegram-ingest responded ${response.status}`, response.status, undefined, safeJson(text));
    }
    const parsed = safeJson(text) as { data?: { results?: InboundResult[] } } | null;
    return parsed?.data?.results ?? [];
  }

  // ── storage ───────────────────────────────────────────────────────────────
  /** Uploads mirrored media. `x-upsert` makes a re-download idempotent. */
  /** @throws SupabaseError when the bucket policy or a size limit refuses. */
  async upload(bucket: string, path: string, data: Uint8Array, contentType: string): Promise<string> {
    const url = `${this.baseUrl}/storage/v1/object/${bucket}/${encodeURI(path)}`;
    const response = await this.fetchImpl(url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${this.config.serviceRoleKey}`,
        apikey: this.config.serviceRoleKey,
        'content-type': contentType,
        'x-upsert': 'true',
      },
      body: data as unknown as FetchBody,
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) {
      throw new SupabaseError(`storage upload failed (${response.status}) for ${bucket}/${path}`, response.status);
    }
    const payload = (await response.json().catch(() => ({}))) as { Key?: string; path?: string };
    return payload.path ?? payload.Key ?? path;
  }

  /** Reads an object the app uploaded (outbound media → TDLib input file). */
  async download(bucket: string, path: string, maxBytes: number): Promise<Uint8Array> {
    const url = `${this.baseUrl}/storage/v1/object/${bucket}/${encodeURI(path)}`;
    const response = await this.fetchImpl(url, {
      method: 'GET',
      headers: {
        authorization: `Bearer ${this.config.serviceRoleKey}`,
        apikey: this.config.serviceRoleKey,
        accept: '*/*',
      },
      signal: AbortSignal.timeout(60_000),
    });
    if (!response.ok) {
      throw new SupabaseError(`storage download failed (${response.status}) for ${bucket}/${path}`, response.status);
    }
    const buffer = new Uint8Array(await response.arrayBuffer());
    if (buffer.byteLength > maxBytes) {
      throw new SupabaseError(
        `object ${bucket}/${path} is ${buffer.byteLength} bytes; the limit is ${maxBytes}`,
        413,
      );
    }
    return buffer;
  }

  /** Public URL for `avatars` (that bucket is public by design). */
  publicUrl(bucket: string, path: string): string {
    return `${this.baseUrl}/storage/v1/object/public/${bucket}/${encodeURI(path)}`;
  }

  /**
   * The app mints its own signed URLs for chat media (its JWT passes the
   * storage RLS policy); the bridge only needs this for the odd debug flow, so
   * it goes straight to the Storage REST endpoint instead of a client library.
   */
  async signedUrl(bucket: string, path: string, ttlSeconds = 3_600): Promise<string> {
    const url = `${this.baseUrl}/storage/v1/object/sign/${bucket}/${encodeURI(path)}`;
    const response = await this.fetchImpl(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${this.config.serviceRoleKey}`,
        apikey: this.config.serviceRoleKey,
      },
      body: JSON.stringify({ expiresIn: ttlSeconds }),
    });
    if (!response.ok) throw new SupabaseError(`could not sign ${bucket}/${path}`, response.status);
    const payload = (await response.json()) as { signedURL: string };
    return payload.signedURL.startsWith('http') ? payload.signedURL : `${this.baseUrl}${payload.signedURL}`;
  }

  // ── presence + read receipts (00010) ─────────────────────────────────────
  pendingTyping(ownerUserId: string, since: Date, limit = 20): Promise<TypingRow[]> {
    return this.rpc<TypingRow[]>(
      'bridge_pending_typing',
      { p_owner: ownerUserId, p_since: since.toISOString(), p_limit: limit },
      { shape: 'set' },
    ).then((rows) => rows ?? []);
  }

  /**
   * Typing is deliberately not routed through the ingest webhook: it is
   * high-frequency, low-value, and `telegram_inbox_events.dedupe_key` is not
   * designed for it. One direct RPC per chat per poll is all it costs, and
   * losing one only costs an animation.
   */
  reportTyping(ownerUserId: string, tgChatId: string | number, action: string): Promise<boolean> {
    return this.rpc<boolean>(
      'bridge_report_typing',
      { p_owner: ownerUserId, p_tg_chat_id: String(tgChatId), p_action: action },
      { shape: 'scalar' },
    ).catch((error: Error) => {
      logger.debug('typing report dropped', { reason: error.message });
      return false;
    });
  }

  pendingReads(ownerUserId: string, limit = 25): Promise<ReadRow[]> {
    return this.rpc<ReadRow[]>(
      'bridge_pending_reads',
      { p_owner: ownerUserId, p_limit: limit },
      { shape: 'set' },
    ).then((rows) => rows ?? []);
  }

  markReadsSynced(ownerUserId: string, tgChatId: string | number, maxRead: string | number): Promise<boolean> {
    return this.rpc<boolean>(
      'bridge_mark_reads_synced',
      { p_owner: ownerUserId, p_tg_chat_id: String(tgChatId), p_max_read: String(maxRead) },
      { shape: 'scalar' },
    );
  }

  markInboxRead(ownerUserId: string, tgChatId: string | number, upTo?: string | number): Promise<number> {
    return this.rpc<number>(
      'bridge_mark_inbox_read',
      {
        p_owner: ownerUserId,
        p_tg_chat_id: String(tgChatId),
        p_up_to_tg_message_id: upTo === undefined ? null : String(upTo),
      },
      { shape: 'scalar' },
    ).then((value) => Number(value ?? 0));
  }

  listSessions(limit = 200): Promise<SessionRow[]> {
    return this.rpc<SessionRow[]>(
      'bridge_list_sessions',
      { p_worker: this.config.workerId, p_limit: limit },
      { shape: 'set' },
    ).then((rows) => rows ?? []);
  }

  /** Local dev / single-process deployments: ignore worker affinity. */
  listAllSessions(limit = 200): Promise<SessionRow[]> {
    return this.rpc<SessionRow[]>('bridge_list_sessions', { p_worker: null, p_limit: limit }, { shape: 'set' }).then(
      (rows) => rows ?? [],
    );
  }

  recordEvent(event: Record<string, unknown>): Promise<unknown> {
    return this.rpc('bridge_record_event', { p_event: event }, { shape: 'scalar' });
  }
}

export type TypingRow = {
  chat_id: string;
  tg_chat_id: string | number;
  action: string;
  updated_at: string;
};

export type ReadRow = {
  chat_id: string;
  tg_chat_id: string | number;
  max_read_message_id: string | number;
};

export type SessionRow = {
  user_id: string;
  username: string;
  auth_state: 'linked' | 'syncing' | 'needs_reauth' | string;
  session_ref: string | null;
  tg_user_id: string | number | null;
  api_id: number | null;
  assigned_worker: string | null;
  sync_direction: 'both' | 'to_telegram' | 'from_telegram' | 'off';
  has_login_token: boolean;
  last_sync_at: string | null;
};

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text.slice(0, 300);
  }
}
