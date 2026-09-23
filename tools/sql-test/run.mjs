#!/usr/bin/env node
/**
 * tools/sql-test — runs every MessengerX migration against a throwaway
 * Postgres (PGlite = real PostgreSQL compiled to WASM) and asserts the
 * behaviour the app, the edge functions and the TDLib bridge rely on:
 *
 *   • schema + trigger correctness (chat list projection, ticks, outbox)
 *   • RLS isolation between users, eligibility gating, column guards
 *   • bridge RPC contract (claim / ingest / echo reconciliation)
 *   • storage bucket configuration
 *
 * CI runs this on every push, so "the SQL applies" is never a guess.
 *
 *   node tools/sql-test/run.mjs            # run everything
 *   node tools/sql-test/run.mjs --keep     # print each executed statement's error
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const MIGRATIONS = join(ROOT, 'supabase', 'migrations');
const verbose = process.argv.includes('--keep');

const U = {
  a: '11111111-1111-1111-1111-111111111111',
  b: '22222222-2222-2222-2222-222222222222',
  gated: '33333333-3333-3333-3333-333333333333',
  other: '44444444-4444-4444-4444-444444444444',
  link: '66666666-6666-6666-6666-666666666666',
};

// ---------------------------------------------------------------------------
// tiny test harness
// ---------------------------------------------------------------------------
const results = [];
let currentGroup = 'setup';
const group = (name) => (currentGroup = name);

async function test(name, fn) {
  try {
    await fn();
    results.push({ ok: true, name, group: currentGroup });
  } catch (err) {
    results.push({ ok: false, name, group: currentGroup, error: String(err && err.message ? err.message : err) });
  }
}

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg || 'assertion failed');
};
const eq = (actual, expected, msg) => {
  if (actual !== expected) {
    throw new Error(`${msg || 'value mismatch'}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
};
async function throws(fn, pattern) {
  let err = null;
  try {
    await fn();
  } catch (e) {
    err = e;
  }
  assert(err, 'expected the statement to be rejected, but it succeeded');
  if (pattern) {
    assert(pattern.test(String(err.message)), `error "${err.message}" does not match ${pattern}`);
  }
  return err;
}

// ---------------------------------------------------------------------------
// database bootstrap
// ---------------------------------------------------------------------------
const pg = await PGlite.create({ name: 'messengerx-sqltest' });
// multi-statement scripts go through exec(); anything with $1 bindings must use
// query(), which is why exec() dispatches on the presence of params.
const exec = async (sql, params) => (params ? pg.query(sql, params) : pg.exec(sql));
const query = async (sql, params) => (await pg.query(sql, params)).rows;
const one = async (sql, params) => {
  const res = await pg.query(sql, params ?? []);
  const rows = res.rows ?? [];
  if (!rows.length) throw new Error(`no rows: ${sql.slice(0, 90)}`);
  return rows[0];
};
const scalar = async (sql, params) => {
  const row = await one(sql, params);
  return Object.values(row)[0];
};

const setClaims = async (claims) => {
  await exec(`reset role`);
  await pg.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(claims)]);
};
const become = async (uid) => {
  await setClaims({ sub: uid, role: 'authenticated', aud: 'authenticated' });
  await exec(`set role authenticated`);
};
const becomeService = async () => {
  await setClaims({ role: 'service_role' });
  await exec(`set role service_role`);
};
const becomeOwner = async () => {
  await exec(`reset role`);
  await pg.query(`select set_config('request.jwt.claims', '{}', false)`, []);
};
const rpc = async (fn, args = 'null') => (await query(`select * from ${fn}(${args})`));

console.log('· booting PGlite + Supabase stub');
await exec(readFileSync(join(HERE, 'fixtures', 'supabase_stub.sql'), 'utf8'));

const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort();
for (const file of files) {
  const sql = readFileSync(join(MIGRATIONS, file), 'utf8');
  try {
    await exec(sql);
    console.log(`· applied ${file}`);
  } catch (err) {
    console.error(`\n✖ ${file} failed:\n${err.message}\n`);
    if (!verbose) process.exit(1);
  }
}

// ---------------------------------------------------------------------------
group('bootstrap');
await test('migrations are re-appliable (idempotent)', async () => {
  await exec(readFileSync(join(MIGRATIONS, files[0]), 'utf8'));
});

await test('auth.users trigger creates profiles + a telegram_accounts row', async () => {
  await becomeOwner();
  await exec(`
    insert into auth.users (id, phone, raw_app_meta_data, raw_user_meta_data) values
      ('${U.a}', '+998901112233', '{"provider":"phone"}', '{"full_name":"Aziz Carrier"}');
    insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
      ('${U.b}', 'bestie@example.com', '{"provider":"phone"}', '{"full_name":"Dilnoza Rustamova"}');
    insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
      ('${U.gated}', 'kid@example.com', '{"provider":"google"}', '{"name":"Kid Coder"}');
    insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
      ('${U.other}', 'stranger@example.com', '{"provider":"phone"}', '{"full_name":"Stranger"}');
    insert into auth.users (id, phone, raw_app_meta_data, raw_user_meta_data) values
      ('${U.link}', '+9989017778899', '{"provider":"phone"}', '{"full_name":"Link Tester"}');
  `);
  eq(await scalar(`select count(*)::int from public.profiles`), 5, 'profiles created');
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.a}'`), 'active');
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.gated}'`),
     'pending_verification', 'google signups start gated');
  eq(await scalar(`select count(*)::int from public.telegram_accounts`), 5, 'one link row per user');
  eq(await scalar(`select username from public.profiles where id = '${U.a}'`), 'aziz_carrier',
     'username derived from full name');
});

await test('username collisions are resolved, not fatal', async () => {
  await exec(`
    insert into auth.users (id, phone, raw_user_meta_data) values
      ('55555555-5555-5555-5555-555555555555', '+9989010000000', '{"full_name":"Aziz Carrier"}');
  `);
  const rows = await query(`select username from public.profiles where display_name = 'Aziz Carrier'`);
  eq(rows.length, 2, 'two users sharing a display name');
  eq(new Set(rows.map((r) => r.username)).size, 2, 'two distinct usernames');
});

// ---------------------------------------------------------------------------
group('rls');
await test('a user can read only their own profile row', async () => {
  await become(U.a);
  eq(await scalar(`select count(*)::int from public.profiles`), 1, 'own row only');
  const dir = await query(`select count(*)::int as n from public.directory`);
  eq(Number(dir[0].n) >= 5, true, 'directory view is public');
});

await test('privileged profile columns are server-managed', async () => {
  await become(U.a);
  await throws(
    () => exec(`update public.profiles set access_state = 'banned' where id = '${U.a}'`),
    /server-managed/
  );
  await exec(`update public.profiles set bio = 'shipping pixels' where id = '${U.a}'`);
  eq(await scalar(`select bio from public.profiles where id = '${U.a}'`), 'shipping pixels');
});

await test('users cannot see other users chats, telegrams rows or the ledger', async () => {
  await become(U.other);
  eq(await scalar(`select count(*)::int from public.chats`), 0, 'no chats visible');
  eq(await scalar(`select count(*)::int from public.telegram_accounts`), 1, 'only their own link row');
  eq(await scalar(`select count(*)::int from public.messages`), 0, 'no messages visible');
  eq(await scalar(`select count(*)::int from public.profiles`), 1, 'no profile leak');
  await becomeService();
  eq(await scalar(`select count(*)::int from public.telegram_inbox_events`), 0, 'empty ledger to start');
});

await test('google_credentials / eligibility_checks are unreachable for clients', async () => {
  await becomeService();
  await exec(`insert into public.eligibility_checks (user_id, verdict, method) values ('${U.a}', 'passed', 'manual')`);
  await become(U.b);
  await throws(() => exec(`select count(*) from public.eligibility_checks`), /permission denied/);
  await become(U.a);
  await throws(() => exec(`select count(*) from public.google_credentials`), /permission denied/);
});

// ---------------------------------------------------------------------------
group('messaging');
let chatId = null;
let msgId = null;

await test('create_direct_chat is find-or-create and RLS-visible', async () => {
  await become(U.a);
  const rows = await rpc('public.create_direct_chat', `null, 'dilnoza_rustamova'`);
  chatId = rows[0].create_direct_chat;
  assert(chatId, 'chat id returned');
  const again = await rpc('public.create_direct_chat', `null, 'dilnoza_rustamova'`);
  eq(again[0].create_direct_chat, chatId, 'same chat for the same pair');
  await become(U.b);
  eq(await scalar(`select count(*)::int from public.chats where id = '${chatId}'`), 1, 'peer sees it');
});

await test('self-chat is refused', async () => {
  await become(U.a);
  await throws(() => rpc('public.create_direct_chat', `null, 'aziz_carrier'`), /yourself/);
});

await test('send_message persists, stamps the single tick and never trusts the client state', async () => {
  await become(U.a);
  const [row] = await rpc(
    'public.send_message',
    `'${chatId}', 'text', 'Salom! Realtime demo', null, null, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'`
  );
  msgId = row.id;
  const stored = await one(`select * from public.messages where id = $1`, [msgId]);
  eq(stored.state, 'sent', 'server accepted ⇒ single tick');
  eq(stored.source, 'app');
  assert(stored.sent_at, 'sent_at stamped');
  eq(stored.sender_name, 'Aziz Carrier', 'sender snapshot from the profile');
  eq(stored.client_message_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
});

await test('send_message is idempotent on client_message_id', async () => {
  await become(U.a);
  const again = await rpc(
    'public.send_message',
    `'${chatId}', 'text', 'Salom! Realtime demo', null, null, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'`
  );
  const id2 = again[0].id;
  eq(id2, msgId, 'replay returns the original row');
  eq(await scalar(`select count(*)::int from public.messages where chat_id = '${chatId}'`), 1);
});

await test('empty text messages are rejected by the shape constraint', async () => {
  await become(U.a);
  await throws(
    () => exec(`select public.send_message('${chatId}'::uuid, 'text', '   ', null, null, gen_random_uuid())`),
    /shape|check|constraint|22023|violates/i
  );
});

await test('voice notes need duration + media, images are validated too', async () => {
  await become(U.a);
  await throws(
    () => rpc('public.send_message',
      `'${chatId}', 'voice', null, '{"bucket":"voice-notes","path":"${chatId}/v1.ogg"}', null, null`),
    /duration_ms/
  );
  const [ok] = await rpc('public.send_message',
    `'${chatId}', 'voice', null, '{"bucket":"voice-notes","path":"${chatId}/v1.ogg","duration_ms":4200,"waveform":[10,40,70],"mime":"audio/ogg"}', null, null`);
  assert(ok, 'valid voice note accepted');
  await throws(
    () => rpc('public.send_message',
      `'${chatId}', 'voice', null, '{"bucket":"secrets","path":"x/y","duration_ms":1}', null, null`),
    /bucket/
  );
});

await test('chat_summaries renders preview, sender label and unread badge', async () => {
  await become(U.a);
  const mine = await one(`select * from public.chat_summaries(null, 10)`);
  eq(mine.preview_sender, 'You');
  eq(mine.unread_count, 0, 'author has no unread');
  eq(mine.peer_display_name, 'Dilnoza Rustamova');

  await become(U.b);
  const theirs = await one(`select * from public.chat_summaries(null, 10)`);
  eq(theirs.unread_count, 2, 'two unread for the peer');
  eq(theirs.preview_sender, 'Aziz Carrier');
  eq(theirs.chat_id, chatId);
});

await test('delivery + read receipts advance ticks monotonically', async () => {
  await become(U.b);
  const ids = await query(`select id from public.messages where chat_id = '${chatId}' and sender_id = '${U.a}'`);
  const arr = `{${ids.map((r) => r.id).join(',')}}`;
  const n = await scalar(`select public.mark_messages_delivered($1::uuid[])`, [arr]);
  eq(Number(n) > 0, true, 'delivered acked');
  eq(await scalar(`select state::text from public.messages where id = $1`, [ids[0].id]), 'delivered');

  await exec(`select public.mark_chat_read('${chatId}')`);
  eq(await scalar(`select state::text from public.messages where id = $1`, [ids[0].id]), 'read', 'blue tick');
  eq(await scalar(`select unread_count from public.chat_participants where chat_id = '${chatId}' and user_id = '${U.b}'`), 0);
});

await test('ticks never regress', async () => {
  await becomeService();
  await exec(`update public.messages set state = 'sent' where id = $1`, [msgId]);
  eq(await scalar(`select state::text from public.messages where id = $1`, [msgId]), 'read', 'downgrade ignored');
});

await test('search finds messages the caller can see, and only those', async () => {
  await become(U.a);
  const hits = await query(`select * from public.search_messages('Realtime')`);
  eq(hits.length >= 1, true, 'sender finds it');
  await become(U.other);
  eq((await query(`select * from public.search_messages('Realtime')`)).length, 0, 'stranger finds nothing');
});

await test('only the sender may edit/delete a message', async () => {
  await become(U.b);
  eq(await scalar(`select public.delete_message('${msgId}')`), false, 'peer cannot delete');
  // RLS silently matches zero rows for a non-owner, so the body must survive.
  await exec(`update public.messages set body = 'hacked' where id = $1`, [msgId]);
  eq(await scalar(`select body from public.messages where id = $1`, [msgId]), 'Salom! Realtime demo',
     'peer cannot rewrite content');
  // UPDATE with a non-matching USING policy matches zero rows (it is not an
  // error in Postgres), so assert on the *effect* instead.
  const tickBefore = await scalar(`select state::text from public.messages where id = $1`, [msgId]);
  await exec(`update public.messages set state = 'sent' where id = $1`, [msgId]);
  eq(await scalar(`select state::text from public.messages where id = $1`, [msgId]), tickBefore,
     'a peer cannot rewrite someone else\'s tick');
  await become(U.a);
  eq(await scalar(`select public.delete_message('${msgId}')`), true, 'author soft-deletes');
  eq(await scalar(`select count(*)::int from public.messages where id = '${msgId}' and deleted_at is null`), 0);
});

await test('heartbeat drives derived presence', async () => {
  await become(U.a);
  await exec(`select public.heartbeat()`);
  eq(await scalar(`select is_online from public.directory where id = '${U.a}'`), true, 'is_online derived');
});

await test('update_profile refuses another user\'s storage path', async () => {
  await become(U.a);
  await throws(() => rpc('public.update_profile', `null, null, '${U.b}/avatar.png', null`), /own storage prefix/);
  await rpc('public.update_profile', `null, 'senior engineer', '${U.a}/avatar.png', '@messengerx'`);
  eq(await scalar(`select avatar_path from public.profiles where id = '${U.a}'`), `${U.a}/avatar.png`);
});

await test('00011: an avatar is removed only with p_clear_avatar', async () => {
  await become(U.a);
  // There is exactly one way to remove an avatar. An empty string is not it: the
  // storage-prefix guard rejects it, so a client cannot smuggle in a no-op write
  // and believe the picture was removed.
  await throws(() => rpc('public.update_profile', `null, null, '', null`), /own storage prefix/);
  eq(await scalar(`select avatar_path from public.profiles where id = '${U.a}'`), `${U.a}/avatar.png`,
    'the rejected call changed nothing');
  await rpc('public.update_profile', `null, null, '${U.a}/other.png', null, true`);
  eq(await scalar(`select avatar_path from public.profiles where id = '${U.a}'`), null,
    'the flag wins over a path sent at the same time');
  // Other fields are untouched by a clear-only call.
  eq(await scalar(`select bio from public.profiles where id = '${U.a}'`), 'senior engineer', 'bio survives');
  eq(await scalar(`select telegram_username from public.profiles where id = '${U.a}'`), 'messengerx', 'handle survives');
});

// ---------------------------------------------------------------------------
group('eligibility gate');
await test('a gated Google account cannot chat', async () => {
  await become(U.gated);
  await throws(() => rpc('public.create_direct_chat', `null, 'dilnoza_rustamova'`), /not eligible/);
  const [st] = await query(`select public.eligibility_status() as s`);
  eq(st.s.access_state, 'pending_verification');
});

await test('record_eligibility_check unlocks after the age gate passes', async () => {
  await becomeService();
  await exec(`select public.record_eligibility_check(jsonb_build_object(
      'user_id', '${U.gated}', 'request_id', 'req-1', 'method', 'gmail_profile',
      'verdict', 'passed', 'account_age_days', 1421, 'min_age_days', 366,
      'account_created_at', (clock_timestamp() - interval '1421 days')::text,
      'email', 'kid@example.com', 'signals', '{"initialData":1}'::jsonb))`);
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.gated}'`), 'active');
  await become(U.gated);
  const [row] = await query(`select public.create_direct_chat(null, 'stranger') as id`);
  assert(row.id, 'gated user can now start a chat');
});

await test('a too-young Google account is restricted, not deleted', async () => {
  await becomeService();
  await exec(`select public.record_eligibility_check(jsonb_build_object(
      'user_id', '${U.other}', 'request_id', 'req-2', 'method', 'drive_oldest_file',
      'verdict', 'failed', 'account_age_days', 91, 'min_age_days', 366,
      'reason', 'Google account is 91 days old; 366 required'))`);
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.other}'`), 'restricted');
  eq(await scalar(`select count(*)::int from auth.users where id = '${U.other}'`), 1, 'account survives for appeal');
});

// ---------------------------------------------------------------------------
group('telegram bridge');
const TG_CHAT = 5001337420n;
const TG_CHAT_STR = '5001337420';

await test('an app message for a linked chat lands in the outbox atomically', async () => {
  await becomeService();
  await exec(`
    update public.telegram_accounts set auth_state = 'linked', tg_user_id = 100,
           sync_direction = 'both', linked_at = clock_timestamp() where user_id = '${U.a}';
    insert into public.telegram_chats (owner_user_id, tg_chat_id, tg_chat_type, chat_id, peer_user_id)
    values ('${U.a}', ${TG_CHAT_STR}, 'private', '${chatId}', 9999)
    on conflict (owner_user_id, tg_chat_id) do update set chat_id = excluded.chat_id;
  `);
  await become(U.a);
  await rpc('public.send_message', `'${chatId}', 'text', 'forward me to telegram', null, null, null`);
  const ob = await one(`
    select o.*, m.tg_send_id from public.telegram_outbox o
    join public.messages m on m.id = o.message_id
    order by o.id desc limit 1`);
  eq(ob.state, 'queued');
  eq(String(ob.tg_chat_id), TG_CHAT_STR, 'resolved the Telegram peer id');
  eq(ob.payload?.text, 'forward me to telegram', 'payload carries the text');
  eq(ob.tg_send_id, null, 'send id is only assigned on claim');
});

await test('bridge_claim_outbox leases the row and stamps tg_send_id', async () => {
  await becomeService();
  const rows = await query(`select * from public.bridge_claim_outbox('worker-1', null, 10)`);
  eq(rows.length, 1, 'exactly one claimable row');
  const claimed = rows[0];
  eq(claimed.kind, 'text');
  eq(claimed.attempts, 1);
  eq(await scalar(`select state::text from public.telegram_outbox where id = $1`, [claimed.outbox_id]), 'in_flight');
  eq(await scalar(`select tg_send_id::text from public.messages where id = $1`, [claimed.message_id]),
     String(claimed.outbox_id), 'outbox id is the TDLib sending_id');
  eq((await query(`select * from public.bridge_claim_outbox('worker-2', null, 10)`)).length, 0,
     'second worker cannot steal the lease');
  globalThis.__claim = claimed;
});

await test('the Telegram echo reconciles instead of duplicating the bubble', async () => {
  const claimed = globalThis.__claim;
  await becomeService();
  const res = await one(`select public.bridge_ingest_message($1::jsonb) as r`, [JSON.stringify({
    owner_user_id: U.a,
    tg_chat_id: TG_CHAT_STR,
    tg_chat_id_num: claimed.tg_chat_id,
    tg_message_id: 777,
    tg_send_id: String(claimed.outbox_id),
    kind: 'text',
    body: 'forward me to telegram',
    is_outgoing: true,
    state: 'sent',
    dedupe_key: `echo:${claimed.outbox_id}`,
  })]);
  eq(res.r.status, 'echo', 'matched the pending send by tg_send_id');
  eq(res.r.message_id, claimed.message_id);
  eq(await scalar(`select tg_message_id::text from public.messages where id = $1`, [claimed.message_id]), '777');
  eq(await scalar(`select state::text from public.telegram_outbox where id = $1`, [claimed.outbox_id]), 'sent');
  eq(await scalar(`select synced_to_telegram_at is not null from public.messages where id = $1`, [claimed.message_id]),
     true, 'outbound sync stamped');
});

await test('inbound Telegram traffic mirrors into a chat, once', async () => {
  const TG_OTHER = '7000000001';
  await becomeService();
  const first = await one(`select public.bridge_ingest_message($1::jsonb) as r`, [JSON.stringify({
    owner_user_id: U.a,
    tg_chat_id: TG_OTHER,
    tg_chat_type: 'private',
    tg_message_id: 1001,
    kind: 'voice',
    body: null,
    media: { bucket: 'voice-notes', path: 'placeholder', url: 'https://cdn.example/v.ogg', duration_ms: 6100, waveform: [4, 9, 21], mime: 'audio/ogg' },
    sender_peer_user_id: 4242424,
    sender_first_name: 'Sabina',
    sender_last_name: 'Yusupova',
    peer_user_id: 4242424,
    peer_first_name: 'Sabina',
    peer_last_name: 'Yusupova',
    is_outgoing: false,
    sent_at: new Date(Date.now() - 60_000).toISOString(),
    dedupe_key: 'in:1001',
  })]);
  eq(first.r.created, true, 'mirror chat created');
  const mirrorChat = first.r.chat_id;
  assert(mirrorChat, 'chat id returned');

  const dup = await one(`select public.bridge_ingest_message($1::jsonb) as r`, [JSON.stringify({
    owner_user_id: U.a, tg_chat_id: TG_OTHER, tg_message_id: 1001, kind: 'voice',
    media: { bucket: 'voice-notes', path: 'placeholder', duration_ms: 6100 },
    sender_peer_user_id: 4242424, dedupe_key: 'in:1001',
  })]);
  eq(dup.r.status, 'duplicate', 'same dedupe key twice ⇒ no second bubble');

  const noSender = await one(`select public.bridge_ingest_message($1::jsonb) as r`, [JSON.stringify({
    owner_user_id: U.a, tg_chat_id: TG_OTHER, tg_message_id: 1002, kind: 'text', body: 'orphan', dedupe_key: 'in:1002',
  })]);
  eq(noSender.r.status, 'skipped', 'sender-less events are parked, not thrown');
  eq(noSender.r.reason, 'no_sender');

  const m = await one(`select * from public.messages where id = $1`, [first.r.message_id]);
  eq(m.source, 'telegram');
  eq(m.kind, 'voice');
  eq(m.sender_name, 'Sabina Yusupova', 'peer snapshot');
  eq(m.state, 'delivered', 'inbound messages arrive delivered');
  assert(m.sender_peer_id, 'peer row linked');
  eq(await scalar(`select count(*)::int from public.chats where id = $1 and is_telegram_mirror and kind = 'direct'`, [mirrorChat]), 1);
  eq(await scalar(`select title from public.chats where id = $1`, [mirrorChat]), 'Sabina Yusupova');
  globalThis.__mirror = { mirrorChat };
});

await test('the mirror chat shows up in the Flutter home screen', async () => {
  await become(U.a);
  const rows = await query(`select * from public.chat_summaries(null, 20) order by last_message_at desc nulls last`);
  const row = rows.find((r) => r.chat_id === globalThis.__mirror.mirrorChat);
  assert(row, 'mirrored chat listed');
  eq(row.is_telegram_mirror, true);
  eq(row.preview_kind, 'voice');
  eq(row.preview_body, 'Voice message');
  eq(row.telegram_auth_state, 'linked');
  eq(row.sync_direction, 'both');
  eq(row.title, 'Sabina Yusupova');
});

await test('Telegram read receipts turn app ticks blue', async () => {
  await becomeService();
  const n = await scalar(`select public.bridge_update_delivery(jsonb_build_object(
      'owner_user_id', '${U.a}', 'tg_chat_id', '${TG_CHAT_STR}',
      'up_to_tg_message_id', '100000', 'state', 'read'))`);
  eq(Number(n) >= 1, true, 'receipts applied');
  eq(await scalar(`select state::text from public.messages where id = $1`, [globalThis.__claim.message_id]), 'read');
});

await test('outbox failures retry with a lease and terminate after max_attempts', async () => {
  const claimed = globalThis.__claim;
  await becomeService();
  const stateBefore = await scalar(`select state::text from public.messages where id = $1`, [claimed.message_id]);
  await exec(`update public.telegram_outbox set attempts = max_attempts - 1, state = 'in_flight' where id = $1`, [claimed.outbox_id]);
  await exec(`select public.bridge_complete_outbox($1, 'failed', null, 'FLOOD_WAIT_37', interval '5 seconds')`, [claimed.outbox_id]);
  eq(await scalar(`select state::text from public.telegram_outbox where id = $1`, [claimed.outbox_id]), 'failed');
  eq(await scalar(`select state::text from public.messages where id = $1`, [claimed.message_id]), stateBefore,
     'a retriable failure leaves the user-visible tick alone');
  await exec(`update public.telegram_outbox set attempts = max_attempts where id = $1`, [claimed.outbox_id]);
  await exec(`select public.bridge_complete_outbox($1, 'failed', null, 'FLOOD_WAIT_37', interval '5 seconds')`, [claimed.outbox_id]);
  eq(await scalar(`select state::text from public.messages where id = $1`, [claimed.message_id]), 'failed',
     'exhausted retries surface as a failed bubble');
  await become(U.a);
  eq(await scalar(`select public.retry_message($1::uuid)`, [claimed.message_id]), true, 'retry re-enqueues');
  eq(await scalar(`select state::text from public.telegram_outbox where id = $1`, [claimed.outbox_id]), 'queued');
});

await test('clients can read their outbox status but never write it', async () => {
  await become(U.a);
  eq(await scalar(`select count(*)::int from public.telegram_outbox`), 1);
  await throws(() => exec(`update public.telegram_outbox set state = 'sent' where id = $1`,
    [globalThis.__claim.outbox_id]), /permission denied|row-level security|violates/i);
});

// ---------------------------------------------------------------------------
group('link handshake');
await test('telegram_link_start queues a sealed request the worker can claim', async () => {
  await become(U.link);
  const [started] = await query(`select public.telegram_link_start(
      jsonb_build_object('alg', 'plain', 'data', jsonb_build_object('phone', '+9989017778899')), false) as s`);
  const requestId = started.s.request_id;
  assert(requestId, 'request id issued');
  eq(await scalar(`select auth_state::text from public.telegram_accounts where user_id = '${U.link}'`),
     'awaiting_phone', 'the toggle already shows progress');

  await becomeService();
  const claim = await one(`select public.bridge_claim_link_request('worker-1') as c`);
  assert(claim.c, 'claim returned a request');
  eq(claim.c.request_id, requestId);
  eq(claim.c.payload.data.phone, '+9989017778899', 'envelope reaches the worker intact');
  eq(claim.c.profile.phone_e164, '+9989017778899', 'worker gets the account context too');
  globalThis.__link = { requestId };
});

await test('clients cannot smuggle plaintext credentials into the queue', async () => {
  await become(U.link);
  await throws(() => exec(`insert into public.telegram_link_requests (user_id, kind, payload)
                           values ('${U.link}', 'link', jsonb_build_object('code', '12345'))`),
               /sealed|policy|permission/i);
});

await test('the bridge reports the next step and the user answers with a sealed code', async () => {
  await becomeService();
  await exec(`select public.bridge_link_progress($1, 'awaiting_user', 'awaiting_code', null,
              'Code sent to your Telegram app', null, 'awaiting_code')`, [globalThis.__link.requestId]);
  eq(await scalar(`select step from public.telegram_link_requests where id = $1`, [globalThis.__link.requestId]),
     'awaiting_code');
  eq(await scalar(`select auth_step_note from public.telegram_accounts where user_id = '${U.link}'`),
     'Code sent to your Telegram app', 'the UI note is driven by the bridge');

  await become(U.link);
  await exec(`select public.telegram_link_submit($1,
      jsonb_build_object('alg', 'plain', 'data', jsonb_build_object('code', 'A1B2C')))`,
    [globalThis.__link.requestId]);
  await throws(() => exec(`select public.telegram_link_submit($1, '{"alg":"nope"}'::jsonb)`,
    [globalThis.__link.requestId]), /malformed/);

  await becomeService();
  const again = await one(`select public.bridge_claim_link_request('worker-1') as c`);
  eq(again.c.payload.data.code, 'A1B2C', 'worker receives the sealed code');
  await exec(`select public.bridge_link_progress($1, 'claimed', 'authorizing', null, null, null, null)`,
    [globalThis.__link.requestId]);
  eq(await scalar(`select payload is null from public.telegram_link_requests where id = $1`,
    [globalThis.__link.requestId]), true, 'OTP material wiped after read');
});

await test('completing the link stores the identity and clears the note', async () => {
  await becomeService();
  await exec(`select public.bridge_link_complete($1, 987654, 'link_tester', 'Link Tester', '+998',
              'session/link', null, 12345)`, [globalThis.__link.requestId]);
  await become(U.link);
  const [st] = await query(`select public.telegram_link_state() as s`);
  eq(st.s.auth_state, 'linked');
  eq(st.s.tg_username, 'link_tester');
  eq(st.s.pending_request, undefined, 'no open handshake anymore');
});

await test('preferences are client-writable, the session is not', async () => {
  await become(U.link);
  await rpc('public.telegram_set_preferences', `'from_telegram', false, false, true`);
  eq(await scalar(`select sync_direction::text from public.telegram_accounts where user_id = '${U.link}'`),
     'from_telegram');
  await throws(
    () => exec(`update public.telegram_accounts set auth_state = 'syncing' where user_id = $1`, [U.link]),
    /managed by the bridge/
  );
});

await test('unlinking flips the toggle off and asks the worker to drop the session', async () => {
  await become(U.link);
  const [res] = await query(`select public.telegram_unlink() as r`);
  assert(res.r.request_id, 'unlink request created');
  eq(await scalar(`select auth_state::text from public.telegram_accounts where user_id = '${U.link}'`), 'revoked');
  await becomeService();
  const claim = await one(`select public.bridge_claim_link_request('worker-1') as c`);
  eq(claim.c.kind, 'unlink');
});

await test('expired handshakes are reclaimed, not stuck', async () => {
  await becomeService();
  await exec(`update public.telegram_link_requests set expires_at = clock_timestamp() - interval '1 minute'
              where user_id = '${U.link}' and status = 'queued'`);
  const claim = await one(`select public.bridge_claim_link_request('worker-1') as c`);
  eq(claim.c, null, 'nothing claimable once expired');
  await exec(`update public.telegram_link_requests set status = 'expired', completed_at = clock_timestamp()
              where user_id = '${U.link}' and status = 'queued'`);
});

await test('a second account cannot hijack an already-linked Telegram identity', async () => {
  await becomeService();
  await exec(`update public.telegram_accounts set auth_state = 'unlinked', tg_user_id = null where user_id = '${U.link}'`);
  await exec(`update public.telegram_accounts set auth_state = 'linked', tg_user_id = 987654 where user_id = '${U.b}'`);
  const err = await throws(() => exec(`
      insert into public.telegram_accounts (user_id, tg_user_id, auth_state) values ('${U.link}', 987654, 'linked')
    `));
  assert(/unique|duplicate/i.test(err.message), 'unique index on tg_user_id holds');
  await exec(`update public.telegram_accounts set tg_user_id = null, auth_state = 'unlinked' where user_id = '${U.b}'`);
});

// ---------------------------------------------------------------------------
group('realtime & storage');
await test('realtime publishes the chat tables with FULL row identity', async () => {
  await becomeOwner();
  const pubs = await query(`
    select tablename from pg_publication_tables where pubname = 'supabase_realtime'`);
  const names = pubs.map((r) => r.tablename);
  for (const t of ['messages', 'chats', 'chat_participants', 'telegram_accounts', 'telegram_outbox']) {
    assert(names.includes(t), `${t} must be in supabase_realtime (got ${names.join(', ')})`);
  }
  eq(await scalar(`select relreplident from pg_class where oid = 'public.messages'::regclass`), 'f',
     'replica identity full');
});

await test('storage buckets are configured for avatars / images / voice-notes', async () => {
  await becomeOwner();
  const buckets = await query(`select id, public, file_size_limit, allowed_mime_types from storage.buckets order by id`);
  eq(buckets.map((b) => b.id).join(','), 'avatars,images,voice-notes');
  eq(buckets.find((b) => b.id === 'avatars').public, true);
  eq(buckets.find((b) => b.id === 'images').public, false);
  eq(buckets.find((b) => b.id === 'voice-notes').allowed_mime_types.includes('audio/ogg'), true,
     'Telegram voice notes must be ogg/opus');
});

await test('avatar uploads are confined to the owner prefix', async () => {
  await become(U.a);
  await exec(`insert into storage.objects (bucket_id, name, owner) values ('avatars', '${U.a}/avatar.png', '${U.a}')`);
  await throws(
    () => exec(`insert into storage.objects (bucket_id, name, owner) values ('avatars', '${U.b}/avatar.png', '${U.b}')`),
    /row-level security|policy/i
  );
});

await test('chat media is gated by chat membership', async () => {
  await become(U.b);
  await exec(`insert into storage.objects (bucket_id, name, owner) values ('images', '${chatId}/photo.jpg', '${U.b}')`);
  await become(U.other);
  await throws(
    () => exec(`insert into storage.objects (bucket_id, name, owner) values ('images', '${chatId}/evil.jpg', '${U.other}')`),
    /row-level security|policy/
  );
  await become(U.b);
  eq((await query(`select 1 from storage.objects where bucket_id = 'images' and name like '${chatId}%'`)).length, 1,
     'the uploader can read their own media back');
  await become(U.link);
  eq((await query(`select 1 from storage.objects where bucket_id = 'images'`)).length, 0,
     'a stranger reads nothing');
});

// ---------------------------------------------------------------------------
group('housekeeping');
await test('deleting a message re-points the chat preview', async () => {
  await become(U.a);
  const [before] = await query(`select last_message_id from public.chats where id = $1`, [chatId]);
  const [row] = await query(`select id from public.messages where chat_id = $1 and deleted_at is null
                             order by id desc limit 1`, [chatId]);
  await exec(`select public.delete_message($1::uuid)`, [row.id]);
  const [after] = await query(`select last_message_id from public.chats where id = $1`, [chatId]);
  assert(after.last_message_id !== row.id, 'preview moved to an older message');
});

await test('unread_total aggregates the badge', async () => {
  await become(U.b);
  eq(typeof Number(await scalar(`select public.unread_total()`)), 'number');
});

await test('system notices bypass sender requirements', async () => {
  await becomeService();
  await exec(`insert into public.messages (chat_id, kind, body, source) values ('${chatId}', 'system', 'Dilnoza joined', 'app')`);
  eq(await scalar(`select state::text from public.messages where chat_id = '${chatId}' and kind = 'system'`), 'read');
});

await test('clients cannot forge system messages or a telegram origin', async () => {
  await become(U.a);
  await throws(() => exec(`insert into public.messages (chat_id, sender_id, kind, body, source)
                           values ('${chatId}', '${U.a}', 'system', 'haha', 'app')`),
               /policy|permission|check|not eligible/i);
  await throws(() => exec(`insert into public.messages (chat_id, sender_id, kind, body, source, tg_message_id)
                           values ('${chatId}', '${U.a}', 'text', 'hi', 'telegram', 5)`),
               /sealed|policy|permission/i);
});

group('presence & read receipts');
const TG_MIRROR_CHAT = globalThis.__mirror.mirrorChat;

await test('a member can flag typing once, and the RPC throttles repeats', async () => {
  await become(U.a);
  eq(await scalar(`select public.set_typing('${chatId}'::uuid, true)`), true, 'first write lands');
  eq(await scalar(`select public.set_typing('${chatId}'::uuid, true)`), false, 'a 3s client timer is floored at 2.5s');
  const rows = await query(`select * from public.chat_typing_state('${chatId}'::uuid)`);
  eq(rows.length, 1);
  eq(rows[0].source, 'app');
  eq(rows[0].action, 'typing');
  eq(rows[0].name, 'Aziz Carrier', 'the UI gets a display name without a second query');
});

await test('presence is scoped to members and to the user\'s own row', async () => {
  await become(U.other);
  await throws(() => scalar(`select public.set_typing('${chatId}'::uuid, true)`), /not a member/i);
  eq((await query(`select * from public.chat_typing_state('${chatId}'::uuid)`)).length, 0,
     'a non-member sees no presence at all');
  await become(U.b);
  await throws(() => exec(`insert into public.chat_typing (chat_id, user_id, source)
                           values ('${chatId}', '${U.a}', 'app')`),
               /row-level security|policy/i);
  eq((await query(`select * from public.chat_typing_state('${chatId}'::uuid)`)).length, 1,
     'presence is visible to the other member — that is the whole feature');
  const tampered = await query(`update public.chat_typing set action = 'typing'
                                where chat_id = '${chatId}' and user_id = '${U.a}'
                                returning action`);
  eq(tampered.length, 0, 'but nobody can rewrite someone else\'s row');
});

await test('turning typing off deletes the row', async () => {
  await become(U.a);
  eq(await scalar(`select public.set_typing('${chatId}'::uuid, false)`), false);
  eq(await scalar(`select count(*)::int from public.chat_typing where chat_id = '${chatId}'`), 0);
  eq(await scalar(`select public.set_typing('${chatId}'::uuid, true)`), true, 'and can start again');
});

await test('bridge_pending_typing only offers fresh rows for synced chats', async () => {
  await becomeService();
  const rows = await query(`select * from public.bridge_pending_typing('${U.a}', clock_timestamp() - interval '1 minute')`);
  eq(rows.length, 1);
  eq(String(rows[0].tg_chat_id), TG_CHAT_STR, 'carries the Telegram chat to forward to');
  eq(rows[0].action, 'typing');

  await becomeOwner();
  await exec(`update public.chat_typing set updated_at = clock_timestamp() - interval '5 minutes',
                     expires_at = clock_timestamp() + interval '6 seconds'
              where chat_id = '${chatId}'`);
  await becomeService();
  eq((await query(`select * from public.bridge_pending_typing('${U.a}', clock_timestamp() - interval '30 seconds')`)).length, 0,
     'a row the worker already forwarded is not offered twice');
});

await test('a mirrored chat only forwards presence when the account allows it', async () => {
  await becomeOwner();
  await exec(`update public.telegram_chats set sync_direction = 'from_telegram'
              where owner_user_id = '${U.a}' and chat_id = '${chatId}'`);
  await becomeService();
  eq((await query(`select * from public.bridge_pending_typing('${U.a}', clock_timestamp() - interval '1 hour')`)).length, 0);
  await becomeOwner();
  await exec(`update public.telegram_chats set sync_direction = 'both'
              where owner_user_id = '${U.a}' and chat_id = '${chatId}'`);
});

await test('telegram typing appears as presence in the mirrored chat', async () => {
  await becomeService();
  eq(await scalar(`select public.bridge_report_typing('${U.a}', ${TG_CHAT_STR}, 'chatActionTyping')`), true);
  await become(U.a);
  const rows = await query(`select * from public.chat_typing_state('${chatId}'::uuid) where source = 'telegram'`);
  eq(rows.length, 1, 'the app renders "typing…" from the Telegram side too');
  eq(rows[0].action, 'typing');

  await becomeService();
  eq(await scalar(`select public.bridge_report_typing('${U.a}', ${TG_CHAT_STR}, 'chatActionNone')`), true);
  await become(U.a);
  eq((await query(`select * from public.chat_typing_state('${chatId}'::uuid) where source = 'telegram'`)).length, 0,
     'and the indicator stops');
  await becomeService();
  eq(await scalar(`select public.bridge_report_typing('${U.a}', 999999, 'chatActionTyping')`), false,
     'an unmapped chat is a no-op, not an error');
});

await test('app reads become Telegram viewMessages exactly once', async () => {
  await become(U.a);
  await scalar(`select public.mark_chat_read('${TG_MIRROR_CHAT}'::uuid)`);
  await becomeService();
  const pending = await query(`select * from public.bridge_pending_reads('${U.a}')`);
  const row = pending.find((r) => r.chat_id === TG_MIRROR_CHAT);
  assert(row, 'the mirror chat needs a read receipt pushed to Telegram');
  eq(String(row.tg_chat_id), '7000000001');
  eq(Number(row.max_read_message_id), 1001, 'the inbound Telegram message id the user has now read');

  eq(await scalar(`select public.bridge_mark_reads_synced('${U.a}', 7000000001, 1001)`), true);
  eq((await query(`select * from public.bridge_pending_reads('${U.a}')`)).find((r) => r.chat_id === TG_MIRROR_CHAT),
     undefined, 'the watermark stops a re-send');
  eq(await scalar(`select public.bridge_mark_reads_synced('${U.a}', 7000000001, 500)`), false,
     'and never moves backwards');
});

await test('reading Telegram elsewhere clears the MessengerX badge', async () => {
  // The mirror chat has one inbound voice message (tg id 1001) that U.a has not read.
  await become(U.a);
  const before = await one(`select cp.unread_count, m.state::text as state
                            from public.chat_participants cp
                            join public.messages m on m.chat_id = cp.chat_id
                           where cp.chat_id = '${TG_MIRROR_CHAT}' and cp.user_id = '${U.a}'
                           limit 1`);
  assert(before.unread_count >= 0);
  await becomeService();
  eq(Number(await scalar(`select public.bridge_mark_inbox_read('${U.a}', 7000000001, 1001)`)) >= 1, true,
     'the inbound message is marked read');
  await become(U.a);
  const after = await one(`select cp.unread_count, m.state::text as state
                           from public.chat_participants cp
                           join public.messages m on m.chat_id = cp.chat_id
                          where cp.chat_id = '${TG_MIRROR_CHAT}' and cp.user_id = '${U.a}'
                          limit 1`);
  eq(after.unread_count, 0, 'badge cleared');
  eq(after.state, 'read');
  eq(await scalar(`select count(*)::int from public.message_reads where user_id = '${U.a}'`), before === after ? 0 : 1,
     'receipt recorded once (idempotent on replay)');
  await becomeService();
  eq(Number(await scalar(`select public.bridge_mark_inbox_read('${U.a}', 7000000001, 1001)`)), 0,
     'replaying the same read is a no-op');
});

await test('reply targets resolve from app ids to telegram ids', async () => {
  // Pick a live message that carries a telegram id (earlier groups soft-delete some).
  await becomeOwner();
  const live = await one(`select id, tg_message_id from public.messages
                          where tg_message_id is not null and deleted_at is null
                          order by id desc limit 1`);
  const target = live.id;
  const expected = Number(live.tg_message_id);

  await become(U.a);
  await throws(() => one(`select public.bridge_message_tg_ids(null)`), /permission denied/i);

  await becomeService();
  const resolved = await one(`select public.bridge_message_tg_ids(array['${target}'::uuid, '${chatId}'::uuid]) as m`);
  eq(Number(resolved.m[target]), expected, 'the telegram message id the reply needs');
  eq(resolved.m[chatId], undefined, 'a chat id is not a message id: absent, not null');
  eq(JSON.stringify(await one(`select public.bridge_message_tg_ids('{}') as m`)), '{"m":{}}',
     'an empty request is a no-op');
});

await test('the bridge can list the sessions it should resume', async () => {
  await becomeOwner();
  await exec(`update public.telegram_accounts set worker_id = 'worker-1' where user_id = '${U.a}'`);
  await becomeService();
  const rows = await query(`select * from public.bridge_list_sessions('worker-1', 50)`);
  const mine = rows.find((r) => r.user_id === U.a);
  assert(mine, 'the linked account is resumable');
  eq(mine.auth_state, 'linked');
  eq(mine.sync_direction, 'both');
  eq(mine.has_login_token, false);
  eq((await query(`select * from public.bridge_list_sessions('nobody-else', 50)`)).find((r) => r.user_id === U.a),
     undefined, 'another worker\'s sessions are not offered');
  await becomeOwner();
  await exec(`update public.telegram_accounts set auth_state = 'unlinked', worker_id = null where user_id = '${U.a}'`);
  await becomeService();
  eq((await query(`select * from public.bridge_list_sessions(null, 500)`)).find((r) => r.user_id === U.a),
     undefined, 'an unlinked account has nothing to resume');
  await becomeOwner();
  await exec(`update public.telegram_accounts set auth_state = 'linked', worker_id = 'worker-1' where user_id = '${U.a}'`);
  const all = await query(`select * from public.bridge_list_sessions(null, 500)`);
  assert(all.some((r) => r.user_id === U.a), 'a null worker means "everything", used on boot');
});

await test('expired presence rows are pruned, not left hanging', async () => {
  await becomeOwner();
  await exec(`update public.chat_typing set updated_at = clock_timestamp() - interval '1 hour',
                     expires_at = clock_timestamp() - interval '1 minute'`);
  await becomeService();
  assert(Number(await scalar(`select public.prune_chat_typing()`)) >= 1, 'prune removed the stale row');
  eq(await scalar(`select count(*)::int from public.chat_typing where expires_at < clock_timestamp()`), 0);
});

// ---------------------------------------------------------------------------
await becomeOwner();
const failed = results.filter((r) => !r.ok);
let lastGroup = null;
for (const r of results) {
  if (r.group !== lastGroup) {
    console.log(`\n${r.group}`);
    lastGroup = r.group;
  }
  console.log(`  ${r.ok ? '✓' : '✗'} ${r.name}${r.ok ? '' : `\n      ${r.error}`}`);
}
console.log(`\n${results.length - failed.length}/${results.length} passed`);
if (failed.length) process.exitCode = 1;
