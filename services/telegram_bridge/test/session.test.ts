/**
 * End-to-end coverage for one bridge session against the simulated Telegram and a
 * recording Supabase stub: the link handshake, an outbound send with its echo
 * reconciliation, inbound mirroring, media hand-off, presence and read receipts.
 *
 * These are the behaviours that cannot be verified by typechecking, and the ones
 * that break silently in production.
 */

import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, beforeEach, describe, it } from 'node:test';

import { TelegramSession } from '../src/session.js';
import { TelegramSimulator } from '../src/simulator.js';
import { SupabaseBridge } from '../src/supabase.js';
import { aesKeyFromSecret, sealEnvelope, verifySignatureHeader } from '../src/util/envelope.js';
import { CHAT_ID, accountContext, linkClaim, notifyRow, outboxRow, recorder, testConfig, until, type Recorder } from './helpers.js';

const TG_CHAT = 5_001_337_420;

type Harness = {
  config: ReturnType<typeof testConfig>;
  sim: TelegramSimulator;
  rec: Recorder;
  session: TelegramSession;
  storageDir: string;
};

const newHarness = (
  overrides: Record<string, string | undefined> = {},
  contextOverrides: Parameters<typeof accountContext>[0] = {},
): Harness => {
  const config = testConfig({ BRIDGE_MEDIA_DIR: undefined, ...overrides });
  const sim = new TelegramSimulator({ chats: [{ id: TG_CHAT, title: 'Dilnoza', type: 'private', peerUserId: 555 }] });
  const rec = recorder();
  const db = new SupabaseBridge(config, rec.fetchImpl);
  const session = new TelegramSession({
    config,
    db,
    context: accountContext(contextOverrides),
    transportFor: () => sim,
  });
  const storageDir = path.join(os.tmpdir(), 'messengerx-sim-files');
  mkdirSync(storageDir, { recursive: true });
  return { config, sim, rec, session, storageDir };
};

/** Drives the two-step handshake and asserts the DB saw each step. */
async function linkInto(rec: Recorder, config: Harness['config'], session: TelegramSession): Promise<void> {
  const key = aesKeyFromSecret(config.sealKey ?? '');
  const first = linkClaim({ payload: sealEnvelope({ phone: '+998901112233' }, key) as never });
  const asked = await session.handleLinkRequest(first);
  assert.equal(asked.result, 'awaiting_user');
  assert.equal(asked.step, 'awaiting_code');

  const second = linkClaim({
    step: 'awaiting_code',
    payload: sealEnvelope({ code: '12345' }, key) as never,
  });
  const done = await session.handleLinkRequest(second);
  assert.equal(done.result, 'ready');
}

describe('telegram session', () => {
  let harness: Harness;

  beforeEach(async () => {
    // One live session per test; stopping the previous one keeps timers and
    // simulator state from bleeding between cases.
    await harness?.session?.stop('previous test finished');
    harness = newHarness();
  });

  it('hands the TDLib session its persisted base64 encryption key', async () => {
    const key = Buffer.alloc(32, 0x22).toString('base64');
    harness = newHarness({ TDLIB_DB_KEY: key });
    await harness.session.start();
    assert.equal(harness.session.state, 'awaiting_auth',
      'the simulator rejects non-string keys like the real tdjson bytes decoder');
  });

  it('walks the link handshake and reports each step to the app', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    assert.equal(session.state, 'awaiting_auth', 'TDLib wants credentials before anything else');

    await linkInto(rec, config, session);
    assert.equal(session.ready, true);
    assert.equal(sim.authorizationState, 'ready');

    const progress = rec.calls.filter((call) => call.url.includes('bridge_link_progress'));
    assert.ok(progress.length >= 1, 'the app is told which step it is on');
    assert.deepEqual(JSON.parse(progress[0]!.body).p_step, 'awaiting_code');

    const complete = rec.find('bridge_link_complete');
    assert.ok(complete, 'the identity is written once');
    const body = complete.json();
    assert.equal(body.p_tg_user_id, '777001');
    assert.equal(body.p_tg_username, 'messengerx_sim');
    assert.equal(body.p_api_id, config.apiId);
    assert.equal(body.p_login_token_enc, null, 'no login token is minted unless the operator asks');
  });

  it('opens a previously unknown public Telegram user as an owner-scoped private mirror', async () => {
    const config = testConfig();
    const sim = new TelegramSimulator({ chats: [] });
    const rec = recorder();
    const session = new TelegramSession({
      config,
      db: new SupabaseBridge(config, rec.fetchImpl),
      context: accountContext({ tg_user_id: '777001' }),
      transportFor: () => sim,
    });
    harness = { config, sim, rec, session, storageDir: os.tmpdir() };
    await session.start();
    await linkInto(rec, config, session);
    sim.addChat({ id: 5_551_001, peerUserId: 5_551_001, type: 'private', username: 'new_friend', title: 'New Friend' });
    rec.reply('bridge_resolve_chat', { chat_id: CHAT_ID, created: true, mapping_id: 'test-mapping' });
    assert.equal(await session.openPublicChat('new_friend'), CHAT_ID);
    const resolution = rec.find('bridge_resolve_chat');
    assert.equal(resolution?.json().p_owner_user_id, session.ownerUserId);
    assert.equal(resolution?.json().p_tg_chat_id, '5551001');
    assert.equal(resolution?.json().p_peer_user_id, '5551001');
    assert.equal(resolution?.json().p_tg_chat_type, 'private');
  });

  it('registers Telegram groups as groups, not as private users', async () => {
    const config = testConfig();
    const sim = new TelegramSimulator({ chats: [
      { id: 9_991, title: 'Friends', type: 'supergroup' },
    ] });
    const rec = recorder();
    const session = new TelegramSession({
      config, db: new SupabaseBridge(config, rec.fetchImpl),
      context: accountContext({ tg_user_id: '777001' }), transportFor: () => sim,
    });
    harness = { config, sim, rec, session, storageDir: os.tmpdir() };
    await session.start();
    await linkInto(rec, config, session);
    const resolved = await until(() => rec.find('bridge_resolve_chat'));
    assert.equal(resolved.json().p_tg_chat_type, 'supergroup');
    assert.equal(resolved.json().p_peer_user_id, null);
  });

  it('refuses numeric IDs, groups, missing users, Saved Messages and wrong TDLib identities', async () => {
    const config = testConfig();
    const sim = new TelegramSimulator({ chats: [] });
    const rec = recorder();
    const session = new TelegramSession({
      config,
      db: new SupabaseBridge(config, rec.fetchImpl),
      context: accountContext({ tg_user_id: '777001' }),
      transportFor: () => sim,
    });
    harness = { config, sim, rec, session, storageDir: os.tmpdir() };
    await session.start();
    await linkInto(rec, config, session);
    sim.addChat({ id: 8_881, type: 'supergroup', username: 'somegroup' });
    sim.addChat({ id: 777_001, type: 'private', peerUserId: 777_001, username: 'ownaccount' });
    await assert.rejects(() => session.openPublicChat('987654321'), /invalid public Telegram username/);
    await assert.rejects(() => session.openPublicChat('somegroup'), /not a private user/);
    await assert.rejects(() => session.openPublicChat('doesntexist'), /USERNAME_NOT_OCCUPIED/);
    await assert.rejects(() => session.openPublicChat('ownaccount'), /Saved Messages/);
    assert.equal(rec.find('bridge_resolve_chat'), undefined, 'no invalid lookup ever creates a database chat');
  });

  it('gracefully redirects an encrypted QR request to phone authentication without blocking notices', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    const key = aesKeyFromSecret(config.sealKey ?? '');
    const claim = linkClaim({
      payload: { ...sealEnvelope({ use_qr: true }, key), use_qr: true } as never,
    });
    const result = await session.handleLinkRequest(claim);
    assert.equal(result.result, 'awaiting_user');
    assert.equal(result.step, 'awaiting_phone');
    assert.match(result.note ?? '', /QR linking is unavailable/);
    assert.equal(sim.authorizationState, 'wait_phone');
    assert.equal(rec.find('bridge_link_progress')?.json().p_qr_code, null,
      'do not show an invented TDLib QR token');

    const phone = await session.handleLinkRequest(linkClaim({
      step: 'awaiting_phone', payload: sealEnvelope({ phone: '+998901112233' }, key) as never,
    }));
    assert.equal(phone.step, 'awaiting_code');
    const code = await session.handleLinkRequest(linkClaim({
      step: 'awaiting_code', payload: sealEnvelope({ code: '12345' }, key) as never,
    }));
    assert.equal(code.result, 'ready');
    assert.ok(rec.find('bridge_link_complete'), 'the fallback can still link the account');
  });

  it('honours the top-level legacy QR flag even when the envelope has no flag', async () => {
    const { config, session } = harness;
    await session.start();
    const key = aesKeyFromSecret(config.sealKey ?? '');
    const claim = linkClaim({
      payload: { ...sealEnvelope({}, key), use_qr: true } as never,
    });
    const result = await session.handleLinkRequest(claim);
    assert.equal(result.step, 'awaiting_phone');
    assert.match(result.note ?? '', /QR linking is unavailable/);
  });

  it('never lets a sealed credential reach the database or the logs', async () => {
    const { config, session, rec } = harness;
    await session.start();
    const key = aesKeyFromSecret(config.sealKey ?? '');
    await session.handleLinkRequest(
      linkClaim({ payload: sealEnvelope({ phone: '+998901112233', code: '99999' }, key) as never }),
    );
    const serialized = rec.calls.map((call) => call.body).join('\n');
    assert.ok(!serialized.includes('99999'), 'the plaintext code is never sent anywhere');
    assert.ok(!serialized.includes('+998901112233'), 'nor the phone number');
  });

  it('sends one folded notice into Saved Messages without mirroring the self-chat', async () => {
    const { config, session, rec, sim } = harness;
    // The own chat is in getChats at startup too: chat discovery must not make a
    // MessengerX mirror even before a notice is sent.
    sim.addChat({ id: 777_001, title: 'Saved Messages', type: 'private', peerUserId: 777_001 });
    await session.start();
    await linkInto(rec, config, session);
    assert.ok(!rec.calls.some((call) =>
      call.url.includes('bridge_resolve_chat') && String(call.json().p_tg_chat_id) === '777001'),
      'Saved Messages stays out of the app chat list');

    rec.reply('/rpc/bridge_notice_owed', true);
    rec.reply('/rpc/bridge_complete_notify', true);
    const result = await session.deliverNotices([notifyRow({ folded: 3, preview: 'oxirgi xabar' })]);
    assert.deepEqual(result, { sent: 1, failed: 0, parked: 0, skipped: 0 });
    assert.equal(session.counters.notices, 1);
    assert.equal(sim.sentMessages.length, 1, 'exactly one Saved Messages bubble for a burst');
    const sent = sim.sentMessages[0]!;
    assert.equal(String(sent.chat_id), '777001');
    assert.equal(((sent.content as any).text as any).text, 'MessengerX · Dilnoza\noxirgi xabar\n+2 more');
    assert.equal((sent.content as any).link_preview_options.is_disabled, true);
    assert.equal((sent as any).sending_id, null, 'a notice is not an app outbox echo');
    const completed = rec.find('bridge_complete_notify')!.json();
    assert.equal(completed.p_state, 'sent');
    assert.equal(completed.p_self_chat_id, '777001', 'cache the chat id Telegram actually returned');
    assert.ok(Number(completed.p_tg_message_id) > 0);
    assert.equal(rec.find('bridge_notice_owed')!.json().p_preview, 'oxirgi xabar',
      'the last-moment check also refuses a stale preview after a privacy change');

    sim.injectIncoming({ chatId: 777_001, text: 'also saved here', isOutgoing: false });
    sim.injectPeerRead(777_001, Number(sent.id));
    await new Promise((resolve) => setTimeout(resolve, 30)); // settle simulator's queued echo
    const events = rec.calls.filter((call) => call.url.includes('telegram-ingest'))
      .flatMap((call) => call.json().events ?? []);
    assert.ok(events.every((event: any) => event.tg_chat_id !== '777001'),
      'echo, inbound, and read updates in Saved Messages never reach the app');
    assert.ok(!rec.calls.some((call) => call.url.includes('bridge_mark_inbox_read') &&
      String(call.json().p_tg_chat_id) === '777001'), 'read updates in Saved Messages stay private');
  });

  it('opens Saved Messages through the recipient session if TDLib has no self chat yet', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);
    await assert.rejects(() => session.client.request('getChat', { chat_id: '777001' }), /CHAT_NOT_FOUND/);

    rec.reply('/rpc/bridge_notice_owed', true);
    rec.reply('/rpc/bridge_complete_notify', true);
    const delivered = await session.deliverNotices([notifyRow({ tg_self_chat_id: '99999' })]);
    assert.equal(delivered.sent, 1);
    assert.equal((await session.client.request('getChat', { chat_id: '777001' })).id, 777001);
    assert.equal(String(sim.sentMessages[0]?.chat_id), '777001',
      'createPrivateChat returned the authoritative chat id, not the stale cached one');
    assert.equal(rec.find('bridge_complete_notify')!.json().p_self_chat_id, '777001');
    assert.ok(!rec.calls.some((call) => call.url.includes('bridge_resolve_chat') &&
      String(call.json().p_tg_chat_id) === '777001'), 'self chat must not be imported');
  });

  it('does not send a claimed notice if it was read or muted while waiting', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);
    rec.reply('/rpc/bridge_notice_owed', false);
    rec.reply('/rpc/bridge_complete_notify', true);
    const result = await session.deliverNotices([notifyRow()]);
    assert.equal(result.skipped, 1);
    assert.equal(sim.sentMessages.length, 0);
    assert.equal(rec.find('bridge_complete_notify')!.json().p_state, 'skipped');
  });

  it('replays a failed database completion without resending the Saved Messages text', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);
    rec.reply('/rpc/bridge_notice_owed', true);
    rec.reply('/rpc/bridge_complete_notify', { message: 'temporary DB outage', code: '08006' }, 503);
    const first = await session.deliverNotices([notifyRow()]);
    assert.equal(first.sent, 1, 'Telegram did receive the notice');
    assert.equal(sim.sentMessages.length, 1);

    rec.reply('/rpc/bridge_complete_notify', true);
    const retried = await session.deliverNotices([notifyRow({ attempts: 2 })]);
    assert.equal(retried.skipped, 1, 'only the DB completion is retried');
    assert.equal(sim.sentMessages.length, 1, 'never send a second bubble while the session survives');
    assert.equal(rec.find('bridge_complete_notify')!.json().p_state, 'sent');
  });

  it('parks a notice on Telegram flood wait and resets a bad Saved Messages cache', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);
    rec.reply('/rpc/bridge_notice_owed', true);
    sim.failNext('sendMessage', 420, 'FLOOD_WAIT_23');
    const parked = await session.deliverNotices([notifyRow()]);
    assert.equal(parked.parked, 1);
    const retry = rec.find('bridge_complete_notify')!.json();
    assert.equal(retry.p_state, 'queued');
    assert.equal(retry.p_retry_in, '25 seconds');
    assert.equal(retry.p_reset_self_chat, false);

    rec.reply('/rpc/bridge_notice_owed', true);
    sim.failNext('sendMessage', 400, 'PEER_ID_INVALID');
    const badCache = await session.deliverNotices([notifyRow({ attempts: 2 })]);
    assert.equal(badCache.parked, 1);
    const fallback = rec.find('bridge_complete_notify')!.json();
    assert.equal(fallback.p_state, 'queued');
    assert.equal(fallback.p_retry_in, '60 seconds');
    assert.equal(fallback.p_reset_self_chat, true);
  });

  it('fails a revoked session’s notice queue and never sends under the wrong account', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);
    rec.reply('/rpc/bridge_notice_owed', true);
    sim.failNext('sendMessage', 401, 'AUTH_KEY_UNREGISTERED');
    const failed = await session.deliverNotices([notifyRow()]);
    assert.equal(failed.failed, 1);
    assert.equal(session.ready, false);
    assert.ok(rec.find('bridge_fail_notify'), 'remaining notices for this revoked account are failed');
    assert.equal(rec.find('bridge_set_account_state')!.json().p_auth_state, 'needs_reauth');

    const wrong = await session.deliverNotices([notifyRow({ user_id: CHAT_ID })]);
    assert.equal(wrong.failed, 1);
    assert.equal(rec.find('bridge_complete_notify')!.json().p_error, 'wrong account session');
  });

  it('sends a queued text message and reconciles the echo', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);

    const result = await session.pump([outboxRow({ payload: { text: 'salom, qalaysiz?' } })]);
    assert.equal(result.sent, 1);
    assert.ok(result.presence >= 0);

    const sent = sim.sentMessages[0];
    assert.ok(sent, 'TDLib received a sendMessage');
    assert.equal(String(sent.chat_id), String(TG_CHAT));
    // The simulator stores what TDLib would store: the rendered content.
    assert.equal(((sent.content as any).text as any).text, 'salom, qalaysiz?');
    assert.equal((sent as any).sending_id, 41, 'the outbox id is the correlation token');

    const completion = rec.find('bridge_complete_outbox');
    assert.ok(completion);
    const done = completion.json();
    assert.equal(done.p_state, 'sent');
    assert.ok(Number(done.p_tg_message_id) > 0, 'the Telegram message id is stored');

    // The echo arrives as an update and must not become a second bubble: it is
    // pushed with tg_send_id so the database reconciles it against the row.
    const allEvents = (): any[] =>
      rec.calls.filter((call) => call.url.includes('telegram-ingest')).flatMap((call) => call.json().events ?? []);
    const event = await until(() => allEvents().find((candidate) => candidate.type === 'message'));
    assert.equal(event.tg_send_id, '41');
    assert.equal(event.is_outgoing, true);
    assert.equal(event.owner_user_id, accountContext().user_id);
    assert.equal(event.tg_chat_id, String(TG_CHAT));
    assert.match(event.dedupe_key, /^aaaaaaaa.*:message:\d+$/);
    // Chat discovery and the echo may share a batch; the queue must never lose one.
    assert.ok(allEvents().some((candidate) => candidate.type === 'chat'));
  });

  it('mirrors an inbound peer message into a signed ingest batch', async () => {
    const { config, session, rec, sim } = harness;
    await session.start();
    await linkInto(rec, config, session);

    assert.ok(rec.find('bridge_resolve_chat'), 'the chat is mapped on discovery');

    const message = sim.injectIncoming({ chatId: TG_CHAT, text: 'qalaysiz, doʻstim?', senderName: 'Dilnoza' });
    const ingest = await until(() => {
      const call = rec.find('telegram-ingest');
      if (!call) return undefined;
      const events = call.json().events as any[];
      return events.some((event) => event.tg_message_id === String(message.id)) ? call : undefined;
    });
    const event = ingest
      .json()
      .events.find((candidate: any) => candidate.tg_message_id === String(message.id));
    assert.equal(event.type, 'message');
    assert.equal(event.body, 'qalaysiz, doʻstim?');
    assert.equal(event.kind, 'text');
    assert.equal(event.is_outgoing, false);
    assert.equal(event.sent_at.slice(0, 4), new Date(Number(message.date) * 1000).toISOString().slice(0, 4));

    const headers = ingest.headers;
    assert.equal(headers.authorization, 'Bearer shared-bridge-token');
    const signature = headers['x-bridge-signature'] ?? '';
    assert.match(signature, /^t=\d+,v1=[0-9a-f]{64}$/);
    // The signature covers the exact bytes on the wire: recomputing it over
    // `ingest.body` is what proves the edge function will accept the batch.
    assert.equal(verifySignatureHeader(config.bridgeHmacSecret ?? '', signature, ingest.body, 60), true);
  });

  it('uploads a downloadable photo and attaches the storage path', async () => {
    const { config, session, rec, sim, storageDir } = harness;
    await session.start();
    await linkInto(rec, config, session);

    // The bridge only uploads media once the Telegram chat is bound to a MessengerX
    // chat, because that chat id is the storage folder membership is checked on.
    rec.reply('/rpc/bridge_resolve_chat', { chat_id: CHAT_ID, created: true });

    // The simulator promises this exact local path for the next file it hands out.
    const bytes = Buffer.from(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Uint8Array(60)]));
    const nextFileId = 3_001;
    const target = path.join(process.env.TMPDIR ?? '/tmp', `messengerx-sim-${nextFileId}.bin`);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, bytes);
    void storageDir;

    const message = sim.injectIncoming({ chatId: TG_CHAT, photo: true, text: 'from the trip' });
    const upload = await until(() => rec.calls.find((call) => call.url.includes('/storage/v1/object/images/')));
    assert.equal(upload.method, 'POST');
    assert.equal(upload.headers['x-upsert'], 'true');
    assert.equal(upload.headers['content-type'], 'image/jpeg');

    const ingest = await until(() => {
      const call = rec.find('telegram-ingest');
      const events: any[] = call?.json().events ?? [];
      return events.find((event) => event.tg_message_id === String(message.id) && event.media) ? call : undefined;
    });
    const event = ingest
      .json()
      .events.find((candidate: any) => candidate.tg_message_id === String(message.id));
    assert.equal(event.kind, 'image');
    assert.equal(event.body, 'from the trip');
    assert.equal(event.media.bucket, 'images');
    assert.equal(event.media.path.split('/')[0], CHAT_ID, 'folder [1] must be the chat, for the storage policy');
    // Chat-scoped path, because storage membership is resolved from folder [1].
    assert.match(event.media.path, new RegExp(`^${CHAT_ID}/tg/${TG_CHAT}-${message.id}\\.jpg$`));
    assert.equal(event.media.size_bytes, bytes.byteLength);
  });

  it('still mirrors media it will not download, instead of dropping it', async () => {
    const { session, rec, sim } = newHarness({}, { auto_download_media: false, auto_download_voice: false });
    await session.start();
    await linkInto(rec, harness.config, session);

    const message = sim.injectIncoming({ chatId: TG_CHAT, photo: true });
    const ingest = await until(() => {
      const call = rec.find('telegram-ingest');
      const events: any[] = call?.json().events ?? [];
      return events.some((event) => event.tg_message_id === String(message.id)) ? call : undefined;
    });
    const event = ingest.json().events.find((candidate: any) => candidate.tg_message_id === String(message.id));
    assert.equal(event.kind, 'image');
    assert.equal(event.media, null, 'no bytes, so no media object');
    assert.ok(event.body.includes('Photo'), 'but the conversation still shows it');
    assert.ok(!rec.calls.some((call) => call.url.includes('/storage/v1/object/')), 'nothing was uploaded');
  });

  it('forwards presence and read receipts, each exactly once', async () => {
    const { config, session, rec } = harness;
    await session.start();
    await linkInto(rec, config, session);

    rec.reply('/rpc/bridge_pending_typing', [
      {
        chat_id: CHAT_ID,
        tg_chat_id: String(TG_CHAT),
        action: 'typing',
        updated_at: new Date().toISOString(),
      },
    ]);
    rec.reply('/rpc/bridge_pending_reads', [
      { chat_id: CHAT_ID, tg_chat_id: String(TG_CHAT), max_read_message_id: '900' },
    ]);

    const result = await session.pump([]);
    assert.equal(result.presence, 1);
    assert.equal(result.reads, 1);

    // `sendChatAction` is a notification, so it lands on the next tick; waiting
    // for it is what the production loop does implicitly.
    const action = (await until(() => harness.sim.chatActions.at(-1))) as any;
    assert.equal(action['@type'], 'sendChatAction');
    assert.equal(action.action['@type'], 'chatActionTyping');

    const synced = rec.find('bridge_mark_reads_synced');
    assert.ok(synced, 'the watermark is written so the receipt is not re-sent');
    assert.equal(synced.json().p_max_read, '900');

    const second = await session.pump([]);
    assert.equal(second.presence, 0, 'the same presence row is not forwarded twice');
  });

  it('parks sends when the session loses its authorisation', async () => {
    const { config, session, rec } = harness;
    await session.start();
    assert.equal(session.ready, false);

    const result = await session.pump([outboxRow({ payload: { text: 'queued while offline' } })]);
    assert.equal(result.parked, 1);
    const parked = rec.find('bridge_complete_outbox');
    assert.ok(parked);
    assert.equal(parked.json().p_state, 'queued', 'the row waits for the user instead of failing');
    assert.match(parked.json().p_error, /not authorised/);
    assert.equal(harness.sim.sentMessages.length, 0);
  });

  it('honours Telegram flood waits with the delay Telegram asked for', async () => {
    const { config, session, rec } = harness;
    await session.start();
    await linkInto(rec, config, session);

    harness.sim.failNext('sendMessage', 420, 'FLOOD_WAIT_23');

    const result = await session.pump([outboxRow({ payload: { text: 'spam guard' } })]);
    assert.equal(result.parked, 1);
    const completion = rec.find('bridge_complete_outbox')!.json();
    assert.equal(completion.p_state, 'queued');
    assert.equal(completion.p_error, 'flood_wait_23');
    assert.equal(Number.parseInt(String(completion.p_retry_in), 10), 25, 'FLOOD_WAIT_23 + a small margin');
  });

  after(async () => {
    await harness.session.stop('test teardown');
    // A stopped session must not keep the process alive.
    assert.equal(harness.session.stopped, true);
  });
});
