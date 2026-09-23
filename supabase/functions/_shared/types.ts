/**
 * Shared vocabulary for every Massanger edge function.
 *
 * Responses are always envelopes, never bare payloads: a client can branch on
 * `ok` without sniffing status codes, and errors carry a stable `code` the Dart
 * layer maps to a typed failure (see apps/mobile/lib/core/errors).
 */

export type MessageKind = 'text' | 'image' | 'voice' | 'system';
export type DeliveryState = 'sending' | 'pending' | 'sent' | 'delivered' | 'read' | 'failed';
export type AccessState =
  | 'pending_verification'
  | 'active'
  | 'restricted'
  | 'banned'
  | 'deactivated';
export type TelegramAuthState =
  | 'unlinked'
  | 'awaiting_phone'
  | 'awaiting_code'
  | 'awaiting_password'
  | 'awaiting_registration'
  | 'syncing'
  | 'linked'
  | 'needs_reauth'
  | 'revoked'
  | 'failed';
export type SyncDirection = 'both' | 'to_telegram' | 'from_telegram' | 'off';

export type Ok<T> = { ok: true; data: T };
export type Err = { ok: false; error: { code: ErrorCode; message: string; retry_after_seconds?: number } };
export type Envelope<T> = Ok<T> | Err;

export type ErrorCode =
  | 'bad_request'
  | 'unauthorized'
  | 'forbidden'
  | 'not_found'
  | 'conflict'
  | 'payload_too_large'
  | 'rate_limited'
  | 'signature_invalid'
  | 'stale_request'
  | 'eligibility_pending'
  | 'eligibility_failed'
  | 'upstream_error'
  | 'misconfigured'
  | 'internal_error';

export const STATUS_BY_CODE: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  payload_too_large: 413,
  rate_limited: 429,
  signature_invalid: 401,
  stale_request: 400,
  eligibility_pending: 409,
  eligibility_failed: 403,
  upstream_error: 502,
  misconfigured: 500,
  internal_error: 500,
};

/** Thrown by helpers; the handler turns it into an Envelope. */
export class HttpError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly details?: Record<string, unknown>;
  readonly retryAfterSeconds?: number;

  constructor(
    code: ErrorCode,
    message: string,
    options: { details?: Record<string, unknown>; retryAfterSeconds?: number; status?: number } = {},
  ) {
    super(message);
    this.name = 'HttpError';
    this.code = code;
    this.status = options.status ?? STATUS_BY_CODE[code];
    this.details = options.details;
    this.retryAfterSeconds = options.retryAfterSeconds;
  }
}

// ---------------------------------------------------------------------------
// Bridge payloads (worker ⇄ edge)
// ---------------------------------------------------------------------------

export type BridgeEventKind =
  | 'message'
  | 'message_edit'
  | 'message_delete'
  | 'read'
  | 'chat'
  | 'peer'
  | 'state'
  | 'outbox_result'
  | 'link_progress'
  | 'unlink';

/** One normalized inbound Telegram event. */
export type InboundEvent = {
  type: BridgeEventKind;
  owner_user_id: string;
  tg_chat_id: string;
  tg_chat_type?: 'private' | 'basic_group' | 'supergroup' | 'channel';
  tg_message_id?: string;
  /** TDLib `sending_id`; equals the telegram_outbox row id for our own sends. */
  tg_send_id?: string;
  dedupe_key: string;
  kind?: MessageKind;
  body?: string | null;
  media?: Record<string, unknown> | null;
  sent_at?: string;
  /** True when the message was sent *by the linked account* (outgoing). */
  is_outgoing?: boolean;
  reply_to_tg_message_id?: string | null;
  title?: string | null;
  peer_user_id?: string | null;
  peer_first_name?: string | null;
  peer_last_name?: string | null;
  peer_username?: string | null;
  peer_avatar_url?: string | null;
  sender_peer_user_id?: string | null;
  sender_first_name?: string | null;
  sender_last_name?: string | null;
  sender_username?: string | null;
  sender_name?: string | null;
  sender_avatar_url?: string | null;
  sender_is_contact?: boolean;
  state?: DeliveryState;
  up_to_tg_message_id?: string | null;
  outbox_id?: string;
  error?: string | null;
  /** link/state events */
  request_id?: string;
  status?: string;
  step?: string;
  note?: string | null;
  auth_state?: TelegramAuthState;
  qr_code?: string | null;
};

export type InboundBatch = {
  worker_id: string;
  /** epoch seconds, also used for the signature window */
  ts: number;
  events: InboundEvent[];
};

export type InboundResult = {
  index: number;
  dedupe_key: string;
  status: 'processed' | 'duplicate' | 'skipped' | 'echo' | 'edited' | 'deleted' | 'error';
  message_id?: string;
  chat_id?: string;
  reason?: string;
  detail?: string;
};

/** Sealed credential envelope stored in telegram_link_requests.payload. */
export type CredentialEnvelope =
  | { alg: 'plain'; data: Record<string, string | boolean> }
  | { alg: 'A256GCM'; iv: string; ct: string; tag?: string };

export type LinkEnvelopePayload = {
  phone?: string;
  code?: string;
  password?: string;
  use_qr?: boolean;
  reason?: string;
};
