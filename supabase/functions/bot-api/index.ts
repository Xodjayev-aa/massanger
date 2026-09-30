/**
 * bot-api — the HTTP face of a bot token.
 *
 * The database already owns the whole bot surface: tokens are hashed in
 * `public.bots`, `app.bot_touch` enforces the per-minute budget, and
 * `public.bot_api` dispatches Telegram-shaped methods. This function exists so
 * that surface is reachable from outside the app — from curl, from a Vercel
 * cron, from a Raspberry Pi under somebody's desk — without ever handing a bot
 * owner a Supabase key.
 *
 *   POST { "token": "12345:abc…", "method": "sendMessage",
 *          "payload": { "chat_id": "…", "text": "hi" } }
 *
 * The reply is Telegram's: `{ ok: true, result: … }`, or `{ ok: false,
 * error_code, description }` with an HTTP 200, because a bot author's code
 * should branch on the body, not on a status line. `verify_jwt` is off (see
 * supabase/config.toml) — the token *is* the credential, and it is passed
 * through to the database, which is the only thing that can validate it.
 */

import { readEnv } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import {
  clientIp,
  corsHeaders,
  fail,
  ok,
  readJsonBody,
  withEnvelope,
} from '../_shared/http.ts';
import { adminClient } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { HttpError } from '../_shared/types.ts';

const FUNCTION_NAME = 'bot-api';
const MAX_BODY = 64 * 1024;

/** Telegram's own shape — a bot ported from there keeps working. */
const METHODS = new Set([
  'getme',
  'sendmessage',
  'editmessagetext',
  'deletemessage',
  'pinchatmessage',
  'unpinchatmessage',
  'sendchataction',
  'getchat',
  'getchatmember',
  'getchatmembercount',
  'banchatmember',
  'unbanchatmember',
  'restrictchatmember',
  'promotechatmember',
  'setmycommands',
  'getmycommands',
  'setwebhook',
  'deletewebhook',
  'answerinlinequery',
  'leavechat',
  'getupdates',
]);

type RequestBody = {
  token?: string;
  method?: string;
  payload?: Record<string, unknown>;
};

function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  const wrapped = withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') {
      throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);
    }
    // Cheap first gate: the fine-grained limit is per bot, inside the database.
    enforce('bot-api:ip', clientIp(req) ?? 'unknown', 300, 60_000);

    const body = await readJsonBody<RequestBody>(req, MAX_BODY);
    const token = typeof body.token === 'string' ? body.token.trim() : '';
    const method = typeof body.method === 'string' ? body.method.trim().toLowerCase() : '';
    if (token.length < 8) {
      return fail('unauthorized', 'a bot token is required', cors, { status: 401 });
    }
    if (!METHODS.has(method)) {
      return fail('bad_request', `unknown method ${method || '(none)'}`, cors, { status: 400 });
    }

    const { data, error } = await adminClient(env).rpc('bot_api', {
      p_token: token,
      p_method: method,
      p_payload: body.payload ?? {},
    });
    if (error) {
      // A database failure here is ours, not the bot author's; say so plainly
      // rather than dressing it up as a Telegram error.
      log.error('bot_api failed', { method, message: error.message, code: error.code });
      throw new HttpError('upstream_error', 'the bot platform rejected the call', { status: 502 });
    }

    // `{ok:false}` is an answer, not a transport failure: 200 with the reason,
    // exactly like Telegram, so bot code can branch on it.
    return ok(data, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins));
  return wrapped(request);
}

Deno.serve(handle);
