/**
 * telegram-ingest — the inbound webhook of the Telegram bridge.
 *
 * The TDLib worker is a long-lived MTProto client, so Telegram does not push to
 * us; the worker pushes to *this* endpoint. Putting the write behind a function
 * instead of letting the worker write tables directly gives us:
 *
 *   • one authenticated, HMAC-signed, replay-windowed entry point;
 *   • normalization + per-event error isolation (a bad event never poisons a
 *     batch of 100);
 *   • idempotency: every event carries a `dedupe_key`, and the ledger
 *     (`telegram_inbox_events`) + the unique telegram message key make retries
 *     no-ops, so a worker crash mid-batch cannot duplicate a bubble;
 *   • the write happens inside `bridge_ingest_message()`, which resolves the
 *     mirror chat, the shadow peer, the app-side echo and the unread badge in
 *     one transaction — Realtime then fans it out to every device.
 *
 * Trust model: `Authorization: Bearer BRIDGE_TOKEN` (shared secret) *and*
 * `x-bridge-signature: t=<epoch>,v1=<hmac_sha256(ts.body)>` with a ±60s window.
 * No user JWT is accepted here; a client cannot inject forged Telegram traffic.
 */

import { readEnv, type Env } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import { bearerToken, clientIp, corsHeaders, fail, ok, withEnvelope } from '../_shared/http.ts';
import { requireTokenMatch, verifySignedMessage } from '../_shared/crypto.ts';
import { adminClient, rpc } from '../_shared/supabase.ts';
import { consume } from '../_shared/rate-limit.ts';
import { HttpError, type InboundBatch, type InboundEvent, type InboundResult } from '../_shared/types.ts';

const FUNCTION_NAME = 'telegram-ingest';
const MAX_EVENTS = 200;

type RpcRow = Record<string, unknown> | null;

function normalizeEvent(event: InboundEvent): InboundEvent {
  const owner = typeof event.owner_user_id === 'string' ? event.owner_user_id.trim().toLowerCase() : '';
  if (!/^[0-9a-f-]{36}$/.test(owner)) {
    throw new HttpError('bad_request', 'owner_user_id must be a uuid');
  }
  const chatId = String(event.tg_chat_id ?? '');
  if (!/^-?\d{1,20}$/.test(chatId)) {
    throw new HttpError('bad_request', 'tg_chat_id must be a 64-bit integer as a string');
  }
  const dedupe =
    typeof event.dedupe_key === 'string' && event.dedupe_key.length > 0
      ? event.dedupe_key
      : `${owner}:${chatId}:${event.type}:${event.tg_message_id ?? event.tg_send_id ?? 'x'}`;
  return {
    ...event,
    owner_user_id: owner,
    tg_chat_id: chatId,
    dedupe_key: dedupe.slice(0, 220),
    type: event.type ?? 'message',
    // Telegram ids travel as strings to survive JS numbers; the SQL casts them.
    tg_message_id: event.tg_message_id === undefined ? undefined : String(event.tg_message_id),
    tg_send_id: event.tg_send_id === undefined ? undefined : String(event.tg_send_id),
  };
}

async function dispatch(env: Env, admin: ReturnType<typeof adminClient>, raw: InboundEvent): Promise<InboundResult> {
  const event = normalizeEvent(raw);
  const base = { index: -1, dedupe_key: event.dedupe_key };

  switch (event.type) {
    case 'message':
    case 'message_edit':
    case 'message_delete': {
      const result = await rpc<Record<string, unknown>>(admin, 'bridge_ingest_message', {
        p_event: { ...event, worker_id: (event as unknown as { worker_id?: string }).worker_id },
      });
      return {
        ...base,
        status: (result?.status as InboundResult['status']) ?? 'processed',
        message_id: result?.message_id as string | undefined,
        chat_id: result?.chat_id as string | undefined,
        reason: result?.reason as string | undefined,
      };
    }

    case 'read': {
      const applied = await rpc<number>(admin, 'bridge_update_delivery', { p_event: event });
      return { ...base, status: 'processed', reason: `${applied ?? 0} receipts applied` };
    }

    case 'chat': {
      const resolved = await rpc<Record<string, unknown>>(admin, 'bridge_resolve_chat', {
        p_owner_user_id: event.owner_user_id,
        p_tg_chat_id: event.tg_chat_id,
        p_tg_chat_type: event.tg_chat_type ?? 'private',
        p_title: event.title ?? null,
        p_peer_user_id: event.peer_user_id ?? null,
        p_peer_username: event.peer_username ?? null,
        p_peer_first_name: event.peer_first_name ?? null,
        p_peer_last_name: event.peer_last_name ?? null,
        p_peer_avatar_url: event.peer_avatar_url ?? null,
        p_create: true,
      });
      return { ...base, status: 'processed', chat_id: resolved?.chat_id as string | undefined };
    }

    case 'peer': {
      const peerId = await rpc<string>(admin, 'bridge_upsert_peer', {
        p_owner_user_id: event.owner_user_id,
        p_tg_user_id: event.sender_peer_user_id ?? event.peer_user_id ?? 0,
        p_username: event.sender_username ?? event.peer_username ?? null,
        p_first_name: event.sender_first_name ?? event.peer_first_name ?? null,
        p_last_name: event.sender_last_name ?? event.peer_last_name ?? null,
        p_avatar_url: event.sender_avatar_url ?? event.peer_avatar_url ?? null,
        p_is_contact: event.sender_is_contact ?? null,
      });
      return { ...base, status: 'processed', message_id: peerId ?? undefined };
    }

    case 'outbox_result': {
      const result = await rpc<Record<string, unknown>>(admin, 'bridge_complete_outbox', {
        p_outbox_id: event.outbox_id,
        p_state: event.state === 'failed' ? 'failed' : 'sent',
        p_tg_message_id: event.tg_message_id ?? null,
        p_error: event.error ?? null,
      });
      return { ...base, status: result?.ok ? 'processed' : 'skipped', reason: result?.state as string | undefined };
    }

    case 'link_progress': {
      if (!event.request_id) return { ...base, status: 'skipped', reason: 'request_id required' };
      await rpc<unknown>(admin, 'bridge_link_progress', {
        p_request_id: event.request_id,
        p_status: event.status ?? 'claimed',
        p_step: event.step ?? null,
        p_qr_code: event.qr_code ?? null,
        p_note: event.note ?? null,
        p_error: event.error ?? null,
        p_auth_state: event.auth_state ?? null,
      });
      return { ...base, status: 'processed' };
    }

    case 'state': {
      await rpc<unknown>(admin, 'bridge_set_account_state', {
        p_user_id: event.owner_user_id,
        p_auth_state: event.auth_state ?? 'syncing',
        p_note: event.note ?? null,
        p_error: event.error ?? null,
        p_worker_id: (event as unknown as { worker_id?: string }).worker_id ?? null,
        p_session_ref: (event as unknown as { session_ref?: string }).session_ref ?? null,
        p_last_sync: event.type === 'state' && (event as unknown as { last_sync?: boolean }).last_sync === true,
      });
      return { ...base, status: 'processed' };
    }

    case 'unlink': {
      await rpc<unknown>(admin, 'bridge_set_account_state', {
        p_user_id: event.owner_user_id,
        p_auth_state: 'revoked',
        p_note: null,
        p_error: event.error ?? null,
        p_worker_id: (event as unknown as { worker_id?: string }).worker_id ?? null,
      });
      return { ...base, status: 'processed', reason: 'session dropped' };
    }

    default:
      return { ...base, status: 'skipped', reason: `unsupported event type ${(event as InboundEvent).type}` };
  }
}

/**
 * Events are grouped by owner and applied sequentially inside each group
 * (message order and read receipts must not interleave), while different
 * users are processed concurrently so one slow account cannot stall the fan-in.
 */
async function processBatch(
  env: Env,
  admin: ReturnType<typeof adminClient>,
  events: InboundEvent[],
): Promise<InboundResult[]> {
  const groups = new Map<string, Array<{ event: InboundEvent; index: number }>>();
  events.forEach((event, index) => {
    const key = typeof event.owner_user_id === 'string' ? event.owner_user_id : 'unknown';
    const list = groups.get(key) ?? [];
    list.push({ event, index });
    groups.set(key, list);
  });

  const results = new Array<InboundResult>(events.length);

  await Promise.all(
    [...groups.values()].map(async (group) => {
      for (const { event, index } of group) {
        try {
          results[index] = { ...(await dispatch(env, admin, event)), index };
        } catch (error) {
          const isHttp = error instanceof HttpError;
          log[isHttp ? 'warn' : 'error']('ingest event failed', {
            index,
            type: event.type,
            dedupe_key: event.dedupe_key,
            code: isHttp ? error.code : 'internal_error',
            reason: (error as Error).message,
          });
          results[index] = {
            index,
            dedupe_key: event.dedupe_key ?? 'unknown',
            status: 'error',
            detail: isHttp ? (error as HttpError).message : 'internal error',
          };
        }
      }
    }),
  );

  return results;
}

async function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);
    if (!env.bridgeHmacSecret || !env.bridgeToken) {
      throw new HttpError('misconfigured', 'BRIDGE_HMAC_SECRET / BRIDGE_TOKEN are not set');
    }

    requireTokenMatch(bearerToken(req), env.bridgeToken);

    const raw = await req.text();
    if (raw.length > env.maxBodyBytes) {
      throw new HttpError('payload_too_large', `body exceeds ${env.maxBodyBytes} bytes`);
    }
    await verifySignedMessage({
      secret: env.bridgeHmacSecret,
      signatureHeader: req.headers.get('x-bridge-signature'),
      body: raw,
      toleranceSeconds: env.clockSkewSeconds,
    });

    const limit = consume('ingest', 'global', 600);
    if (!limit.allowed) {
      return fail('rate_limited', 'ingest is saturated', cors, { retryAfterSeconds: limit.retryAfterSeconds });
    }

    const batch = JSON.parse(raw) as Partial<InboundBatch>;
    if (!Array.isArray(batch.events) || batch.events.length === 0) {
      throw new HttpError('bad_request', 'events[] is required');
    }
    if (batch.events.length > Math.min(MAX_EVENTS, env.ingestMaxEvents)) {
      throw new HttpError('bad_request', `events[] accepts at most ${Math.min(MAX_EVENTS, env.ingestMaxEvents)} items`);
    }

    const admin = adminClient(env);
    const started = Date.now();
    const results = await processBatch(env, admin, batch.events);
    const summary: Record<string, number> = { total: results.length };
    for (const result of results) {
      summary[result.status] = (summary[result.status] ?? 0) + 1;
    }

    log.info('ingest batch', {
      worker: batch.worker_id ?? 'unknown',
      ip: clientIp(req) ?? 'unknown',
      ms: Date.now() - started,
      ...summary,
    });

    return ok({ results, summary, took_ms: Date.now() - started }, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

Deno.serve(handle);