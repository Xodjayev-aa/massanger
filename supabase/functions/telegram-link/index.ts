/**
 * telegram-link — the client's side of the TDLib authorization handshake.
 *
 * Why this is a function and not just RPC calls:
 *   * login codes and 2FA passwords are sealed here (AES-256-GCM, SEAL_KEY)
 *     before they ever reach Postgres, so the queue table only holds
 *     ciphertext with a TTL;
 *   * the bridge is pinged immediately, which takes the phone-code round-trip
 *     from "next poll tick" to "now";
 *   * input is normalized (E.164, code charset) and rate limited per user.
 *
 * The state machine (see docs/architecture.md):
 *
 *   app: start(phone)          → link_requests(step=queued)      → worker
 *   worker: TDLib setAuthenticationParameters → progress(awaiting_code)
 *   app: submit(code)          → sealed envelope on the same row  → worker
 *   worker: checkAuthenticationCode [→ awaiting_password] → complete()
 *   app: status()              → renders the Profile screen toggle
 */

import { readEnv, sealingAvailable } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import {
  bearerToken,
  clientIp,
  corsHeaders,
  expectString,
  ok,
  readJsonBody,
  UUID_RE,
  withEnvelope,
} from '../_shared/http.ts';
import { requireUser, rpc, userClient } from '../_shared/supabase.ts';
import { aesKeyFromSecret, seal } from '../_shared/crypto.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { wakeBridge } from '../_shared/bridge.ts';
import { HttpError, type LinkEnvelopePayload, type SyncDirection } from '../_shared/types.ts';

const FUNCTION_NAME = 'telegram-link';

type Action = 'start' | 'submit' | 'status' | 'cancel' | 'unlink' | 'preferences' | 'chatSync' | 'startChat';

type RequestBody = {
  action?: Action;
  phone?: string;
  username?: string;
  useQr?: boolean;
  requestId?: string;
  code?: string;
  password?: string;
  syncDirection?: SyncDirection;
  autoDownloadVoice?: boolean;
  autoDownloadMedia?: boolean;
  mirrorToApp?: boolean;
  chatId?: string;
  direction?: SyncDirection;
};

const PHONE_RE = /^\+?[0-9]{6,20}$/;
const CODE_RE = /^[0-9A-Za-z]{3,20}$/;
const DIRECTIONS: SyncDirection[] = ['both', 'to_telegram', 'from_telegram', 'off'];

/** E.164 input may arrive as `+998 90 111 22 33` from any keyboard. */
function normalizePhone(raw: string): string {
  const digits = raw.replace(/[^\d+]/g, '');
  const plusless = digits.replace(/\+/g, '');
  if (plusless.length < 7 || plusless.length > 20) throw new HttpError('bad_request', 'phone number must be 7–20 digits');
  const normalized = `+${plusless}`;
  if (!PHONE_RE.test(normalized)) throw new HttpError('bad_request', 'phone number must be in E.164 format');
  return normalized;
}

async function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);

    const token = bearerToken(req);
    const caller = await requireUser(env, token);
    enforce('telegram-link:uid', caller.uid, 30);
    enforce('telegram-link:ip', clientIp(req) ?? 'unknown', 120);

    const body = await readJsonBody<RequestBody>(req, env.maxBodyBytes);
    const action = (expectString(body.action, 'action', { max: 20 }) ?? 'status') as Action;
    const asUser = userClient(env, token!);
    const sealKey = env.sealKey ? await aesKeyFromSecret(env.sealKey) : null;

    const pack = async (payload: LinkEnvelopePayload) => {
      const envelope = await seal(payload, sealKey);
      return envelope;
    };

    switch (action) {
      case 'start': {
        const payload: LinkEnvelopePayload = {};
        if (typeof body.phone === 'string' && body.phone.trim() !== '') {
          payload.phone = normalizePhone(body.phone);
        }
        if (body.useQr === true) payload.use_qr = true;
        const envelope = await pack(payload);

        const data = await rpc<{ request_id: string; step: string; expires_at: string }>(
          asUser,
          'telegram_link_start',
          { p_envelope: envelope, p_use_qr: body.useQr === true },
        );
        await wakeBridge(env, { kind: 'link', user_ids: [caller.uid], ids: [data.request_id] });
        log.info('link handshake started', { uid: caller.uid, requestId: data.request_id, sealed: sealingAvailable(env) });
        return ok({ ...data, sealed: sealingAvailable(env) }, cors);
      }

      case 'submit': {
        const requestId = expectString(body.requestId, 'requestId', { pattern: UUID_RE })!;
        const payload: LinkEnvelopePayload = {};
        if (typeof body.code === 'string' && body.code.trim() !== '') {
          const code = body.code.replace(/[\s-]/g, '');
          if (!CODE_RE.test(code)) throw new HttpError('bad_request', 'the code must be 3–20 letters or digits');
          payload.code = code;
        }
        if (typeof body.password === 'string' && body.password !== '') {
          if (body.password.length > 128) throw new HttpError('bad_request', 'password too long');
          payload.password = body.password;
        }
        if (typeof body.phone === 'string' && body.phone.trim() !== '') {
          payload.phone = normalizePhone(body.phone);
        }
        if (Object.keys(payload).length === 0) {
          throw new HttpError('bad_request', 'nothing to submit: pass code, password or phone');
        }

        await rpc<boolean>(asUser, 'telegram_link_submit', {
          p_request_id: requestId,
          p_envelope: await pack(payload),
        });
        await wakeBridge(env, { kind: 'link', user_ids: [caller.uid], ids: [requestId] });
        return ok({ submitted: true }, cors);
      }

      case 'status': {
        const state = await rpc<Record<string, unknown>>(asUser, 'telegram_link_state', {});
        return ok(state ?? { auth_state: 'unlinked' }, cors);
      }

      case 'cancel': {
        const requestId = expectString(body.requestId, 'requestId', { pattern: UUID_RE })!;
        await rpc<boolean>(asUser, 'telegram_link_cancel', { p_request_id: requestId });
        return ok({ cancelled: true }, cors);
      }

      case 'unlink': {
        const result = await rpc<{ request_id: string }>(asUser, 'telegram_unlink', {});
        await wakeBridge(env, { kind: 'relink', user_ids: [caller.uid], ids: [result.request_id] });
        // Telegram unlink revokes the worker's TDLib session. MessengerX no
        // longer stores Gmail or Drive consent as part of sign-in.
        return ok({ unlink_requested: true, request_id: result.request_id }, cors);
      }

      case 'preferences': {
        const args: Record<string, unknown> = {};
        if (body.syncDirection && DIRECTIONS.includes(body.syncDirection)) {
          args.p_sync_direction = body.syncDirection;
        }
        if (typeof body.autoDownloadVoice === 'boolean') args.p_auto_download_voice = body.autoDownloadVoice;
        if (typeof body.autoDownloadMedia === 'boolean') args.p_auto_download_media = body.autoDownloadMedia;
        if (typeof body.mirrorToApp === 'boolean') args.p_mirror_to_app = body.mirrorToApp;
        if (Object.keys(args).length === 0) throw new HttpError('bad_request', 'no preferences supplied');
        // telegram_set_preferences() is a SECURITY DEFINER function that scopes
        // itself with app.current_uid(); it has to run as the caller, or the
        // service_role identity updates nothing at all.
        const data = await rpc(asUser, 'telegram_set_preferences', args);
        await wakeBridge(env, { kind: 'relink', user_ids: [caller.uid] });
        return ok(data ?? {}, cors);
      }

      case 'startChat': {
        // The RPC validates link state, enforces a persistent per-user limit,
        // and accepts only a public @username. No client-supplied Telegram chat
        // ID can reach the bridge's mapping/finish functions.
        const username = expectString(body.username, 'username', { max: 64 })!;
        const data = await rpc<{ request_id: string; status: string; expires_at: string }>(
          asUser, 'telegram_start_chat', { p_username: username },
        );
        await wakeBridge(env, { kind: 'chat', user_ids: [caller.uid], ids: [data.request_id] });
        return ok(data, cors);
      }

      case 'chatSync': {
        const chatId = expectString(body.chatId, 'chatId', { pattern: UUID_RE })!;
        if (!body.direction || !DIRECTIONS.includes(body.direction)) {
          throw new HttpError('bad_request', 'direction must be one of ' + DIRECTIONS.join('|'));
        }
        const applied = await rpc<boolean>(asUser, 'telegram_set_chat_sync', {
          p_chat_id: chatId,
          p_direction: body.direction,
        });
        // No ids: a chat-level toggle only needs the worker to re-read
        // bridge_account_context() for this owner.
        await wakeBridge(env, { kind: 'relink', user_ids: [caller.uid] });
        return ok({ applied: applied === true, chat_id: chatId, direction: body.direction }, cors);
      }

      default:
        throw new HttpError('bad_request', `unknown action "${action}"`);
    }
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

Deno.serve(handle);