/** Wire types shared with the `telegram-ingest` edge function. */

export type MessageKind = 'text' | 'image' | 'voice' | 'system';
export type DeliveryState = 'sending' | 'pending' | 'sent' | 'delivered' | 'read' | 'failed';
export type SyncDirection = 'both' | 'to_telegram' | 'from_telegram' | 'off';

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

/** Media block as stored in `public.messages.media`. */
export type MediaPayload = {
  bucket: 'images' | 'voice-notes' | 'avatars';
  path: string;
  mime?: string;
  size_bytes?: number;
  width?: number;
  height?: number;
  duration_ms?: number;
  /** 64 bars, 0–100 — the same array the recorder produces in the app. */
  waveform?: number[];
  tg_file_id?: string;
  remote_url?: string;
};

export type InboundEvent = {
  type: BridgeEventKind;
  owner_user_id: string;
  tg_chat_id: string;
  tg_chat_type?: 'private' | 'basic_group' | 'supergroup' | 'channel';
  tg_message_id?: string;
  tg_send_id?: string;
  dedupe_key: string;
  kind?: MessageKind;
  body?: string | null;
  media?: MediaPayload | null;
  sent_at?: string;
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
  request_id?: string;
  status?: string;
  step?: string;
  note?: string | null;
  auth_state?: string;
  qr_code?: string | null;
  worker_id?: string;
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

/** Telegram chat type → our mirror metadata. */
export const tdChatType = (chat: Record<string, unknown>): InboundEvent['tg_chat_type'] => {
  switch (chat['@type']) {
    case 'chatTypePrivate':
      return 'private';
    case 'chatTypeBasicGroup':
      return 'basic_group';
    case 'chatTypeSupergroup':
      return 'supergroup';
    case 'chatTypeSecret':
      return 'private';
    default:
      return undefined;
  }
};

export const dedupeKeyFor = (
  ownerUserId: string,
  tgChatId: string | number,
  type: BridgeEventKind,
  tgMessageId?: string | number | null,
): string => `${ownerUserId}:${tgChatId}:${type}:${tgMessageId ?? 'na'}`;
