/**
 * The mapping layer is where a Telegram message becomes a Massanger message and
 * back, so its edge cases (long text, markdown, missing media, unsupported types)
 * are asserted here rather than discovered in production.
 */

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  TG_TEXT_LIMIT,
  decodeWaveform,
  mapIncomingMessage,
  parseMarkdown,
  planOutbound,
  renderMarkdown,
  sendOptions,
  sendingIdFor,
  splitText,
} from '../src/render.js';
import { tdChatAction } from '../src/session.js';
import type { OutboxRow } from '../src/supabase.js';
import type { TdObject } from '../src/tdlib.js';

const row = (overrides: Partial<OutboxRow>): OutboxRow => ({
  outbox_id: 1,
  message_id: 'm',
  owner_user_id: 'o',
  chat_id: 'c',
  tg_chat_id: '1',
  kind: 'text',
  payload: {},
  attempts: 0,
  session_ref: null,
  tg_user_id: null,
  ...overrides,
});

describe('splitText', () => {
  it('leaves short messages alone', () => {
    assert.deepEqual(splitText('hello'), ['hello']);
    assert.deepEqual(splitText(''), ['']);
  });

  it('cuts long messages at a word boundary under the limit', () => {
    const words = Array.from({ length: 2_000 }, (_, index) => `word${index}`);
    const chunks = splitText(words.join(' '));
    assert.ok(chunks.length >= 2);
    for (const chunk of chunks) assert.ok(chunk.length <= TG_TEXT_LIMIT, `chunk was ${chunk.length}`);
    assert.equal(chunks.join(' ').split(' ').length, words.length, 'no word was lost');
    assert.ok(!/\s$/.test(chunks[0] ?? ''), 'chunks are trimmed');
  });

  it('prefers a newline near the limit', () => {
    const head = 'a'.repeat(TG_TEXT_LIMIT - 10);
    const chunks = splitText(`${head}\n\n${'b'.repeat(500)}`);
    assert.equal(chunks[0], head);
  });

  it('splits mid-word when a single token is longer than the limit', () => {
    const chunks = splitText('x'.repeat(TG_TEXT_LIMIT * 2 + 5));
    assert.equal(chunks.length, 3);
    assert.equal(chunks.join('').length, TG_TEXT_LIMIT * 2 + 5);
  });
});

describe('markdown', () => {
  it('converts composer markdown into TDLib entities with UTF-16 offsets', () => {
    const parsed = parseMarkdown('**bold** then `code`');
    assert.equal(parsed.text, 'bold then code');
    assert.deepEqual(
      parsed.entities.map((entity) => [entity['@type'], entity.offset, entity.length]),
      [
        ['messageEntityBold', 0, 4],
        ['messageEntityCode', 10, 4],
      ],
    );
  });

  it('handles links and leaves unmatched markers as literal text', () => {
    const parsed = parseMarkdown('see [docs](https://example.com/a) now');
    assert.equal(parsed.text, 'see docs now');
    assert.deepEqual(parsed.entities[0], {
      '@type': 'messageEntityTextUrl',
      offset: 4,
      length: 4,
      url: 'https://example.com/a',
    });
    // Unpaired markers are literal text, never stripped: a user typing
    // "2 * 3" must not lose characters.
    assert.deepEqual(parseMarkdown('2 * 3 != ** 4'), { text: '2 * 3 != ** 4', entities: [] });
  });

  it('counts offsets in code units when an emoji precedes the styling', () => {
    const parsed = parseMarkdown('👍 **ok**');
    assert.equal(parsed.text, '👍 ok');
    assert.equal(parsed.entities[0]?.offset, 3, '👍 is two UTF-16 units plus the space');
  });

  it('round-trips through renderMarkdown', () => {
    const entities: TdObject[] = [
      { '@type': 'messageEntityBold', offset: 0, length: 3 },
      { '@type': 'messageEntityItalic', offset: 4, length: 3 },
    ];
    const rendered = renderMarkdown('abc def ghi', entities);
    assert.equal(rendered, '**abc** __def__ ghi');
    assert.equal(parseMarkdown(rendered).text, 'abc def ghi');
  });

  it('turns text links into markdown', () => {
    const rendered = renderMarkdown('massanger', [{ '@type': 'messageEntityTextUrl', offset: 0, length: 9, url: 'https://m.dev' }]);
    assert.equal(rendered, '[massanger](https://m.dev)');
  });

  it('ignores out-of-range and unknown entities', () => {
    assert.equal(renderMarkdown('short', [{ '@type': 'messageEntityBold', offset: 99, length: 5 }]), 'short');
    assert.equal(renderMarkdown('short', [{ '@type': 'messageEntitySpoilerTime', offset: 0, length: 2 }]), 'short');
  });
});

describe('planOutbound', () => {
  it('renders plain text as one inputMessageText', () => {
    const plan = planOutbound(row({ kind: 'text', payload: { text: 'hi **there**' } }), null);
    assert.equal(plan.sends.length, 1);
    assert.equal(plan.degraded, false);
    const content = plan.sends[0]?.content as TdObject;
    assert.equal(content['@type'], 'inputMessageText');
    assert.equal((content.text as TdObject).text, 'hi there');
    assert.equal(((content.text as TdObject).entities as TdObject[])[0]?.['@type'], 'messageEntityBold');
  });

  it('never mirrors system messages', () => {
    const plan = planOutbound(row({ kind: 'system', payload: { text: 'user joined' } }), null);
    assert.equal(plan.sends.length, 0);
    assert.match(plan.note ?? '', /never mirrored/);
  });

  it('splits a long message into several sends, clearing the draft on the last', () => {
    const plan = planOutbound(row({ kind: 'text', payload: { text: 'y'.repeat(TG_TEXT_LIMIT * 2 + 10) } }), null);
    assert.equal(plan.sends.length, 3);
    assert.equal(plan.sends[0]?.clearDraft, false, 'only the final chunk clears the draft');
    assert.equal(plan.sends.at(-1)?.clearDraft, true);
  });

  it('builds a voice note with duration and a normalised waveform', () => {
    const plan = planOutbound(
      row({ kind: 'voice', payload: { media: { duration_ms: 6_400, waveform: [10, 20, 30] } } }),
      { localPath: '/tmp/v.ogg', mime: 'audio/ogg', durationMs: 6_400, waveform: [10, 20, 30] },
    );
    const content = plan.sends[0]?.content as TdObject;
    assert.equal(content['@type'], 'inputMessageVoiceNote');
    const voice = content.voice_note as TdObject;
    assert.equal(voice.duration, 6);
    assert.equal(voice.mime_type, 'audio/ogg');
    const bars = decodeWaveform(voice.waveform);
    assert.ok(bars && bars.length === 64, 'the client waveform is stretched to 64 bars');
    assert.ok(bars.every((value) => value >= 1 && value <= 100));
  });

  it('caps a voice note at Telegram’s maximum length', () => {
    const plan = planOutbound(row({ kind: 'voice' }), { localPath: '/tmp/v.ogg', mime: 'audio/ogg', durationMs: 900_000 });
    assert.equal(((plan.sends[0]?.content as TdObject).voice_note as TdObject).duration, 300);
  });

  it('sends a photo with the caption attached, not as a second bubble', () => {
    const plan = planOutbound(
      row({ kind: 'image', payload: { text: 'look at this', media: { caption: 'from the trip' } } }),
      { localPath: '/tmp/p.jpg', mime: 'image/jpeg', width: 1_600, height: 900 },
    );
    const content = plan.sends[0]?.content as TdObject;
    assert.equal(content['@type'], 'inputMessagePhoto');
    assert.equal((content.photo as TdObject).path, '/tmp/p.jpg');
    assert.equal(content.sticker_width, 1_600);
    assert.equal((content.caption as TdObject).text, 'from the trip');
  });

  it('degrades to a readable text bubble when media cannot be fetched', () => {
    const plan = planOutbound(row({ kind: 'image', payload: { media: { path: 'images/x.jpg' } } }), null);
    assert.equal(plan.degraded, true);
    const content = plan.sends[0]?.content as TdObject;
    assert.equal((content.text as TdObject).text, '[Attachment is not available on the bridge]');
    assert.match(plan.note ?? '', /could not be fetched/);
  });

  it('carries the reply target on the first chunk only', () => {
    const plan = planOutbound(row({ kind: 'text', payload: { text: 'answer' } }), null, {
      replyToMessageId: 9001,
    });
    assert.equal(plan.sends[0]?.replyToMessageId, '9001');
  });
});

describe('mapIncomingMessage', () => {
  const message = (content: TdObject, extra: Partial<TdObject> = {}): TdObject => ({
    '@type': 'message',
    id: 500,
    chat_id: 1,
    date: 1_700_000_000,
    content,
    ...extra,
  });

  it('maps text with entities into markdown', () => {
    const mapped = mapIncomingMessage({
      message: message({
        '@type': 'messageText',
        text: {
          '@type': 'formattedText',
          text: 'ping',
          entities: [{ '@type': 'messageEntityBold', offset: 0, length: 4 }],
        },
      }),
    });
    assert.equal(mapped.kind, 'text');
    assert.equal(mapped.body, '**ping**');
  });

  it('keeps a caption and attaches the uploaded object for photos', () => {
    const uploaded = new Map([[77, { bucket: 'images' as const, path: 'o/tg/1-500.jpg', mime: 'image/jpeg', size: 20_000 }]]);
    const mapped = mapIncomingMessage({
      message: message({
        '@type': 'messagePhoto',
        photo: {
          '@type': 'photo',
          sizes: [{ '@type': 'photoSize', photo_size: { '@type': 'file', id: 77 }, width: 800, height: 600 }],
          caption: { '@type': 'formattedText', text: 'sunrise', entities: [] },
        },
      }),
      uploaded,
    });
    assert.equal(mapped.kind, 'image');
    assert.equal(mapped.body, 'sunrise');
    assert.equal(mapped.media?.path, 'o/tg/1-500.jpg');
    assert.equal(mapped.media?.width, 800);
  });

  it('mirrors an undownloaded photo as text so the thread stays readable', () => {
    const mapped = mapIncomingMessage({
      message: message({
        '@type': 'messagePhoto',
        photo: { '@type': 'photo', sizes: [], caption: { '@type': 'formattedText', text: '', entities: [] } },
      }),
    });
    assert.equal(mapped.body, '[Photo]');
    assert.equal(mapped.skip, false, 'a photo we chose not to download is still a message');
    assert.match(mapped.reason ?? '', /not downloaded|no downloadable/);
  });

  it('maps a voice note including the decoded waveform', () => {
    const uploaded = new Map([[9, { bucket: 'voice-notes' as const, path: 'o/tg/1-500.ogg', mime: 'audio/ogg', size: 900 }]]);
    const mapped = mapIncomingMessage({
      message: message({
        '@type': 'messageVoiceNote',
        voice_note: {
          '@type': 'voiceNote',
          duration: 4,
          waveform: Buffer.from([1, 2, 3]).toString('base64'),
          voice: { '@type': 'file', id: 9 },
        },
      }),
      uploaded,
    });
    assert.equal(mapped.kind, 'voice');
    assert.equal(mapped.media?.duration_ms, 4_000);
    assert.deepEqual(mapped.media?.waveform, [1, 2, 3]);
    assert.equal(mapped.body, null);
  });

  it('turns a document voice note into a voice bubble', () => {
    const uploaded = new Map([[5, { bucket: 'voice-notes' as const, path: 'o/tg/1-500.ogg', mime: 'audio/opus', size: 500 }]]);
    const mapped = mapIncomingMessage({
      message: message({
        '@type': 'messageDocument',
        document: { '@type': 'document', file_name: 'voice.opus', mime_type: 'audio/opus', document: { '@type': 'file', id: 5 }, size: 500 },
      }),
      uploaded,
    });
    assert.equal(mapped.kind, 'voice');
  });

  it('labels every other Telegram type instead of dropping the message', () => {
    for (const [type, expected] of [
      ['messageSticker', '[Sticker]'],
      ['messageLocation', '[Location]'],
      ['messageVideoNote', '[Video message]'],
      ['messageWeirdNewThing', '[Unsupported Telegram message: weird new thing]'],
    ] as const) {
      const mapped = mapIncomingMessage({ message: message({ '@type': type }) });
      assert.equal(mapped.body, expected, type);
      assert.equal(mapped.skip, false);
    }
  });

  it('renders service messages as readable system lines', () => {
    const mapped = mapIncomingMessage({
      message: message({ '@type': 'messageChatAddMembers', member_user_ids: [1, 2] }),
    });
    assert.equal(mapped.kind, 'system');
    assert.equal(mapped.body, 'members were added');
  });
});

describe('sending id correlation', () => {
  it('uses the outbox id, which is what bridge_claim_outbox stamps on the message', () => {
    assert.equal(sendingIdFor(41), 41);
    assert.equal((sendOptions(41) as TdObject).sending_id, 41);
    assert.throws(() => sendingIdFor(0), /cannot be used as a TDLib sending_id/);
    assert.throws(() => sendingIdFor(Number.MAX_SAFE_INTEGER + 1), /cannot be used/);
  });

  it('keeps the TDLib payload shape stable', () => {
    const options = sendOptions(7, true);
    assert.equal(options['@type'], 'messageSendingOptions');
    assert.equal(options.priority, 'HIGH');
    assert.equal(options.from_background, true);
  });
});

describe('chat actions', () => {
  it('maps stored actions back to TDLib', () => {
    assert.deepEqual(tdChatAction('typing'), { '@type': 'chatActionTyping' });
    assert.deepEqual(tdChatAction('upload_photo'), { '@type': 'chatActionUploadPhoto' });
    assert.deepEqual(tdChatAction('unknown-thing'), { '@type': 'chatActionTyping' });
  });
});
