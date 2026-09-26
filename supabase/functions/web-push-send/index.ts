/**
 * web-push-send — the only thing that sends a browser notification.
 *
 * Two entry points on one route:
 *
 *   GET  → the public VAPID key. The app needs it *before* it can subscribe, and
 *          it is public by design: every push request carries it in the clear as
 *          the `k=` parameter. Nothing else is exposed, and the whole feature
 *          reports `configured: false` (rather than an error) when the operator
 *          has not set the VAPID secrets, so the client can simply hide the
 *          switch instead of showing a broken one.
 *
 *   POST → drain the `web_push_requests` queue once.
 *
 * Why a sweep and not one call per message: the queue already exists in
 * Postgres, and `web_push_claim` is the thing that makes delivery safe. A sweep
 * is idempotent, resumable and self-healing — losing one invocation costs
 * latency, never a message.
 *
 * Who is allowed to ask for a sweep:
 *
 *   • Any authenticated user, with their own JWT. This is the low-latency path
 *     and mirrors `telegram-send`: the sender's tab, which is online by
 *     definition, pokes us right after `send_message` returns. It buys
 *     immediacy; correctness never depends on it.
 *   • The scheduled/webhook path, with WEB_PUSH_SWEEP_TOKEN. Migration `00018`
 *     makes `pg_net` POST here the instant a notice is queued, so this is the
 *     path that delivers within seconds with no machine of ours running and no
 *     scheduler for the operator to configure. Without it the feature still
 *     works — it is just only as immediate as the next heartbeat (00017).
 *
 * The scheduled caller is also the only one allowed to *wait* (`wait_ms`): a
 * notice is held for a 2 s fold window, so a webhook fired at INSERT time
 * arrives before the row is due. Rather than sleeping inside somebody's
 * message transaction or asking the operator to install `pg_cron`, the
 * invocation is held briefly and claims again. A user's request is never held
 * open for this. See `_shared/push-sweep.ts`.
 *
 * The function is deployed with `verify_jwt = false` because the scheduled
 * caller has no Supabase session. Both paths are therefore authenticated by
 * hand below, and a missing secret fails closed rather than falling through.
 */

import { readEnv } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import { bearerToken, clientIp, corsHeaders, ok, readJsonBody, withEnvelope } from '../_shared/http.ts';
import { adminClient, requireUser, rpc, type AdminClient } from '../_shared/supabase.ts';
import { timingSafeEqual } from '../_shared/crypto.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { HttpError } from '../_shared/types.ts';
import { buildPushRequest, loadVapidKeys, type VapidKeys } from '../_shared/webpush.ts';
import { resolveSweepPlan, WAIT_MS_MAX } from '../_shared/push-sweep.ts';

const FUNCTION_NAME = 'web-push-send';

/** A sender's tab may drain a few rows; the scheduled caller may drain more. */
const USER_SWEEP_LIMIT = 5;
const SCHEDULED_SWEEP_LIMIT = 25;

/** Long enough for a slow push service, short enough that the lease outlives us. */
const POST_TIMEOUT_MS = 10_000;
const LEASE = '90 seconds';

type ClaimedNotice = {
  id: string;
  user_id: string;
  chat_id: string;
  chat_title: string | null;
  chat_kind: string;
  sender_name: string;
  preview: string;
  folded: number;
  attempts: number;
  max_attempts: number;
};

type PushTargetRow = {
  user_id: string;
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
};

type SweepResult = {
  claimed: number;
  delivered: number;
  skipped: number;
  retried: number;
  failed: number;
  gone: number;
};

/**
 * The notification text. Kept here rather than in SQL so the *policy* (what may
 * appear on a lock screen) stays in one place: the database decides whether a
 * preview exists at all, and this decides how it reads.
 *
 * A group chat is titled by the group, because "Aziz" alone does not say where.
 */
export function renderNotice(notice: ClaimedNotice): { title: string; body: string } {
  const sender = notice.sender_name.trim() === '' ? 'MessengerX' : notice.sender_name.trim();
  const group = notice.chat_kind === 'group' && (notice.chat_title ?? '').trim() !== '';
  const title = group ? `${notice.chat_title!.trim()} · ${sender}` : sender;

  const preview = notice.preview.trim();
  const body = preview === ''
    // Previews are off: say just enough to be useful, and nothing more.
    ? (notice.folded > 1 ? `${notice.folded} new messages` : 'New message')
    : (notice.folded > 1 ? `${preview} (+${notice.folded - 1} more)` : preview);

  return { title, body };
}

/** Deep link that opens the chat the notification is about. */
const noticeUrl = (chatId: string): string => `/chats/${chatId}`;

async function sweep(
  admin: AdminClient,
  keys: VapidKeys,
  options: { limit: number; subject: string; extraEndpointHosts: string[]; worker: string },
): Promise<SweepResult> {
  const result: SweepResult = { claimed: 0, delivered: 0, skipped: 0, retried: 0, failed: 0, gone: 0 };

  const claimed = await rpc<ClaimedNotice[]>(admin, 'web_push_claim', {
    p_worker: options.worker,
    p_limit: options.limit,
    p_lease: LEASE,
  });
  const notices = Array.isArray(claimed) ? claimed : [];
  result.claimed = notices.length;
  if (notices.length === 0) return result;

  // One lookup for every recipient in this sweep, instead of one per notice.
  const userIds = [...new Set(notices.map((notice) => notice.user_id))];
  const targetRows = await rpc<PushTargetRow[]>(admin, 'web_push_targets', { p_user_ids: userIds });
  const byUser = new Map<string, PushTargetRow[]>();
  for (const target of Array.isArray(targetRows) ? targetRows : []) {
    const list = byUser.get(target.user_id) ?? [];
    list.push(target);
    byUser.set(target.user_id, list);
  }

  for (const notice of notices) {
    // The lease is a claim, not a promise. Re-check immediately before spending
    // the encryption: the recipient may have read the chat, muted it, gone
    // online, or switched previews off since the claim — and a preview that
    // changed is a privacy event, not a formatting one.
    const owed = await rpc<boolean>(admin, 'web_push_owed', {
      p_notify_id: notice.id,
      p_worker: options.worker,
      p_preview: notice.preview,
    });
    if (owed !== true) {
      await rpc(admin, 'web_push_complete', { p_notify_id: notice.id, p_state: 'skipped' });
      result.skipped++;
      continue;
    }

    const targets = byUser.get(notice.user_id) ?? [];
    if (targets.length === 0) {
      // Every browser this user had is gone or disabled. Nobody is waiting.
      await rpc(admin, 'web_push_complete', {
        p_notify_id: notice.id,
        p_state: 'skipped',
        p_error: 'no live browser',
      });
      result.skipped++;
      continue;
    }

    const message = { ...renderNotice(notice), data: { chat_id: notice.chat_id, url: noticeUrl(notice.chat_id) } };
    let delivered = 0;
    let lastError: string | null = null;

    for (const target of targets) {
      try {
        const request = await buildPushRequest(
          { endpoint: target.endpoint, p256dh: target.p256dh, auth: target.auth },
          { ...message, tag: notice.chat_id },
          keys,
          { subject: options.subject, extraEndpointHosts: options.extraEndpointHosts },
        );

        const response = await fetch(request.url, {
          ...request.init,
          signal: AbortSignal.timeout(POST_TIMEOUT_MS),
        });

        if (response.ok) {
          delivered++;
          await rpc(admin, 'web_push_target_result', { p_subscription_id: target.id, p_ok: true });
          continue;
        }

        // 404/410 is the push service telling us this subscription is
        // permanently gone — the user cleared site data or uninstalled the PWA.
        // Retrying is pointless; the row is deleted.
        const gone = response.status === 404 || response.status === 410;
        if (gone) result.gone++;
        lastError = `HTTP ${response.status}`;
        await rpc(admin, 'web_push_target_result', {
          p_subscription_id: target.id,
          p_ok: false,
          p_gone: gone,
          p_error: lastError,
        });
      } catch (error) {
        // A network failure, an abort or a bad endpoint is per-subscription, not
        // per-notice: the other browsers still get their notification.
        lastError = (error as Error)?.name === 'TimeoutError' ? 'push service timed out' : 'push service unreachable';
        await rpc(admin, 'web_push_target_result', {
          p_subscription_id: target.id,
          p_ok: false,
          p_error: lastError,
        });
      }
    }

    if (delivered > 0) {
      await rpc(admin, 'web_push_complete', { p_notify_id: notice.id, p_state: 'sent', p_delivered: delivered });
      result.delivered++;
      continue;
    }

    // Nothing got through. Give up for good once the attempts run out, so a
    // permanently broken state surfaces instead of looping quietly.
    const exhausted = notice.attempts >= notice.max_attempts;
    await rpc(admin, 'web_push_complete', {
      p_notify_id: notice.id,
      p_state: exhausted ? 'failed' : 'queued',
      p_delivered: 0,
      p_error: lastError ?? 'no browser accepted the notification',
      p_retry_in: '60 seconds',
    });
    if (exhausted) result.failed++;
    else result.retried++;
  }

  return result;
}

async function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    const admin = adminClient(env);

    // ---- GET: the public half of the VAPID identity ------------------------
    if (req.method === 'GET') {
      return ok({
        configured: env.webPushVapidPublicKey !== null,
        vapid_public_key: env.webPushVapidPublicKey,
      }, cors);
    }

    if (req.method !== 'POST') {
      throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts GET and POST`);
    }

    const configured = env.webPushVapidPublicKey && env.webPushVapidPrivateKey && env.webPushVapidSubject;
    if (!configured) {
      // Fail closed, and say so plainly: a deployment without VAPID secrets has
      // no business pretending it can deliver anything.
      throw new HttpError('misconfigured', 'browser push is not configured on this deployment');
    }

    const token = bearerToken(req);
    // Compared in constant time, like every other shared secret in this codebase:
    // a plain `===` on a secret leaks its prefix through timing.
    const isScheduled = env.webPushSweepToken !== null && token !== null &&
      timingSafeEqual(token, env.webPushSweepToken);

    let limit = SCHEDULED_SWEEP_LIMIT;
    let worker = `scheduled-${crypto.randomUUID()}`;
    if (isScheduled) {
      enforce('web-push-send:ip', clientIp(req) ?? 'unknown', 240);
    } else {
      // A user-triggered sweep is a latency optimisation, so it is bounded and
      // rate-limited: it must never become a way to make us spend money.
      const caller = await requireUser(env, token);
      enforce('web-push-send:uid', caller.uid, 30, 60_000);
      enforce('web-push-send:ip', clientIp(req) ?? 'unknown', 600);
      limit = USER_SWEEP_LIMIT;
      worker = `sender-${caller.uid.slice(0, 8)}-${crypto.randomUUID().slice(0, 8)}`;
    }

    const body = await readJsonBody<Record<string, unknown>>(req, env.maxBodyBytes);
    const plan = resolveSweepPlan(body, { maxLimit: limit, isScheduled });

    const keys = await loadVapidKeys(env.webPushVapidPublicKey!, env.webPushVapidPrivateKey!);
    const sweepOnce = () => sweep(admin, keys, {
      limit: plan.limit,
      subject: env.webPushVapidSubject!,
      extraEndpointHosts: env.webPushEndpointHosts,
      worker,
    });

    let result = await sweepOnce();

    // The webhook fires at INSERT time, but the row is deliberately held for a
    // 2 s quiet window so a burst folds into one notification — so arriving
    // early is the *expected* case, not an error. Hold this invocation and try
    // once more rather than leaving the notice for the next heartbeat.
    if (plan.waitMs > 0 && result.claimed === 0) {
      await new Promise((resolve) => setTimeout(resolve, Math.min(plan.waitMs, WAIT_MS_MAX)));
      const second = await sweepOnce();
      result = { ...second, claimed: second.claimed };
    }

    log.info('sweep complete', { ...result, scheduled: isScheduled, waited_ms: plan.waitMs, worker });
    return ok(result, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

Deno.serve(handle);
