/**
 * Message mapping, both directions.
 *
 * Outbound (app → Telegram) renders a `telegram_outbox` row into a TDLib
 * `InputMessageContent`; inbound (Telegram → app) renders a TDLib `message`
 * into the `bridge_ingest_message` event body. Both halves live in one file on
 * purpose: the mapping *is* the product surface, and the two directions have to
 * agree on markdown, voice-note fields and unsupported-type placeholders.
 */

import type { InboundEvent, MessageKind } from './protocol.js';
import type { OutboxRow } from './supabase.js';
import type { TdObject } from './tdlib.js';
import {
  IMAGE_MIMES,
  clampDurationMs,
  isImageMime,
  isVoiceMime,
  normalizeWaveform,
  waveformToBase64,
} from './media.js';

export const TG_TEXT_LIMIT = 4096;

/**
 * Long messages are split rather than rejected, at a word boundary when one
 * exists (then a newline near the limit, then mid-word as a last resort).
 */
export function splitText(text: string, limit = TG_TEXT_LIMIT): string[] {
  const clean = text.replace(/\r\n/g, '\n');
  if (clean.length <= limit) return [clean];
  const chunks: string[] = [];
  let rest = clean;
  while (rest.length > limit) {
    let cut = rest.lastIndexOf(' ', limit);
    const newline = rest.lastIndexOf('\n', limit);
    if (newline > limit * 0.6) cut = newline + 1;
    if (cut <= 0) cut = limit;
    chunks.push(rest.slice(0, cut).trimEnd());
    rest = rest.slice(cut).replace(/^[ \n]+/, '');
  }
  if (rest.length > 0) chunks.push(rest);
  return chunks.filter((chunk) => chunk.length > 0);
}

// ── markdown ⇄ MessageEntity ────────────────────────────────────────────────

const ENTITY_BY_KIND = {
  bold: 'messageEntityBold',
  italic: 'messageEntityItalic',
  code: 'messageEntityCode',
  strike: 'messageEntityStrikethrough',
  spoiler: 'messageEntitySpoiler',
} as const;

type MarkerKind = keyof typeof ENTITY_BY_KIND;

/**
 * The markdown subset the Flutter composer emits. Offsets are UTF-16 code units
 * because that is what TDLib counts.
 */
export function parseMarkdown(text: string): { text: string; entities: TdObject[] } {
  const entities: TdObject[] = [];
  let out = '';
  let index = 0;

  const markers: Array<[MarkerKind, string]> = [
    ['bold', '**'],
    ['strike', '~~'],
    ['spoiler', '||'],
    ['italic', '__'],
    ['code', '`'],
  ];

  while (index < text.length) {
    let consumed = false;
    for (const [kind, marker] of markers) {
      if (!text.startsWith(marker, index)) continue;
      const close = text.indexOf(marker, index + marker.length);
      if (close < 0) continue;
      const inner = text.slice(index + marker.length, close);
      if (inner.length === 0 || inner.includes('\n') && marker === '`') continue;
      const offset = out.length;
      out += inner;
      entities.push({ '@type': ENTITY_BY_KIND[kind], offset, length: inner.length });
      index = close + marker.length;
      consumed = true;
      break;
    }
    if (consumed) continue;

    const link = /^\[([^\]\n]{1,256})\]\((https?:\/\/[^\s)]{1,2000})\)/.exec(text.slice(index));
    if (link?.[1] && link[2]) {
      const offset = out.length;
      out += link[1];
      entities.push({ '@type': 'messageEntityTextUrl', offset, length: link[1].length, url: link[2] });
      index += link[0].length;
      continue;
    }

    out += text[index];
    index += 1;
  }

  return { text: out, entities };
}

/** Inverse: Telegram entities → the markdown the app renders. */
export function renderMarkdown(text: string, entities: TdObject[] | undefined): string {
  const list = (entities ?? []).filter(
    (entity) => Number.isFinite(Number(entity.offset)) && Number.isFinite(Number(entity.length)),
  );
  if (list.length === 0) return text;

  const markers: Record<string, readonly [string, string] | null> = {
    messageEntityBold: ['**', '**'],
    messageEntityItalic: ['__', '__'],
    messageEntityStrikethrough: ['~~', '~~'],
    messageEntitySpoiler: ['||', '||'],
    messageEntityCode: ['`', '`'],
    messageEntityPre: ['```', '```'],
    messageEntityBlockquote: ['> ', ''],
    messageEntityTextUrl: null,
    messageEntityUrl: null,
    messageEntityMention: null,
  };

  // Right-to-left, so earlier offsets stay valid while we splice.
  let out = text;
  for (const entity of [...list].sort((a, b) => Number(b.offset) - Number(a.offset))) {
    const start = Number(entity.offset);
    const end = Math.min(out.length, start + Number(entity.length));
    if (start < 0 || end <= start) continue;
    const inner = out.slice(start, end);
    if (entity['@type'] === 'messageEntityTextUrl') {
      out = `${out.slice(0, start)}[${inner}](${String(entity.url ?? '')})${out.slice(end)}`;
      continue;
    }
    const marker = markers[entity['@type']];
    if (!marker) continue;
    out = `${out.slice(0, start)}${marker[0]}${inner}${marker[1]}${out.slice(end)}`;
  }
  return out;
}

// ── outbound ────────────────────────────────────────────────────────────────

export type ResolvedMedia = {
  localPath: string;
  mime: string;
  sizeBytes?: number;
  width?: number;
  height?: number;
  durationMs?: number;
  waveform?: number[];
};

export type OutboundSend = {
  /** TDLib `InputMessageContent`. */
  content: TdObject;
  /** Telegram message the first chunk replies to. */
  replyToMessageId?: string | null;
  /** Only the last chunk clears the draft (it is a per-send flag, not per-content). */
  clearDraft?: boolean;
};

export type OutboundPlan = {
  /** One entry per Telegram message; long texts become several. */
  sends: OutboundSend[];
  /** Media could not be rendered, so a placeholder text bubble goes instead. */
  degraded: boolean;
  note?: string;
};

const formatted = (text: string): TdObject => {
  const parsed = parseMarkdown(text);
  return { '@type': 'formattedText', text: parsed.text, entities: parsed.entities };
};

export function planOutbound(
  row: Pick<OutboxRow, 'kind' | 'payload'>,
  media: ResolvedMedia | null,
  options: { replyToMessageId?: string | number | null } = {},
): OutboundPlan {
  if (row.kind === 'system') {
    return { sends: [], degraded: false, note: 'system messages are never mirrored to Telegram' };
  }

  const text = typeof row.payload?.text === 'string' ? row.payload.text : '';
  const caption = typeof row.payload?.media?.caption === 'string' ? row.payload.media.caption : '';
  const mime = media?.mime ?? String(row.payload?.media?.mime ?? '');
  const replyTo = options.replyToMessageId ? String(options.replyToMessageId) : null;
  const send = (content: TdObject, last: boolean): OutboundSend => ({
    content,
    ...(replyTo ? { replyToMessageId: replyTo } : {}),
    clearDraft: last,
  });

  if (media && isVoiceMime(mime)) {
    const durationMs = clampDurationMs(media.durationMs ?? Number(row.payload?.media?.duration_ms ?? 0));
    const waveform = waveformToBase64(normalizeWaveform(media.waveform ?? row.payload?.media?.waveform));
    const content: TdObject = {
      '@type': 'inputMessageVoiceNote',
      voice_note: {
        '@type': 'voiceNote',
        duration: Math.max(1, Math.round(durationMs / 1000)),
        waveform,
        mime_type: mime,
      },
      caption: caption.length > 0 ? formatted(caption) : { '@type': 'formattedText', text: '', entities: [] },
    };
    return { sends: [send(content, true)], degraded: false };
  }

  if (media && IMAGE_MIMES.has(mime)) {
    const content: TdObject = {
      '@type': 'inputMessagePhoto',
      photo: { '@type': 'inputFileLocal', path: media.localPath },
      caption: caption.length > 0 ? formatted(caption) : { '@type': 'formattedText', text: '', entities: [] },
      sticker_width: media.width ?? Number(row.payload?.media?.width ?? 0),
      sticker_height: media.height ?? Number(row.payload?.media?.height ?? 0),
    };
    return { sends: [send(content, true)], degraded: false };
  }

  if (media) {
    const content: TdObject = {
      '@type': 'inputMessageDocument',
      document: { '@type': 'inputFileLocal', path: media.localPath },
      caption: caption.length > 0 ? formatted(caption) : { '@type': 'formattedText', text: '', entities: [] },
      disable_content_type_detection: true,
    };
    // A photo/voice mime we did not recognise still travels as a file: it is
    // better to deliver the bytes than to drop them.
    return {
      sends: [send(content, true)],
      degraded: false,
      note: isImageMime(mime) || isVoiceMime(mime) ? `sent as document (unusual mime ${mime})` : undefined,
    };
  }

  if (row.kind !== 'text') {
    return {
      sends: [
        send(
          {
            '@type': 'inputMessageText',
            text: formatted(text || '[Attachment is not available on the bridge]'),
            link_preview_options: { '@type': 'linkPreviewOptions', is_disabled: false },
          },
          true,
        ),
      ],
      degraded: true,
      note: `media ${String(row.payload?.media?.path ?? '(none)')} could not be fetched`,
    };
  }

  const parsed = parseMarkdown(text || '[empty message]');
  const chunks = splitText(parsed.text);
  return {
    sends: chunks.map((chunk, index) =>
      send(
        {
          '@type': 'inputMessageText',
          text: {
            '@type': 'formattedText',
            text: chunk,
            // Entities address the whole string, so only the first chunk keeps them.
            entities: index === 0 ? parsed.entities : [],
          },
          link_preview_options: { '@type': 'linkPreviewOptions', is_disabled: false },
        },
        index === chunks.length - 1,
      ),
    ),
    degraded: false,
  };
}

// ── inbound ─────────────────────────────────────────────────────────────────

export type UploadedMedia = {
  bucket: 'images' | 'voice-notes';
  path: string;
  mime: string;
  size: number;
};

export type InboundMessageInput = {
  message: TdObject;
  /** Media the session already downloaded and pushed to Storage, by TDLib file id. */
  uploaded?: Map<number, UploadedMedia>;
};

export type MappedMessage = {
  kind: MessageKind;
  body: string | null;
  media: InboundEvent['media'];
  /** True when the message should not create a row at all (e.g. our own echo). */
  skip: boolean;
  reason?: string;
};

const SERVICE_MESSAGE_TYPES = new Set([
  'messageChatAddMembers',
  'messageChatJoinByLink',
  'messageChatDeleteMember',
  'messageChatChangeTitle',
  'messageChatChangePhoto',
  'messageChatSetTheme',
  'messageChatSetMessageAutoDeleteTime',
  'messagePinMessage',
  'messageUnpinMessage',
  'messageScreenshotTaken',
  'messageChatSetTTL',
  'messageContactRegistered',
  'messageUserIsActive',
  'messageBasicGroupChatCreate',
  'messageSupplementaryChatCreate',
  'messageChatDeletePhoto',
]);

/**
 * Nested TDLib objects are always indexable here: an absent one reads back as a
 * sentinel with `@type: 'none'` (not a TDLib type), so every field access below
 * yields `undefined` instead of throwing.
 */
const asObject = (value: unknown): TdObject =>
  typeof value === 'object' && value !== null ? (value as TdObject) : { '@type': 'none' };

const messageFileId = (value: unknown): number => {
  const file = asObject(value);
  const id = Number(file?.id ?? NaN);
  return Number.isFinite(id) ? id : NaN;
};

/** Maps a TDLib `message` onto the columns `bridge_ingest_message` expects. */
export function mapIncomingMessage(input: InboundMessageInput): MappedMessage {
  const content = asObject(input.message.content) ?? { '@type': 'unknown' };
  const type = String(content['@type'] ?? 'unknown');
  const isOutgoing = input.message.is_outgoing === true;

  if (SERVICE_MESSAGE_TYPES.has(type)) {
    return { kind: 'system', body: serviceText(content), media: null, skip: false };
  }

  switch (type) {
    case 'messageText': {
      const text = asObject(content.text);
      const body = renderMarkdown(String(text?.text ?? ''), (text?.entities as TdObject[] | undefined) ?? []);
      return { kind: 'text', body: body.length > 0 ? body : null, media: null, skip: false };
    }

    case 'messagePhoto': {
      const photo = asObject(content.photo);
      const captionSource = asObject(photo.caption);
      const caption = renderMarkdown(
        String(captionSource?.text ?? ''),
        (captionSource?.entities as TdObject[] | undefined) ?? [],
      );
      const biggest = pickBiggestSize((photo.sizes as TdObject[] | undefined) ?? []);
      const uploaded = biggest ? input.uploaded?.get(biggest.fileId) : undefined;
      if (!uploaded) {
        // Still mirrored: the caption and a placeholder keep the thread readable.
        return {
          kind: 'image',
          body: caption.length > 0 ? caption : isOutgoing ? '[Photo sent from Telegram]' : '[Photo]',
          media: null,
          skip: false,
          reason: biggest ? 'photo was not downloaded (size or policy)' : 'no downloadable photo size',
        };
      }
      return {
        kind: 'image',
        body: caption.length > 0 ? caption : null,
        media: {
          bucket: uploaded.bucket,
          path: uploaded.path,
          mime: uploaded.mime,
          size_bytes: uploaded.size,
          width: biggest?.width || undefined,
          height: biggest?.height || undefined,
        },
        skip: false,
      };
    }

    case 'messageVoiceNote': {
      const voice = asObject(content.voice_note);
      const fileId = messageFileId(voice.voice);
      const uploaded = Number.isFinite(fileId) ? input.uploaded?.get(fileId) : undefined;
      const seconds = Number(voice.duration ?? 0);
      if (!uploaded) {
        return {
          kind: 'voice',
          body: '[Voice message]',
          media: null,
          skip: false,
          reason: 'voice note was not downloaded (auto_download_voice is off or the file is unavailable)',
        };
      }
      return {
        kind: 'voice',
        body: null,
        media: {
          bucket: uploaded.bucket,
          path: uploaded.path,
          mime: uploaded.mime,
          size_bytes: uploaded.size,
          duration_ms: seconds > 0 ? Math.round(seconds * 1000) : undefined,
          waveform: decodeWaveform(voice.waveform),
          tg_file_id: Number.isFinite(fileId) ? String(fileId) : undefined,
        },
        skip: false,
      };
    }

    case 'messageDocument': {
      const document = asObject(content.document);
      const name = String(document.file_name ?? 'file');
      const mime = String(document.mime_type ?? '');
      const captionSource = asObject(content.caption);
      const caption = renderMarkdown(String(captionSource?.text ?? ''), (captionSource?.entities as TdObject[]) ?? []);
      const fileId = messageFileId(document.document ?? document);
      const uploaded = Number.isFinite(fileId) ? input.uploaded?.get(fileId) : undefined;

      // Telegram delivers some voice notes (and Telegram Desktop's "audio") as
      // documents; anything Opus-looking becomes a voice note in Massanger.
      if (uploaded && isVoiceMime(mime)) {
        return {
          kind: 'voice',
          body: null,
          media: {
            bucket: uploaded.bucket,
            path: uploaded.path,
            mime: uploaded.mime,
            size_bytes: uploaded.size,
          },
          skip: false,
        };
      }
      return {
        kind: 'text',
        body: `[File: ${name} (${uploaded?.size ?? Number(document.size ?? 0)} bytes)]${caption ? `\n${caption}` : ''}`,
        media: null,
        skip: false,
      };
    }

    case 'messageVideo':
    case 'messageVideoNote':
    case 'messageAudio':
    case 'messageAnimation':
      return {
        kind: 'text',
        body: `[${
          { messageVideo: 'Video', messageVideoNote: 'Video message', messageAudio: 'Audio', messageAnimation: 'GIF' }[
            type
          ] ?? 'Media'
        }]`,
        media: null,
        skip: false,
      };

    case 'messageSticker':
      return { kind: 'text', body: '[Sticker]', media: null, skip: false };

    case 'messageContact': {
      const contact = asObject(content.contact);
      const name = `${String(contact.first_name ?? '')} ${String(contact.last_name ?? '')}`.trim();
      return {
        kind: 'text',
        body: `[Contact: ${name || String(contact.phone_number ?? 'unknown')}]`,
        media: null,
        skip: false,
      };
    }

    case 'messageLocation':
      return { kind: 'text', body: '[Location]', media: null, skip: false };

    case 'messagePoll': {
      const poll = asObject(content.poll);
      return { kind: 'text', body: `[Poll] ${String(poll.question ?? '').trim()}`.trim(), media: null, skip: false };
    }

    default:
      return {
        kind: 'text',
        body: `[Unsupported Telegram message: ${humanize(type)}]`,
        media: null,
        skip: false,
      };
  }
}

const humanize = (type: string): string =>
  type
    .replace(/^message/, '')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .trim();

function serviceText(content: TdObject): string {
  switch (content['@type']) {
    case 'messageChatAddMembers':
      return 'members were added';
    case 'messageChatJoinByLink':
      return 'someone joined via an invite link';
    case 'messageChatDeleteMember':
      return 'a member left';
    case 'messageChatChangeTitle':
      return `the group title is now “${String(content.title ?? '')}”`;
    case 'messageChatChangePhoto':
      return 'the group photo changed';
    case 'messageChatDeletePhoto':
      return 'the group photo was removed';
    case 'messagePinMessage':
      return 'pinned a message';
    case 'messageUnpinMessage':
      return 'unpinned a message';
    case 'messageScreenshotTaken':
      return 'took a screenshot';
    case 'messageBasicGroupChatCreate':
      return 'the group was created';
    default:
      return humanize(String(content['@type'] ?? 'service'));
  }
}

function pickBiggestSize(sizes: TdObject[]): { fileId: number; width: number; height: number } | null {
  let best: { fileId: number; width: number; height: number } | null = null;
  for (const size of sizes) {
    const photoSize = asObject(size.photo_size);
    const fileId = Number(photoSize?.id ?? NaN);
    if (!Number.isFinite(fileId) || fileId <= 0) continue;
    const candidate = {
      fileId,
      width: Number(size.width ?? 0),
      height: Number(size.height ?? 0),
    };
    if (!best || candidate.width * candidate.height > best.width * best.height) best = candidate;
  }
  return best;
}

/** TDLib sends the 51-bar visualisation as base64 bytes, each 0–100. */
export function decodeWaveform(encoded: unknown): number[] | undefined {
  if (typeof encoded !== 'string' || encoded.length === 0) return undefined;
  const bytes = Buffer.from(encoded, 'base64');
  if (bytes.byteLength === 0) return undefined;
  return Array.from(bytes, (value) => Math.max(0, Math.min(100, value)));
}

/**
 * `sendMessage` options. `sending_id` is how a later failure (the
 * `messageSendingStateFailed` state, or `updateMessageSendAcknowledged`) is
 * attributed to the right outbox row.
 */
export const sendOptions = (outboxId: number, highPriority = false): TdObject => ({
  '@type': 'messageSendingOptions',
  sending_id: sendingIdFor(outboxId),
  disable_notification: false,
  from_background: true,
  allow_sending_without_reply: true,
  priority: highPriority ? 'HIGH' : 'DEFAULT',
});

/**
 * `bridge_claim_outbox` stamps `messages.tg_send_id` with the outbox id, so the
 * outbox id *is* the correlation token in both directions and no mapping table
 * is needed. TDLib wants an int53; outbox ids are small bigint sequence values.
 */
export function sendingIdFor(outboxId: number): number {
  if (!Number.isSafeInteger(outboxId) || outboxId <= 0) {
    throw new Error(`outbox id ${outboxId} cannot be used as a TDLib sending_id`);
  }
  return outboxId;
}

export const sendingIdFromMessage = (message: TdObject): number | null => {
  const state = typeof message.sending_state === 'object' && message.sending_state !== null
    ? (message.sending_state as TdObject)
    : null;
  const raw = state?.sending_id ?? state?.local_id ?? message.sending_id;
  if (raw === undefined || raw === null) return null;
  const value = Number(raw);
  return Number.isSafeInteger(value) && value > 0 ? value : null;
};
