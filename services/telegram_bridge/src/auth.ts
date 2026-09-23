/**
 * The interactive link handshake.
 *
 * The app and the worker never share a socket: the app writes a sealed request
 * row, the worker claims it, feeds TDLib, and reports the next step back. Each
 * call therefore does *one* thing and returns, so a code the user enters five
 * minutes later is handled by the next claim — and a worker crash between steps
 * only costs the user a re-entry (the DB row expires on its own).
 *
 * Security rules this file lives by:
 *   • the phone number, code and password arrive only inside an AES-GCM envelope
 *     (`SEAL_KEY`), are decrypted here, in memory, and are never logged;
 *   • `bridge_link_progress()` clears the payload as soon as we have read it, so
 *     the ciphertext exists for exactly one hop;
 *   • an exported login token (operator opt-in, for worker failover) is sealed
 *     again before it is stored — it is a real credential, not a receipt.
 */

import type { Logger } from './logging.js';

import type { BridgeConfig } from './config.js';
import { aesKeyFromSecret, openEnvelope, sealEnvelope, type LinkEnvelopePayload } from './util/envelope.js';
import type { LinkClaim } from './supabase.js';
import { SupabaseBridge } from './supabase.js';
import { TdLibClient, TdLibError, type TdObject } from './tdlib.js';
import { isAbort, sleep } from './util/backoff.js';

export type LinkOutcome = {
  result: 'ready' | 'awaiting_user' | 'unlinked' | 'failed';
  step?: string;
  note?: string;
  error?: string;
};

export type LinkContext = {
  client: TdLibClient;
  db: SupabaseBridge;
  config: BridgeConfig;
  claim: LinkClaim;
  dataDir: string;
  log: Logger;
  onReady: () => Promise<void>;
};

type Step = 'awaiting_phone' | 'awaiting_code' | 'awaiting_password' | 'awaiting_qr' | 'done';

export async function completeLinkHandshake(ctx: LinkContext): Promise<LinkOutcome> {
  const { claim, client, db, log } = ctx;
  const key = ctx.config.sealKey ? aesKeyFromSecret(ctx.config.sealKey) : null;

  let payload: LinkEnvelopePayload = {};
  try {
    payload = openEnvelope(claim.payload, key);
  } catch (error) {
    const message = (error as Error).message;
    log.warn('link payload could not be opened', { error: message, request_id: claim.request_id });
    await progress(ctx, {
      status: 'failed',
      step: 'failed',
      error: `payload could not be decrypted (${message}). Re-enter your details.`,
      authState: 'needs_reauth',
    });
    return { result: 'failed', error: message };
  }

  if (claim.kind === 'unlink' || payload.reason === 'unlink') {
    return runUnlink(ctx);
  }

  try {
    await ensureParameters(ctx);
    const state = await authorizationState(client, 2_000);

    switch (state) {
      case 'ready':
        return finish(ctx);
      case 'wait_phone_number':
      case 'wait_registration': {
        if (state === 'wait_registration') {
          return await progress(ctx, {
            status: 'failed',
            step: 'failed',
            error:
              'that phone number is not registered on Telegram; Massanger links an existing account',
            authState: 'failed',
          });
        }
        if (!payload.phone) {
          return await askUser(ctx, 'awaiting_phone', 'Enter the phone number that owns this Telegram account.');
        }
        await client.request('setAuthenticationPhoneNumber', {
          phone_number: payload.phone,
          allow_flash_call: false,
          is_current_phone_number: false,
          allow_sms_call_hash: true,
        });
        const after = await authorizationState(client, 15_000, 'wait_phone_number');
        if (after === 'wait_code') return await askUser(ctx, 'awaiting_code', 'We sent you a 5-digit code.');
        if (after === 'wait_password') return await askUser(ctx, 'awaiting_password', 'This account has a 2FA password.');
        if (after === 'ready') return await finish(ctx);
        return await askUser(ctx, 'awaiting_code', `Telegram state: ${after}`);
      }
      case 'wait_code': {
        if (!payload.code) return await askUser(ctx, 'awaiting_code', 'Enter the code Telegram sent you.');
        try {
          await client.request('checkAuthenticationCode', { code: payload.code.replace(/\D/g, '') });
        } catch (error) {
          return await handleAuthError(ctx, error, 'awaiting_code');
        }
        const after = await authorizationState(client, 15_000, 'wait_code');
        if (after === 'wait_password') return await askUser(ctx, 'awaiting_password', 'Now the 2FA password.');
        if (after === 'ready') return await finish(ctx);
        return await askUser(ctx, 'awaiting_code', `Telegram state: ${after}`);
      }
      case 'wait_password': {
        if (!payload.password) {
          return await askUser(ctx, 'awaiting_password', `Hint: ${claim.profile?.username ?? 'your 2FA password'}`);
        }
        try {
          await client.request('checkAuthenticationPassword', { password: payload.password });
        } catch (error) {
          return await handleAuthError(ctx, error, 'awaiting_password');
        }
        const after = await authorizationState(client, 15_000, 'wait_password');
        if (after === 'ready') return await finish(ctx);
        return await askUser(ctx, 'awaiting_password', `Telegram state: ${after}`);
      }
      case 'wait_qr':
      case 'scan_qr':
      case 'wait_tcode':
        return await runQr(ctx);
      default:
        // `wait_phone_call`, `wait_tcode`, …: hand the decision back to the user
        // with TDLib's own state name so the UI can explain it.
        return await askUser(ctx, 'awaiting_code', `Telegram is waiting for: ${state}`);
    }
  } catch (error) {
    if (isAbort(error)) {
      return { result: 'failed', error: 'session is shutting down' };
    }
    return await handleAuthError(ctx, error, claim.step as Step | undefined);
  }
}

/**
 * TDLib is authoritative about which step it wants, and the JSON client only
 * tells us through updates. Reading the *last seen* update is what keeps this
 * resilient across TDLib versions (the state object moved a couple of times).
 */
/**
 * TDLib is authoritative about which step it wants, and it only says so through
 * updates, so "wait a moment and read the state again" beats guessing. The state
 * is `wait_phone` the instant the client starts, which is why that value does
 * not count as an answer yet.
 */
async function authorizationState(
  client: TdLibClient,
  waitMs: number,
  unchangedWhileWaiting?: string,
): Promise<string> {
  const deadline = Date.now() + waitMs;
  let state = client.authorizationState;
  while (Date.now() < deadline) {
    state = client.authorizationState;
    if (state !== 'unknown' && (!unchangedWhileWaiting || state !== unchangedWhileWaiting)) return state;
    await sleep(40);
  }
  return state;
}

const lastAuthorizationState = (client: TdLibClient): string => client.authorizationState;

async function ensureParameters(ctx: LinkContext): Promise<void> {
  const { client, config, dataDir, log } = ctx;
  if (client.closed) return;
  if (lastAuthorizationState(client) !== 'unknown') return;

  try {
    await client.request(
      'setTdlibParameters',
      {
        api_id: config.apiId,
        api_hash: config.apiHash,
        database_directory: dataDir,
        files_directory: `${dataDir}/files`,
        use_file_database: true,
        use_chat_info_database: true,
        use_message_database: true,
        use_secret_chats: config.useSecretChats,
        use_test_dc: config.useTestDc,
        system_language_code: config.systemLanguageCode,
        device_model: config.deviceModel,
        system_version: `${process.platform} ${process.arch}`,
        application_version: config.applicationVersion,
        use_storage_manager: true,
      },
      { timeoutMs: Math.max(20_000, config.requestTimeoutMs) },
    );
  } catch (error) {
    // A session that is already configured answers with an error; anything else
    // is worth surfacing, because it usually means a bad api_id/api_hash pair.
    const message = (error as Error).message;
    if (!/already been sent|PARAMETERS_INVALID|received setTdlibParameters/i.test(message)) {
      log.warn('setTdlibParameters failed', { error: message });
      throw error;
    }
  }
}

/** Completes the handshake: identity into `telegram_accounts`, request closed. */
async function finish(ctx: LinkContext): Promise<LinkOutcome> {
  const { client, db, claim, log } = ctx;
  const me = await client.request<TdObject>('getMe');

  let loginTokenEnc: string | null = null;
  if (ctx.config.exportLoginToken) {
    loginTokenEnc = await exportLoginToken(ctx);
  }

  await ctx.onReady();

  const phone = String(me.phone_number ?? '');
  const countryCode = /^\+(\d{1,3})/.exec(phone)?.[1] ?? null;

  await db.linkComplete({
    requestId: claim.request_id,
    tgUserId: String(me.id ?? claim.account.tg_user_id ?? ''),
    tgUsername: String(me.username ?? '') || null,
    displayName: [String(me.first_name ?? ''), String(me.last_name ?? '')].filter(Boolean).join(' ') || null,
    phoneCountryCode: countryCode,
    sessionRef: sessionRefFor(ctx),
    loginTokenEnc,
    apiId: ctx.config.apiId,
  });

  log.info('telegram account linked', {
    tg_user_id: String(me.id ?? ''),
    username: String(me.username ?? '') || null,
  });
  return { result: 'ready', step: 'done', note: 'Telegram account connected' };
}

async function runUnlink(ctx: LinkContext): Promise<LinkOutcome> {
  const { client, db, claim, log } = ctx;
  try {
    await client.request('logOut', {}, { timeoutMs: 10_000 });
  } catch (error) {
    log.warn('logOut failed; dropping the local session anyway', { error: (error as Error).message });
  }
  await db.linkProgress({
    requestId: claim.request_id,
    status: 'succeeded',
    step: 'done',
    note: 'Telegram account unlinked',
    authState: 'unlinked',
  });
  await db
    .setAccountState({ userId: claim.user_id, authState: 'unlinked', note: 'unlinked on request' })
    .catch(() => undefined);
  await db.failPendingSends(claim.user_id, 'telegram account was unlinked').catch(() => undefined);
  return { result: 'unlinked', step: 'done', note: 'Telegram account unlinked' };
}

/**
 * QR login. TDLib ≥1.8 exposes `requestQrCode` + `checkAuthenticationToken`; on
 * older builds the request fails with a 404 and we tell the user to use the SMS
 * code instead of pretending the flow exists.
 */
async function runQr(ctx: LinkContext): Promise<LinkOutcome> {
  const { client, config } = ctx;
  try {
    const response = await client.request<TdObject>('requestQrCode', {});
    const token = String(response.token ?? '');
    if (token.length === 0) {
      return await askUser(ctx, 'awaiting_qr', 'Telegram did not return a QR token.');
    }

    await ctx.db.linkProgress({
      requestId: ctx.claim.request_id,
      status: 'awaiting_user',
      step: 'awaiting_qr',
      qrCode: token,
      note: 'Scan this with Telegram, or enter the code instead.',
    });

    const deadline = Date.now() + Math.min(config.qrTimeoutSeconds, 120) * 1000;
    while (Date.now() < deadline) {
      const state = lastAuthorizationState(client);
      if (state === 'ready') return await finish(ctx);
      const scanned = await client
        .request('checkAuthenticationToken', { token })
        .then(() => true)
        .catch((error: Error) => {
          // Still unscanned is an error in TDLib's vocabulary, not a failure.
          if (/PENDING|NOT_FOUND_YET|not.*scanned|EXPIRED/i.test(error.message)) return false;
          throw error;
        });
      if (scanned) {
        const after = await authorizationState(client, 5_000);
        if (after === 'ready') return await finish(ctx);
        if (after === 'wait_password') return await askUser(ctx, 'awaiting_password', 'Now the 2FA password.');
      }
      await sleep(2_000);
    }
    client.notify('cancelAuthenticationToken', { token });
    return await askUser(ctx, 'awaiting_qr', 'the QR code expired');
  } catch (error) {
    const message = (error as Error).message;
    if (/not found|404|Unimplemented|not modelled/i.test(message)) {
      await ctx.db.linkProgress({
        requestId: ctx.claim.request_id,
        status: 'awaiting_user',
        step: 'awaiting_phone',
        note: 'QR login needs TDLib 1.8+; use the SMS code instead.',
        error: message.slice(0, 200),
      });
      return { result: 'awaiting_user', step: 'awaiting_phone', note: 'qr unavailable' };
    }
    return await handleAuthError(ctx, error, 'awaiting_qr');
  }
}

/** Optional operator feature: a sealed token another worker can resume with. */
async function exportLoginToken(ctx: LinkContext): Promise<string | null> {
  try {
    const exported = await ctx.client.request<TdObject>('exportLoginToken', { expires: 604_800 });
    const token = String(exported.token ?? '');
    if (token.length === 0) return null;
    const key = ctx.config.sealKey ? aesKeyFromSecret(ctx.config.sealKey) : null;
    if (!key) {
      ctx.log.warn('TELEGRAM_EXPORT_LOGIN_TOKEN needs SEAL_KEY; storing nothing instead');
      return null;
    }
    // sealEnvelope() returns an A256GCM object; the column is text, so the JSON
    // is stored compactly and re-opened by `resumeFromLoginToken`.
    return JSON.stringify(sealEnvelope({ access_token: token }, key));
  } catch (error) {
    ctx.log.debug('exportLoginToken failed (continuing without failover support)', {
      error: (error as Error).message,
    });
    return null;
  }
}

/** Used by the manager when a session has no local TDLib database. */
export async function resumeFromLoginToken(client: TdLibClient, sealed: string, sealKey: string): Promise<boolean> {
  try {
    const key = aesKeyFromSecret(sealKey);
    const payload = openEnvelope(JSON.parse(sealed) as never, key);
    const token = payload.access_token ?? payload.code;
    if (!token) return false;
    await client.request('importLoginToken', { token: String(token) });
    return true;
  } catch (error) {
    if (error instanceof Error && !isAbort(error)) return false;
    return false;
  }
}

async function askUser(ctx: LinkContext, step: Step, note: string): Promise<LinkOutcome> {
  await ctx.db.linkProgress({
    requestId: ctx.claim.request_id,
    status: 'awaiting_user',
    step,
    note,
    authState: AUTH_STATE_BY_STEP[step] ?? null,
    sessionRef: sessionRefFor(ctx),
  });
  return { result: 'awaiting_user', step, note };
}

const AUTH_STATE_BY_STEP: Partial<Record<Step, string>> = {
  awaiting_phone: 'awaiting_phone',
  awaiting_code: 'awaiting_code',
  awaiting_password: 'awaiting_password',
  awaiting_qr: 'awaiting_code',
};

async function progress(
  ctx: LinkContext,
  input: {
    status: 'queued' | 'claimed' | 'awaiting_user' | 'succeeded' | 'failed' | 'expired';
    step?: string;
    note?: string;
    error?: string;
    authState?: string | null;
  },
): Promise<LinkOutcome> {
  await ctx.db.linkProgress({
    requestId: ctx.claim.request_id,
    status: input.status,
    step: input.step ?? null,
    note: input.note ?? null,
    error: input.error ?? null,
    authState: input.authState ?? null,
    sessionRef: sessionRefFor(ctx),
  });
  return {
    result: input.status === 'failed' ? 'failed' : input.status === 'succeeded' ? 'ready' : 'awaiting_user',
    step: input.step,
    note: input.note,
    error: input.error,
  };
}

/**
 * Auth errors are user-facing text, so they are translated here once instead of
 * leaking `PHONE_CODE_INVALID` into the UI. Anything we cannot classify keeps
 * the raw message — a silent failure would be worse than an ugly one.
 */
async function handleAuthError(
  ctx: LinkContext,
  error: unknown,
  fallbackStep: Step | string | undefined,
): Promise<LinkOutcome> {
  const message = error instanceof Error ? error.message : String(error);
  const code = error instanceof TdLibError ? error.code : 0;
  const step = (typeof fallbackStep === 'string' && fallbackStep.startsWith('awaiting')
    ? fallbackStep
    : 'awaiting_code') as Step;
  const floodMatch = /FLOOD_WAIT_(\d{1,7})/i.exec(message);

  const friendly = (() => {
    if (/PHONE_CODE_EXPIRED/i.test(message)) return 'that code has expired; ask Telegram for a new one';
    if (/PHONE_CODE_INVALID|CODE_INVALID/i.test(message)) return 'that code is not correct';
    if (/PASSWORD_HASH_INVALID|PASSWORD_INVALID/i.test(message)) return 'the 2FA password is not correct';
    if (/PHONE_NUMBER_INVALID/i.test(message)) return 'that phone number is not valid';
    if (/PHONE_NUMBER_BANNED/i.test(message)) return 'that phone number is banned by Telegram';
    if (/SMS_CODE_TIMEOUT|FLUSH_TIME_TOO_SLOWLY/i.test(message)) return 'Telegram is rate-limiting codes; wait a minute';
    if (floodMatch) return `wait ${floodMatch[1]}s before trying again`;
    if (/SESSION_REVOKED|AUTH_KEY_UNREGISTERED/i.test(message)) return 'this Telegram session was revoked';
    if (/AUTH_KEY_INVALID/i.test(message)) return 'the stored session is not valid anymore';
    if (/NETWORK_(UNREACHABLE|MIGRATE|TARGET)/i.test(message)) return 'Telegram is unreachable right now';
    if (code >= 500) return 'Telegram had a server error; retrying shortly';
    return null;
  })();

  const retryable = /EXPIRED|INVALID/i.test(message) || code >= 500 || /FLOOD_WAIT/i.test(message);
  ctx.log.warn('telegram authentication failed', { error: message, code, retryable });

  return await progress(ctx, {
    status: retryable ? 'awaiting_user' : 'failed',
    step: retryable ? step : 'failed',
    note: friendly ?? message.slice(0, 240),
    error: message.slice(0, 480),
    authState: retryable ? null : 'failed',
  });
}

/** Names the TDLib directory so a rebuild of the pod reuses the same session. */
const sessionRefFor = (ctx: LinkContext): string =>
  ctx.claim.session_ref ?? ctx.claim.account.session_ref ?? `${ctx.config.workerId}:${ctx.claim.user_id.slice(0, 8)}`;
