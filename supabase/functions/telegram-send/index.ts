/**
 * telegram-send — low-latency hand-off of already-persisted messages.
 *
 * The insert path is *not* here: the app writes `messages` through RLS, and a
 * trigger enqueues the Telegram job in the same transaction, so correctness
 * never depends on this function. What the function buys is latency (waking the
 * worker in ~1ms instead of on the next poll) and an explicit re-sync entry
 * point for the cases the trigger intentionally skips:
 *
 *   * the user linked Telegram *after* sending (no mapping existed then)
 *   * the per-chat mapping was created later
 *   * the user tapped "Send to Telegram" on an old message
 *
 * Requests are executed with the caller's JWT, so RLS and the eligibility gate
 * apply to every read and write exactly as they would from the app.
 */

import { readEnv } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import { bearerToken, clientIp, corsHeaders, expectUuidArray, ok, readJsonBody, withEnvelope } from '../_shared/http.ts';
import { requireUser, rpc, userClient } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { wakeBridge } from '../_shared/bridge.ts';
import { HttpError } from '../_shared/types.ts';

const FUNCTION_NAME = 'telegram-send';
const MAX_IDS = 50;

type RequestBody = {
  messageIds?: string[];
  /** 'enqueue' (default) re-queues missing jobs; 'status' only reads. */
  mode?: 'enqueue' | 'status';
};

async function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);

    const token = bearerToken(req);
    const caller = await requireUser(env, token);
    enforce('telegram-send:uid', caller.uid, 240, 60_000);
    enforce('telegram-send:ip', clientIp(req) ?? 'unknown', 600);

    const body = await readJsonBody<RequestBody>(req, env.maxBodyBytes);
    const ids = expectUuidArray(body.messageIds, 'messageIds', MAX_IDS);
    const mode = body.mode === 'status' ? 'status' : 'enqueue';
    const asUser = userClient(env, token!);

    // Which of these ids are actually the caller's own messages? RLS answers
    // that; anything else simply does not come back.
    const { data: owned, error } = await asUser
      .from('messages')
      .select('id, kind, state, source, chat_id, deleted_at, synced_to_telegram_at')
      .in('id', ids);
    if (error) throw new HttpError('upstream_error', 'could not read the messages');

    const ownedIds = new Set((owned ?? []).map((row: { id: string }) => row.id));
    const unknown = ids.filter((id) => !ownedIds.has(id));
    if (ownedIds.size === 0) {
      throw new HttpError('not_found', 'none of those message ids belong to this account');
    }

    let enqueued = 0;
    if (mode === 'enqueue') {
      enqueued = await rpc<number>(asUser, 'enqueue_telegram_outbox', {
        p_message_ids: [...ownedIds],
      });
      if (enqueued > 0) await wakeBridge(env, { kind: 'outbox', user_ids: [caller.uid], ids });
    }

    const { data: states } = await asUser
      .from('telegram_outbox')
      .select('message_id, state, attempts, last_error, tg_message_id')
      .in('message_id', [...ownedIds]);

    const byMessage = new Map<string, Record<string, unknown>>();
    for (const row of states ?? []) byMessage.set((row as { message_id: string }).message_id, row as Record<string, unknown>);

    log.info('forwarding hand-off', { uid: caller.uid, enqueued, requested: ids.length, unknown: unknown.length });

    return ok({
      enqueued,
      unknown_ids: unknown,
      statuses: [...ownedIds].map((id) => ({
        message_id: id,
        outbox: byMessage.get(id) ?? null,
      })),
    }, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

Deno.serve(handle);