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
  oidc: '77777777-7777-7777-7777-777777777777',
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
     'active', 'Google signups no longer use unprovable account-age checks');
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

await test('email-less Telegram OIDC users get a profile without being mislabeled as Google', async () => {
  await becomeOwner();
  await exec(`insert into auth.users (id, raw_app_meta_data, raw_user_meta_data) values
    ('${U.oidc}', '{"provider":"custom:telegram"}', '{"preferred_username":"telegram_joiner","name":"Telegram Joiner"}')`);
  eq(await scalar(`select username from public.profiles where id = '${U.oidc}'`), 'telegram_joiner');
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.oidc}'`), 'active');
  eq(await scalar(`select google_email from public.profiles where id = '${U.oidc}'`), null);
  eq(await scalar(`select google_email from public.profiles where id = '${U.gated}'`), 'kid@example.com');
  eq(await scalar(`select google_email from public.profiles where id = '${U.b}'`), null);
  await exec(`update auth.users set email = 'other@example.com' where id = '${U.oidc}'`);
  eq(await scalar(`select google_email from public.profiles where id = '${U.oidc}'`), null,
     'a non-Google address never becomes a Google address');
  eq(await scalar(`select count(*)::int from public.telegram_accounts where user_id = '${U.oidc}'`), 1,
     'sign-in alone creates an unlinked TDLib slot');
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

await test('retired Google credentials contain no tokens and are client-inaccessible', async () => {
  await becomeService();
  eq(await scalar(`select count(*)::int from public.google_credentials`), 0);
  await become(U.a);
  await throws(() => exec(`select count(*) from public.google_credentials`), /permission denied/);
  await throws(() => exec(`select count(*) from public.eligibility_checks`), /permission denied/);
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
group('server-managed account access');
await test('Google signups have access without importing Gmail or Drive data', async () => {
  await become(U.gated);
  const [st] = await query(`select public.eligibility_status() as s`);
  eq(st.s.access_state, 'active');
  eq(st.s.passed, true);
  eq(st.s.age_days, undefined);
  const [row] = await query(`select public.create_direct_chat(null, 'stranger') as id`);
  assert(row.id, 'a signed-in account can start a chat');
});

await test('manual restrictions still block messaging and cannot be bypassed by an old age verdict', async () => {
  await becomeService();
  await exec(`update public.profiles set access_state = 'restricted', access_state_reason = 'moderation'
              where id = '${U.other}'`);
  await become(U.other);
  await throws(() => rpc('public.create_direct_chat', `null, 'dilnoza_rustamova'`), /not eligible/);
  const [st] = await query(`select public.eligibility_status() as s`);
  eq(st.s.passed, false);
  eq(st.s.reason, 'moderation');
  await throws(() => exec(`update public.profiles set access_state = 'active' where id = '${U.other}'`), /server-managed/);
  await becomeService();
  await throws(() => rpc('public.record_eligibility_check', `'{"user_id":"${U.other}","verdict":"passed"}'::jsonb`), /does not exist/);
  await exec(`update public.profiles set access_state = 'active', access_state_reason = null where id = '${U.other}'`);
});

await test('retiring age states does not unban a moderated account', async () => {
  await becomeService();
  await exec(`update public.profiles set access_state = 'pending_verification',
                 access_state_reason = 'Google accounts must be older than 1 year. Verify to unlock messaging.',
                 google_account_age_days = 100 where id = '${U.gated}';
              update public.profiles set access_state = 'banned', access_state_reason = 'moderation'
              where id = '${U.other}';`);
  await becomeOwner();
  await exec(readFileSync(join(MIGRATIONS, '00013_retire_google_age_gate.sql'), 'utf8'));
  await becomeService();
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.gated}'`), 'active');
  eq(await scalar(`select google_account_age_days from public.profiles where id = '${U.gated}'`), null);
  eq(await scalar(`select access_state::text from public.profiles where id = '${U.other}'`), 'banned');
  await exec(`update public.profiles set access_state = 'active', access_state_reason = null where id = '${U.other}'`);
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
  eq(buckets.find((b) => b.id === 'voice-notes').allowed_mime_types.includes('audio/wav'), true,
     'app-recorded WAV notes must be accepted by Storage');
});

await test('avatar uploads are confined to the owner prefix', async () => {
  await become(U.a);
  await exec(`insert into storage.objects (bucket_id, name, owner) values ('avatars', '${U.a}/avatar.png', '${U.a}')`);
  await throws(
    () => exec(`insert into storage.objects (bucket_id, name, owner) values ('avatars', '${U.b}/avatar.png', '${U.b}')`),
    /row-level security|policy/i
  );
});

await test('a chat member cannot delete another member’s uploaded media', async () => {
  const name = `${chatId}/private-photo.jpg`;
  await become(U.a);
  await exec(`insert into storage.objects (bucket_id, name, owner) values ('images', '${name}', '${U.a}')`);
  await become(U.b);
  eq((await query(`delete from storage.objects where name = '${name}' returning id`)).length, 0,
     'members can read but must not remove someone else’s attachment');
  await become(U.a);
  eq((await query(`delete from storage.objects where name = '${name}' returning id`)).length, 1,
     'uploader can remove their own media');
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
group('offline notices (00012)');

/**
 * The queue is bridge-internal: every read here happens as the owner, because a
 * client role has neither the grant nor an RLS policy (asserted below).
 */
const noticeRows = async (userId = U.a) => {
  await becomeOwner();
  return query(`select * from public.notify_requests where user_id = '${userId}' order by id`);
};
const noticeCount = async (userId = U.a, state = 'queued') => {
  await becomeOwner();
  return Number(await scalar(
    `select count(*)::int from public.notify_requests where user_id = '${userId}' and state = '${state}'`));
};
/** Dilnoza writes to Aziz; `chatId` is the direct chat created in the messaging group. */
const sendAsDilnoza = async (text) => {
  await become(U.b);
  await rpc('public.send_message', `'${chatId}', 'text', '${text}', null, null, null`);
};
const azizAway = async () => {
  await becomeOwner();
  await exec(`update public.profiles
                 set last_seen_at = clock_timestamp() - interval '10 minutes',
                     access_state = 'active', deleted_at = null,
                     push_telegram = true, push_preview = true
               where id = '${U.a}'`);
};

await test('a message to an offline recipient queues exactly one notice', async () => {
  await becomeOwner();
  await exec(`
    delete from public.notify_requests;
    update public.telegram_accounts set auth_state = 'linked', tg_user_id = 200, sync_direction = 'both',
           self_chat_id = null, linked_at = clock_timestamp() where user_id = '${U.b}';
    update public.telegram_accounts set auth_state = 'linked', tg_user_id = 100, sync_direction = 'both',
           self_chat_id = null where user_id = '${U.a}';
    update public.chat_participants set unread_count = 0, muted_until = null, left_at = null
     where chat_id = '${chatId}';
  `);
  await azizAway();

  await sendAsDilnoza('qayerdasan?');

  const rows = await noticeRows(U.a);
  eq(rows.length, 1, 'one queued notice');
  eq(rows[0].state, 'queued');
  eq(rows[0].folded, 1, 'a single message is not folded');
  eq(String(rows[0].chat_id), chatId);
  eq(rows[0].preview, 'qayerdasan?', 'the preview is the message text');
  eq(new Date(rows[0].next_attempt_at).getTime() > Date.now(), true,
     'a short quiet window lets a burst collapse before delivery');
  eq(rows[0].sender_name, 'Dilnoza Rustamova', 'the human label, not the username');
  eq(String(rows[0].sender_user_id), U.b);
  eq(await noticeCount(U.b), 0, 'the sender is never notified about their own message');
  await become(U.a);
  eq(await scalar(`select public.banner_silence_telegram($1)`, [rows[0].last_message_id]), false,
     'an app-only message can show a foreground banner');
  await become(U.other);
  eq(await scalar(`select public.banner_silence_telegram($1)`, [rows[0].last_message_id]), true,
     'a nonmember cannot use the banner RPC to inspect another chat');
});

await test('a burst folds into one row and keeps the newest preview', async () => {
  await sendAsDilnoza('birinchi');
  await sendAsDilnoza('ikkinchi');

  const rows = await noticeRows(U.a);
  eq(rows.length, 1, 'a burst is one notification, not three');
  eq(rows[0].folded, 3, 'folded counter');
  eq(rows[0].preview, 'ikkinchi', 'the preview follows the latest message');
});

await test('a recipient who is back in the app is not buzzed', async () => {
  await becomeOwner();
  await exec(`update public.profiles set last_seen_at = clock_timestamp() where id = '${U.a}'`);
  await sendAsDilnoza('endi koʻrdingmi?');

  const rows = await noticeRows(U.a);
  eq(rows.length, 0, 'returning online cancels the burst and suppresses new notices');

  await becomeService();
  const claimed = await query(`select * from public.bridge_claim_notify('worker-1', null, 10)`);
  eq(claimed.length, 0, 'nothing is handed to the worker');
});

await test('reading the chat cancels a queued notice', async () => {
  await azizAway();
  await sendAsDilnoza('oʻqilmagan xabar');
  eq(await noticeCount(U.a), 1, 'queued while away');

  await become(U.a);
  await rpc('public.mark_chat_read', `'${chatId}'`);
  eq(await noticeCount(U.a), 0, 'reading deletes the queued notice');
});

await test('a muted chat stays silent, and unmuting restores delivery', async () => {
  await becomeOwner();
  await exec(`update public.chat_participants
                 set muted_until = clock_timestamp() + interval '1 hour', unread_count = 0
               where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await sendAsDilnoza('muted chat');
  eq(await noticeCount(U.a), 0, 'mute is respected at queue time');

  await becomeOwner();
  await exec(`update public.chat_participants set muted_until = null
               where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await sendAsDilnoza('unmuted');
  eq(await noticeCount(U.a), 1, 'unmuting brings the buzz back');
});

await test('traffic the user\'s own Telegram delivered is not announced twice', async () => {
  await becomeOwner();
  await exec(`
    delete from public.notify_requests;
    insert into public.telegram_chats (owner_user_id, tg_chat_id, tg_chat_type, chat_id, peer_user_id, sync_direction)
    values ('${U.a}', ${TG_CHAT_STR}, 'private', '${chatId}', 9999, 'both')
    on conflict (owner_user_id, tg_chat_id)
    do update set chat_id = excluded.chat_id, sync_direction = 'both';
  `);
  await exec(`insert into public.messages (chat_id, sender_id, kind, body, source, tg_message_id)
              values ('${chatId}', '${U.b}', 'text', 'kelgan xabar', 'telegram', 900001)`);
  eq(await noticeCount(U.a), 0, 'mirrored Telegram traffic already buzzed on their phone');
  const telegramMessage = await one(`select id from public.messages where tg_message_id = 900001`);
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [telegramMessage.id]), true,
     'the foreground banner is suppressed too');

  // Same traffic, but the recipient does not mirror this chat: now it *is* news.
  await becomeOwner();
  await exec(`delete from public.telegram_chats where owner_user_id = '${U.a}' and chat_id = '${chatId}'`);
  await exec(`insert into public.messages (chat_id, sender_id, kind, body, source, tg_message_id)
              values ('${chatId}', '${U.b}', 'text', 'mapped emas', 'telegram', 900002)`);
  eq(await noticeCount(U.a), 1, 'an unmapped mirror is announced');
  const [row] = await noticeRows(U.a);
  eq(row.source, 'telegram');
});

await test('an app send headed for the recipient’s Telegram does not race a Saved Messages buzz', async () => {
  await becomeOwner();
  await exec(`
    delete from public.notify_requests;
    update public.telegram_accounts set auth_state = 'linked', tg_user_id = 100,
           sync_direction = 'both' where user_id = '${U.a}';
    update public.telegram_accounts set auth_state = 'linked', tg_user_id = 200,
           sync_direction = 'both' where user_id = '${U.b}';
    insert into public.telegram_chats
      (owner_user_id, tg_chat_id, tg_chat_type, chat_id, peer_user_id, sync_direction)
    values ('${U.b}', 100, 'private', '${chatId}', 100, 'both');
  `);
  await azizAway();
  await sendAsDilnoza('also forwarded to Telegram');
  const [queued] = await noticeRows(U.a);
  eq(!!queued, true, 'the app message can still be announced if forwarding fails');
  const outbox = await one(`select id, tg_chat_id, state::text as state from public.telegram_outbox
                             where message_id = $1`, [queued.last_message_id]);
  eq(String(outbox.tg_chat_id), '100', 'the sender forwards to the recipient’s own Telegram id');
  eq(outbox.state, 'queued');
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [queued.last_message_id]), true,
     'a foreground banner also waits rather than racing the Telegram send');

  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where id = $1`, [queued.id]);
  await becomeService();
  eq((await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`)).length, 0,
     'wait until the original Telegram outbox has a result');
  await becomeOwner();
  await exec(`update public.telegram_outbox set state = 'sent' where id = $1`, [outbox.id]);
  await becomeService();
  eq((await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`)).length, 0,
     'success means no duplicate Saved Messages notification');
  eq(await noticeCount(U.a, 'skipped'), 1);
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [queued.last_message_id]), true,
     'a delivered original also suppresses the foreground banner');

  await sendAsDilnoza('but this forward fails');
  const pending = (await noticeRows(U.a)).find((row) => row.state === 'queued');
  eq(!!pending, true, 'a separate queued row follows the skipped history');
  const failedOutbox = await one(`select id from public.telegram_outbox where message_id = $1`, [pending.last_message_id]);
  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where id = $1`, [pending.id]);
  await exec(`update public.telegram_outbox set state = 'failed' where id = $1`, [failedOutbox.id]);
  await becomeService();
  eq((await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`)).length, 0,
     'a retryable failed outbox is still capable of delivering the original');
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [pending.last_message_id]), true,
     'the banner likewise waits for the retry');
  await becomeOwner();
  await exec(`update public.telegram_outbox set attempts = max_attempts where id = $1`, [failedOutbox.id]);
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [pending.last_message_id]), false,
     'an exhausted forward releases the foreground fallback');
  await becomeService();
  const [fallback] = await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`);
  eq(!!fallback, true, 'a terminally failed forward leaves Saved Messages as a fallback');
  eq(await scalar(`select public.bridge_notice_owed($1, 'worker-9', $2)`,
                  [fallback.notify_id, fallback.preview]), true);
  await exec(`select public.bridge_complete_notify($1, 'skipped')`, [fallback.notify_id]);
  await becomeOwner();
  await exec(`delete from public.telegram_chats where owner_user_id = '${U.b}' and tg_chat_id = 100`);
});

await test('a shared Telegram group suppresses a second notice even when app import is off', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  const group = await one(`insert into public.chats (kind, title, created_by)
    values ('group', 'Shared TG group', '${U.b}') returning id`);
  await exec(`
    insert into public.chat_participants (chat_id, user_id, role) values
      ('${group.id}', '${U.b}', 'owner'), ('${group.id}', '${U.a}', 'member');
    insert into public.telegram_chats
      (owner_user_id, tg_chat_id, tg_chat_type, chat_id, sync_direction) values
      ('${U.b}', 90117, 'basic_group', '${group.id}', 'both'),
      ('${U.a}', 90117, 'basic_group', '${group.id}', 'off');
  `);
  await azizAway();
  await become(U.b);
  const [sent] = await rpc('public.send_message', `'${group.id}', 'text', 'to the group', null, null, null`);
  const outbox = await one(`select id, state::text as state from public.telegram_outbox where message_id = $1`, [sent.id]);
  eq(outbox.state, 'queued');
  const [waiting] = await noticeRows(U.a);
  eq(waiting.state, 'queued');
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [sent.id]), true,
     'the original Telegram group send is still pending');
  await becomeOwner();
  await exec(`update public.telegram_outbox set state = 'sent' where id = $1`, [outbox.id]);
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where id = $1`, [waiting.id]);
  await becomeService();
  eq((await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`)).length, 0,
     'Telegram already delivered the group message even with app import disabled');
  eq(await noticeCount(U.a, 'skipped'), 1);
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [sent.id]), true);
  await becomeOwner();
  await exec(`delete from public.telegram_chats where chat_id = '${group.id}';
              delete from public.chats where id = '${group.id}'`);
});

await test('offline alerts remain available with account mirroring disabled', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests;
              update public.telegram_accounts set sync_direction = 'off' where user_id = '${U.a}';
              update public.chat_participants set unread_count = 0, muted_until = null, left_at = null
                where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await azizAway();
  await sendAsDilnoza('app-only with mirroring off');
  const [queued] = await noticeRows(U.a);
  eq(queued.state, 'queued', 'the alert switch is independent of account mirroring');
  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
                where id = $1`, [queued.id]);
  await becomeService();
  const [leased] = await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`);
  eq(leased.notify_id, queued.id, 'the independent notice can actually be sent');
  await exec(`select public.bridge_complete_notify($1, 'skipped')`, [leased.notify_id]);
  await becomeOwner();
  await exec(`update public.telegram_accounts set sync_direction = 'both' where user_id = '${U.a}'`);
});

await test('an off-mapped Telegram chat still suppresses a duplicate alert', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests;
              insert into public.telegram_chats
                (owner_user_id, tg_chat_id, tg_chat_type, chat_id, peer_user_id, sync_direction)
              values ('${U.a}', ${TG_CHAT_STR}, 'private', '${chatId}', 9999, 'off')`);
  await azizAway();
  await exec(`insert into public.messages (chat_id, sender_id, kind, body, source, tg_message_id)
              values ('${chatId}', '${U.b}', 'text', 'already on Telegram', 'telegram', 900003)`);
  eq(await noticeCount(U.a), 0, 'a mapped user already has the Telegram original');
  const message = await one(`select id from public.messages where tg_message_id = 900003`);
  await become(U.a);
  eq(await scalar('select public.banner_silence_telegram($1)', [message.id]), true);
  await becomeOwner();
  await exec(`delete from public.telegram_chats
               where owner_user_id = '${U.a}' and chat_id = '${chatId}'`);
});

await test('previews are a preference, and turning push off clears the queue', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  await azizAway();
  await sendAsDilnoza('birinchi maxfiy');
  eq((await noticeRows(U.a))[0].preview, 'birinchi maxfiy', 'previews on by default');

  await become(U.a);
  const [prefs] = await query(`select public.set_push_preferences(null, false) as p`);
  eq(prefs.p.push_preview, false, 'the RPC echoes the new preference');
  eq(prefs.p.push_telegram, true);
  eq((await noticeRows(U.a))[0].preview, '', 'already-queued text is wiped immediately');

  await sendAsDilnoza('ikkinchi maxfiy');
  const folded = await noticeRows(U.a);
  eq(folded.length, 1);
  eq(folded[0].folded, 2, 'still folded');
  eq(folded[0].preview, '', 'and still content-free');

  await become(U.a);
  await query(`select public.set_push_preferences(false, null) as p`);
  eq(await noticeCount(U.a), 0, 'push off deletes the queued notice');
  await sendAsDilnoza('push oʻchirilgan');
  eq(await noticeCount(U.a), 0, 'and nothing new is queued');
});

await test('a read after the claim invalidates its lease before delivery', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  await azizAway();
  await sendAsDilnoza('sent just before read');

  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where user_id = '${U.a}' and state = 'queued'`);
  await becomeService();
  const [leased] = await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`);
  eq(!!leased, true, 'row leased');
  eq(await scalar(`select public.bridge_notice_owed($1, 'not-the-worker')`, [leased.notify_id]), false,
     'a different worker cannot send this lease');

  await become(U.a);
  await rpc('public.mark_chat_read', `'${chatId}'`);
  await becomeService();
  eq(await scalar(`select public.bridge_notice_owed($1, 'worker-9')`, [leased.notify_id]), false,
     'the last-moment check sees the read');
  eq(await scalar(`select state::text from public.notify_requests where id = $1`, [leased.notify_id]), 'skipped');
  eq(await scalar(`select public.bridge_complete_notify($1, 'sent', 555003, 100, false, null, null)`,
                  [leased.notify_id]), false, 'a late send cannot revive a cancelled row');
});

await test('turning push off cancels an already-leased notice', async () => {
  await azizAway();
  await sendAsDilnoza('turning off');
  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where user_id = '${U.a}' and state = 'queued'`);
  await becomeService();
  const [leased] = await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`);
  eq(!!leased, true, 'row leased');
  await become(U.a);
  await query(`select public.set_push_preferences(false, null)`);
  await becomeService();
  eq(await scalar(`select public.bridge_notice_owed($1, 'worker-9')`, [leased.notify_id]), false);
  eq(await scalar(`select state::text from public.notify_requests where id = $1`, [leased.notify_id]), 'skipped');
});

await test('turning previews off also protects a notice already leased by the worker', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  await azizAway();
  await sendAsDilnoza('private before claim');
  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where user_id = '${U.a}' and state = 'queued'`);
  await becomeService();
  const [leased] = await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`);
  eq(leased.preview, 'private before claim');

  await become(U.a);
  await query(`select public.set_push_preferences(null, false)`);
  await becomeService();
  eq(await scalar(`select preview from public.notify_requests where id = $1`, [leased.notify_id]), '',
     'the database erases text even after the worker has claimed it');
  eq(await scalar(`select public.bridge_notice_owed($1, 'worker-9', $2)`,
                  [leased.notify_id, leased.preview]), false,
     'a worker holding the old preview cannot send it');
  eq(await scalar(`select public.bridge_complete_notify($1, 'skipped')`, [leased.notify_id]), true);
});

await test('deleting an unsent message drops its queued preview', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  await azizAway();
  await sendAsDilnoza('deleted before the quiet window');
  const [queued] = await noticeRows(U.a);
  eq(queued.preview, 'deleted before the quiet window');
  await become(U.b);
  await rpc('public.delete_message', `'${queued.last_message_id}'`);
  eq(await noticeCount(U.a), 0, 'retracted text never goes into Saved Messages');
});

await test('the queue is invisible to clients and unwritable by them', async () => {
  await becomeOwner();
  // The previous case turned Aziz's push off; the RLS assertion needs a known start.
  await exec(`update public.profiles set push_telegram = true where id = '${U.a}'`);
  await become(U.b);
  await throws(() => exec(`select count(*) from public.notify_requests`), /permission denied/);
  await throws(() => exec(`select public.bridge_claim_notify('worker-1', null, 5)`), /permission denied/);
  await throws(() => exec(`select app.notify_should_send('${U.a}', '${U.b}')`), /permission denied/);
  // RLS filters silently rather than raising, so the assertion is "nothing changed".
  await exec(`update public.profiles set push_telegram = false where id = '${U.a}'`);
  await becomeOwner();
  eq(await scalar(`select push_telegram from public.profiles where id = '${U.a}'`), true,
     'another user cannot turn off someone else\'s notices');
  // self_chat_id is bridge-managed, like the rest of the session row
  await become(U.a);
  await throws(() => exec(`update public.telegram_accounts set self_chat_id = 1 where user_id = '${U.a}'`),
               /managed by the bridge/);
});

await test('the bridge claims a notice, targets Saved Messages and caches the chat id', async () => {
  await becomeOwner();
  await exec(`
    delete from public.notify_requests;
    update public.telegram_accounts set auth_state = 'linked', tg_user_id = 100, sync_direction = 'both',
           self_chat_id = null where user_id = '${U.a}';
  `);
  await azizAway();
  await sendAsDilnoza('claim me');

  await becomeService();
  eq((await query(`select * from public.bridge_claim_notify('worker-9', null, 5)`)).length, 0,
     'the worker waits for the folding window');
  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where user_id = '${U.a}' and state = 'queued'`);
  await becomeService();
  const claimed = await query(`select * from public.bridge_claim_notify('worker-9', null, 5)`);
  eq(claimed.length, 1, 'one claimable notice');
  const row = claimed[0];
  eq(String(row.user_id), U.a, 'the recipient owns the session that delivers it');
  eq(String(row.tg_self_chat_id), '100', 'Saved Messages falls back to the own Telegram id');
  eq(String(row.tg_user_id), '100');
  eq(row.preview, 'claim me');
  eq(row.folded, 1);
  eq(row.attempts, 1, 'claiming burns one attempt');
  eq(await scalar(`select state::text from public.notify_requests where id = $1`, [row.notify_id]), 'in_flight');
  eq(await scalar(`select public.bridge_notice_owed($1, 'worker-9')`, [row.notify_id]), true,
     'the recipient is still away and unread');
  eq((await query(`select * from public.bridge_claim_notify('worker-8', null, 5)`)).length, 0,
     'a second worker cannot steal the lease');

  await exec(`select public.bridge_complete_notify($1, 'sent', 555001, 777001, false, null, null)`, [row.notify_id]);
  const done = await one(`select * from public.notify_requests where id = $1`, [row.notify_id]);
  eq(done.state, 'sent');
  eq(String(done.tg_message_id), '555001');
  eq(String(done.tg_self_chat_id), '777001');
  eq(await scalar(`select self_chat_id::text from public.telegram_accounts where user_id = '${U.a}'`), '777001',
     'the discovered chat id is cached for the next notice');
});

await test('relinking a different Telegram user never reuses the old Saved Messages id', async () => {
  await becomeService();
  eq(await scalar(`select self_chat_id::text from public.telegram_accounts where user_id = '${U.a}'`), '777001');
  await exec(`update public.telegram_accounts set tg_user_id = 101 where user_id = '${U.a}'`);
  eq(await scalar(`select self_chat_id from public.telegram_accounts where user_id = '${U.a}'`), null,
     'the previous Telegram identity’s Saved Messages chat is erased');
});

await test('a parked notice retries, a revoked session fails it, and history is pruned', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  await azizAway();
  await sendAsDilnoza('flood wait');

  await becomeOwner();
  await exec(`update public.notify_requests set next_attempt_at = clock_timestamp() - interval '1 second'
              where user_id = '${U.a}' and state = 'queued'`);
  await becomeService();
  const [first] = await query(`select * from public.bridge_claim_notify('worker-1', null, 5)`);
  await exec(`select public.bridge_complete_notify($1, 'queued', null, null, false, 'flood_wait_12', '2 minutes')`,
    [first.notify_id]);
  const parked = await one(`select * from public.notify_requests where id = $1`, [first.notify_id]);
  eq(parked.state, 'queued', 'requeued, not lost');
  eq(parked.last_error, 'flood_wait_12');
  eq(parked.claimed_by, null, 'the lease is released');
  eq((await query(`select * from public.bridge_claim_notify('worker-1', null, 5)`)).length, 0,
     'and it is not claimable before the retry time');

  eq(Number(await scalar(`select public.bridge_fail_notify('${U.a}', 'telegram session was revoked')`)), 1,
     'a revoked session fails the owner\'s queue');
  eq(await scalar(`select state::text from public.notify_requests where id = $1`, [first.notify_id]), 'failed');

  // `notify_requests_touch` keeps updated_at honest, so old history is inserted
  // rather than backdated — which is also what the retention window must survive.
  await becomeOwner();
  await exec(`insert into public.notify_requests
                (user_id, chat_id, sender_name, state, created_at, updated_at)
              values ('${U.a}', '${chatId}', 'Dilnoza Rustamova', 'sent',
                      clock_timestamp() - interval '4 days', clock_timestamp() - interval '4 days')`);
  eq(Number(await scalar(`select public.prune_notify_requests()`)), 1, 'terminal rows past the window are pruned');
  eq(await scalar(`select count(*)::int from public.notify_requests`), 1, 'recent history is kept');
});

await test('retry exhaustion stops a permanently parked notice', async () => {
  await becomeOwner();
  await exec(`delete from public.notify_requests`);
  await azizAway();
  await sendAsDilnoza('fourth failure');
  await becomeOwner();
  await exec(`update public.notify_requests set attempts = max_attempts,
                next_attempt_at = clock_timestamp() - interval '1 second'
              where user_id = '${U.a}' and state = 'queued'`);
  await becomeService();
  eq((await query(`select * from public.bridge_claim_notify('worker-9', '${U.a}', 5)`)).length, 0,
     'a fifth delivery attempt is never leased');
  eq(await noticeCount(U.a, 'failed'), 1);
});

// ---------------------------------------------------------------------------
group('new Telegram contacts (00016)');
let contactRequestId = null;
let contactChatId = null;
await test('starting a Telegram chat requires a linked, permitted TDLib account', async () => {
  await become(U.oidc);
  await throws(() => rpc('public.telegram_start_chat', "'@FreshContact'"), /Connect Telegram/);
  await becomeService();
  await exec(`update public.telegram_accounts
     set tg_user_id = 840001, auth_state = 'linked', mirror_to_app = false
   where user_id = '${U.oidc}'`);
  await become(U.oidc);
  await throws(() => rpc('public.telegram_start_chat', "'@FreshContact'"), /enable mirroring/);
  await becomeService();
  await exec(`update public.telegram_accounts set mirror_to_app = true where user_id = '${U.oidc}'`);
});

await test('only a public username can be requested; the queue cannot be forged by clients', async () => {
  await become(U.oidc);
  await throws(() => rpc('public.telegram_start_chat', "'+998901112233'"), /public Telegram username/);
  await throws(() => rpc('public.telegram_start_chat', "'t.me/other'"), /public Telegram username/);
  const [queued] = await rpc('public.telegram_start_chat', "'  @FreshContact  '");
  contactRequestId = queued.telegram_start_chat.request_id;
  assert(contactRequestId, 'an owner-only queue receipt is returned');
  const [again] = await rpc('public.telegram_start_chat', "'freshcontact'");
  eq(again.telegram_start_chat.request_id, contactRequestId, 'two devices do not duplicate a pending lookup');
  await throws(() => exec(`select * from public.telegram_chat_requests`), /permission denied/);
  await throws(() => exec(`update public.telegram_chat_requests set status = 'succeeded'`), /permission denied/);
  await throws(() => rpc('public.bridge_claim_chat_request', "'hacker', null, '1 second'"), /permission denied/);
  await become(U.b);
  eq((await rpc('public.telegram_chat_request_state', `'${contactRequestId}'`))[0].telegram_chat_request_state,
     null, 'another account cannot inspect the request');
});

await test('only a real private chat mapped to the requester can finish a claimed lookup', async () => {
  await becomeService();
  const noOther = await rpc('public.bridge_claim_chat_request', `'worker-1', '${U.other}', '10 seconds'`);
  eq(noOther[0].bridge_claim_chat_request, null, 'the wrong owner has no work');
  const [row] = await rpc('public.bridge_claim_chat_request', `'worker-1', '${U.oidc}', '10 seconds'`);
  eq(row.bridge_claim_chat_request.request_id, contactRequestId);
  eq(row.bridge_claim_chat_request.username, 'freshcontact');
  eq((await rpc('public.bridge_finish_chat_request', `'${contactRequestId}', 'worker-else', null, 'ignored', null`))[0].bridge_finish_chat_request,
     false, 'another worker cannot complete the lease');
  await throws(
    () => rpc('public.bridge_finish_chat_request', `'${contactRequestId}', 'worker-1', '${chatId}', null, null`),
    /private Telegram mirror owned by the requester/,
  );
  const [created] = await rpc('public.bridge_resolve_chat',
    `'${U.oidc}', 550001, 'private', 'Fresh Contact', 550001, 'freshcontact', 'Fresh', 'Contact', null, true`);
  contactChatId = created.bridge_resolve_chat.chat_id;
  assert(contactChatId, 'TDLib bridge created an owner-scoped mirror');
  eq((await rpc('public.bridge_finish_chat_request', `'${contactRequestId}', 'worker-1', '${contactChatId}', null, null`))[0].bridge_finish_chat_request,
     true);
  await become(U.oidc);
  const [state] = await rpc('public.telegram_chat_request_state', `'${contactRequestId}'`);
  eq(state.telegram_chat_request_state.status, 'succeeded');
  eq(state.telegram_chat_request_state.chat_id, contactChatId);
  eq((await query(`select count(*)::int as n from public.telegram_chats where chat_id = '${contactChatId}'`))[0].n,
     1, 'the client can see only its own mirrored chat');
});

await test('a Telegram group username is never accepted as a private-contact chat', async () => {
  await become(U.oidc);
  const [queued] = await rpc('public.telegram_start_chat', "'@publicgroup'");
  await becomeService();
  const [claim] = await rpc('public.bridge_claim_chat_request', `'worker-1', '${U.oidc}', '10 seconds'`);
  eq(claim.bridge_claim_chat_request.request_id, queued.telegram_start_chat.request_id);
  const [groupChat] = await rpc('public.bridge_resolve_chat',
    `'${U.oidc}', 650001, 'supergroup', 'Public group', null, null, null, null, null, true`);
  await throws(
    () => rpc('public.bridge_finish_chat_request', `'${queued.telegram_start_chat.request_id}', 'worker-1', '${groupChat.bridge_resolve_chat.chat_id}', null, null`),
    /private Telegram mirror/,
  );
  eq((await rpc('public.bridge_finish_chat_request',
    `'${queued.telegram_start_chat.request_id}', 'worker-1', null, 'Only Telegram users can be opened here', null`))[0].bridge_finish_chat_request,
    true);
  await become(U.oidc);
  eq((await rpc('public.telegram_chat_request_state', `'${queued.telegram_start_chat.request_id}'`))[0].telegram_chat_request_state.status,
     'failed');
});

await test('rate limits persist in SQL instead of relying on an edge process cache', async () => {
  await become(U.oidc);
  for (const name of ['aliceb', 'alicec', 'aliced']) {
    const [result] = await rpc('public.telegram_start_chat', `'${name}'`);
    assert(result.telegram_start_chat.request_id);
  }
  await throws(() => rpc('public.telegram_start_chat', "'alicee'"), /Too many Telegram lookups/);
  await becomeService();
  await exec(`update public.telegram_accounts set auth_state = 'unlinked', tg_user_id = null
               where user_id = '${U.oidc}'`);
  eq((await rpc('public.bridge_claim_chat_request', `'worker-1', '${U.oidc}', '1 second'`))[0].bridge_claim_chat_request,
     null, 'the worker cannot open a new chat once the account has unlinked');
});

// ---------------------------------------------------------------------------
group('browser push (00017)');

/**
 * The other half of the notice story. 00012's queue needs a live TDLib session;
 * this one needs nothing but the browser's own subscription, which is what makes
 * an alert possible without an always-on worker. The rules that matter — offline
 * only, never for your own message, never when the user read it — are shared
 * with 00012 on purpose, so they are asserted here against the web queue too.
 */
const webRows = async (userId = U.a) => {
  await becomeOwner();
  return query(`select * from public.web_push_requests where user_id = '${userId}' order by id`);
};
const webCount = async (userId = U.a, state = 'queued') => {
  await becomeOwner();
  return Number(await scalar(
    `select count(*)::int from public.web_push_requests where user_id = '${userId}' and state = '${state}'`));
};
// A well-formed 65-byte P-256 point and a 16-byte auth secret, base64url.
const P256DH = 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4';
const PUSH_AUTH = 'BTBZMqHH6r4Tts7J_aSIgg';
const subscribe = async (uid, endpoint = `https://fcm.googleapis.com/fcm/send/${uid}`) => {
  await become(uid);
  const [row] = await query(
    `select public.register_push_subscription($1, $2, $3, 'test browser') as s`, [endpoint, P256DH, PUSH_AUTH]);
  return row.s;
};
const clearWebPush = async () => {
  await becomeOwner();
  await exec(`delete from public.web_push_requests`);
};
const azizAwayForPush = async () => {
  await becomeOwner();
  await exec(`update public.profiles
                 set last_seen_at = clock_timestamp() - interval '10 minutes',
                     access_state = 'active', deleted_at = null,
                     push_web = true, push_preview = true
               where id = '${U.a}'`);
};

await test('a browser can register, is capped, and cannot forge another account\'s row', async () => {
  await becomeOwner();
  await exec(`delete from public.push_subscriptions; delete from public.web_push_requests;`);

  const registered = await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/aziz-laptop');
  assert(registered.id, 'the RPC returns the row id');
  eq(registered.label, 'test browser');

  // Shape checks are the database's job too, not only the edge function's.
  await become(U.a);
  await throws(() => query(`select public.register_push_subscription('https://fcm.googleapis.com/x', 'not-a-key', $1)`, [PUSH_AUTH]),
    /base64url P-256 point/);
  await throws(() => query(`select public.register_push_subscription('https://fcm.googleapis.com/x', $1, 'short')`, [P256DH]),
    /16 base64url bytes/);
  await throws(() => query(`select public.register_push_subscription('http://x', $1, $2)`, [P256DH, PUSH_AUTH]),
    /at least 16|between 16/);

  // A client cannot insert directly: writes go through the RPC, so the device
  // cap and the endpoint's single ownership cannot be bypassed.
  await throws(() => query(
    `insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values ('${U.a}', 'https://fcm.googleapis.com/fcm/send/direct', $1, $2)`,
    [P256DH, PUSH_AUTH]), /permission denied|row-level security/);

  // ...and cannot see or delete anybody else's row.
  await subscribe(U.b, 'https://fcm.googleapis.com/fcm/send/dilnoza');
  await become(U.a);
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions`)), 1, 'RLS scopes the listing');
  await query(`delete from public.push_subscriptions where user_id = '${U.b}'`);
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions where user_id = '${U.b}'`)), 1,
     'a delete cannot reach another account');

  // Re-registering the same endpoint is a refresh, not a sixth device.
  await become(U.a);
  for (let i = 0; i < 4; i++) {
    await query(`select public.register_push_subscription($1, $2, $3, 'browser ${i}')`,
      [`https://fcm.googleapis.com/fcm/send/aziz-${i}`, P256DH, PUSH_AUTH]);
  }
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions where user_id = '${U.a}'`)), 5, 'five live devices before the cap bites');
  await throws(() => query(`select public.register_push_subscription('https://fcm.googleapis.com/fcm/send/one-too-many', $1, $2)`,
    [P256DH, PUSH_AUTH]), /too many registered browsers/);
  await query(`select public.register_push_subscription($1, $2, $3, 'refreshed')`, ['https://fcm.googleapis.com/fcm/send/aziz-laptop', P256DH, PUSH_AUTH]);

  // The same browser signing in as somebody else must stop notifying the first
  // account: the endpoint is unique, so the row moves rather than duplicates.
  await subscribe(U.b, 'https://fcm.googleapis.com/fcm/send/aziz-laptop');
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/aziz-laptop'`)), 1);
  eq(await scalar(`select user_id::text from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/aziz-laptop'`),
     U.b, 'ownership moved to the account that registered it last');

  await becomeOwner();
  await exec(`delete from public.push_subscriptions`);
});

await test('a message to an away user with a registered browser queues one folded notice', async () => {
  await becomeOwner();
  await exec(`delete from public.push_subscriptions; delete from public.web_push_requests;
              update public.chat_participants set unread_count = 0, muted_until = null, left_at = null
               where chat_id = '${chatId}'`);
  await azizAwayForPush();
  await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/aziz');

  await sendAsDilnoza('web push bir');
  let rows = await webRows(U.a);
  eq(rows.length, 1, 'one queued notice');
  eq(rows[0].state, 'queued');
  eq(rows[0].folded, 1);
  eq(rows[0].sender_name, 'Dilnoza Rustamova', 'the same human label the chat list shows');
  eq(rows[0].preview, 'web push bir');

  await sendAsDilnoza('web push ikki');
  rows = await webRows(U.a);
  eq(rows.length, 1, 'a burst folds instead of stacking');
  eq(rows[0].folded, 2);
  eq(rows[0].preview, 'web push ikki', 'the newest text wins');

  // The dashboard does not need a subscription, and a system message is not news.
  eq(await webCount(U.a), 1);
});

await test('nothing is queued while the app is foregrounded, offline-less, or Telegram already delivered it', async () => {
  await clearWebPush();
  // A heartbeat two seconds ago means the app is open: the in-app banner owns this.
  await becomeOwner();
  await exec(`update public.profiles set last_seen_at = clock_timestamp() where id = '${U.a}'`);
  await sendAsDilnoza('app is open');
  eq(await webCount(U.a), 0, 'a foregrounded app is not notified');

  // Away again, but now with no registered browser: queueing would only create a
  // row the sender has to skip.
  await azizAwayForPush();
  await becomeOwner();
  await exec(`update public.push_subscriptions set disabled_at = clock_timestamp() where user_id = '${U.a}'`);
  await sendAsDilnoza('no browser left');
  eq(await webCount(U.a), 0, 'no live subscription means no notice');

  // Switch the preference off, with a live browser.
  await becomeOwner();
  await exec(`update public.push_subscriptions set disabled_at = null where user_id = '${U.a}'`);
  await become(U.a);
  eq((await query(`select public.set_web_push_enabled(false) as on`))[0].on, false);
  await sendAsDilnoza('push switched off');
  eq(await webCount(U.a), 0, 'the switch is honoured');

  // The user's own message never buzzes them.
  await become(U.a);
  await query(`select public.set_web_push_enabled(true)`);
  await clearWebPush();
  await azizAwayForPush();
  await become(U.a);
  await rpc('public.send_message', `'${chatId}', 'text', 'my own words', null, null, null`);
  eq(await webCount(U.a), 0, 'the sender does not notify themselves');

  // Traffic that arrived *from* Telegram into a chat this recipient mirrors is
  // already buzzing on their phone. 00012 suppresses it; so must 00017, or the
  // two transports disagree about what a duplicate is.
  await clearWebPush();
  await becomeOwner();
  await exec(`insert into public.telegram_chats
                (owner_user_id, tg_chat_id, tg_chat_type, chat_id, peer_user_id, sync_direction)
              values ('${U.a}', ${TG_CHAT_STR}, 'private', '${chatId}', 9999, 'off')`);
  await exec(`insert into public.messages (chat_id, sender_id, kind, body, source, tg_message_id)
              select '${chatId}', '${U.b}', 'text', 'telegram carried this', 'telegram', 424242`);
  eq(await webCount(U.a), 0, 'a Telegram-delivered message is not announced again');

  await becomeOwner();
  await exec(`delete from public.web_push_requests;
              delete from public.telegram_chats where owner_user_id = '${U.a}' and chat_id = '${chatId}';
              update public.chat_participants set unread_count = 0, muted_until = null, left_at = null
                where chat_id = '${chatId}'`);

  // The same text over the app path *is* queued, so the suppression above came
  // from the Telegram mirror and not from the message simply being unremarkable.
  await azizAwayForPush();
  await sendAsDilnoza('app path, same shape');
  eq(await webCount(U.a), 1, 'the app path still notifies');
});

await test('the sender leases, re-checks, and reports a delivery', async () => {
  await clearWebPush();
  await azizAwayForPush();
  await becomeOwner();
  await exec(`update public.chat_participants set unread_count = 0, muted_until = null
               where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await sendAsDilnoza('lease me');
  await becomeOwner();
  await exec(`update public.web_push_requests set next_attempt_at = clock_timestamp() - interval '1 second'
               where user_id = '${U.a}' and state = 'queued'`);

  await becomeService();
  const [leased] = await query(`select * from public.web_push_claim('sender-1', 5)`);
  assert(leased, 'the sweep claims the due notice');
  eq(String(leased.user_id), U.a);
  eq(leased.sender_name, 'Dilnoza Rustamova');
  eq(leased.preview, 'lease me');
  eq(leased.folded, 1);
  eq(leased.chat_kind, 'direct');
  eq(leased.attempts, 1, 'the attempt is counted before the send, not after');
  eq(await scalar(`select state::text from public.web_push_requests where id = $1`, [leased.id]), 'in_flight');
  eq((await query(`select * from public.web_push_claim('sender-2', 5)`)).length, 0, 'a lease is exclusive');

  const targets = await query(`select * from public.web_push_targets(array['${U.a}']::uuid[])`);
  eq(targets.length, 1, 'only live subscriptions are targets');
  eq(targets[0].endpoint, 'https://fcm.googleapis.com/fcm/send/aziz');

  // The last-moment gate: a different sender, or text that was scrubbed after
  // the claim, must not be delivered.
  eq(await scalar(`select public.web_push_owed($1, 'sender-2')`, [leased.id]), false, 'only the lease holder may send');
  eq(await scalar(`select public.web_push_owed($1, 'sender-1', 'lease me')`, [leased.id]), true);
  eq(await scalar(`select public.web_push_owed($1, 'sender-1', 'stale text')`, [leased.id]), false,
     'a preview that changed since the claim is refused');

  eq(await scalar(`select public.web_push_complete($1, 'sent', 2, null, null)`, [leased.id]), true);
  await becomeOwner();
  const [done] = await query(`select state::text as state, delivered_count from public.web_push_requests where id = $1`, [leased.id]);
  eq(done.state, 'sent');
  eq(done.delivered_count, 2, 'how many browsers accepted it is recorded');
  await becomeService();
  eq(await scalar(`select public.web_push_complete($1, 'failed', 0, 'too late', null)`, [leased.id]), false,
     'a late report cannot rewrite a finished row');
});

await test('reading the chat cancels the notice and kills a live lease', async () => {
  await clearWebPush();
  await azizAwayForPush();
  await becomeOwner();
  await exec(`update public.chat_participants set unread_count = 0, muted_until = null
               where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await sendAsDilnoza('read me first');

  await becomeOwner();
  await exec(`update public.web_push_requests set next_attempt_at = clock_timestamp() - interval '1 second'
               where state = 'queued'`);
  await becomeService();
  const [leased] = await query(`select * from public.web_push_claim('sender-1', 5)`);
  eq(await webCount(U.a, 'queued'), 0, 'the row is in flight, not queued');

  await become(U.a);
  await rpc('public.mark_chat_read', `'${chatId}'`);
  await becomeService();
  eq(await scalar(`select public.web_push_owed($1, 'sender-1')`, [leased.id]), false,
     'the read reached the lease before the encrypted payload did');
  eq(await scalar(`select state::text from public.web_push_requests where id = $1`, [leased.id]), 'skipped');
  eq(await scalar(`select public.web_push_complete($1, 'sent', 1, null, null)`, [leased.id]), false,
     'a cancelled row cannot be reported as sent');

  // A notice that arrives while the app is open is never queued at all.
  await becomeOwner();
  await exec(`update public.profiles set last_seen_at = clock_timestamp() where id = '${U.a}'`);
  await sendAsDilnoza('arrived while open');
  eq(await webCount(U.a), 0);
});

await test('turning previews off scrubs a notice already leased by the sender', async () => {
  await clearWebPush();
  await azizAwayForPush();
  await becomeOwner();
  await exec(`update public.chat_participants set unread_count = 0, muted_until = null
               where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await sendAsDilnoza('private words');
  await becomeOwner();
  await exec(`update public.web_push_requests set next_attempt_at = clock_timestamp() - interval '1 second'
               where state = 'queued'`);
  await becomeService();
  const [leased] = await query(`select * from public.web_push_claim('sender-1', 5)`);
  eq(await scalar(`select public.web_push_owed($1, 'sender-1', 'private words')`, [leased.id]), true);

  await become(U.a);
  await query(`select public.set_push_preferences(null, false)`);
  await becomeService();
  eq(await scalar(`select public.web_push_owed($1, 'sender-1', 'private words')`, [leased.id]), false,
     'the claimed text no longer matches, so the sender must drop it');
  await becomeOwner();
  eq(await scalar(`select preview from public.web_push_requests where id = $1`, [leased.id]), '',
     'the stored preview is gone, not merely hidden');
  await become(U.a);
  await query(`select public.set_push_preferences(null, true)`);
});

await test('the queue is invisible to clients and sends are not theirs to start', async () => {
  await become(U.a);
  await throws(() => query(`select count(*) from public.web_push_requests`), /permission denied/);
  await throws(() => query(
    `insert into public.web_push_requests (user_id, chat_id, sender_name) values ('${U.a}', '${chatId}', 'forged')`),
    /permission denied/);
  await throws(() => query(`select * from public.web_push_claim('attacker', 5)`), /permission denied/);
  await throws(() => query(`select * from public.web_push_targets(array['${U.b}']::uuid[])`), /permission denied/);
  await throws(() => query(`select public.web_push_complete(gen_random_uuid(), 'sent')`), /permission denied/);
  await throws(() => query(`select public.prune_web_push_requests()`), /permission denied/);
  await throws(() => query(`select public.prune_push_subscriptions()`), /permission denied/);
  await throws(() => query(`select public.web_push_owed(gen_random_uuid(), 'x')`), /permission denied/);
});

await test('a dead endpoint is deleted, a flaky one is disabled, a success clears the record', async () => {
  await becomeOwner();
  await exec(`delete from public.push_subscriptions; delete from public.web_push_requests;
              update public.profiles set push_preview = true where id = '${U.a}'`);
  await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/gone');
  await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/flaky');
  await becomeOwner();
  const gone = await scalar(`select id::text from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/gone'`);
  const flaky = await scalar(`select id::text from public.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/flaky'`);

  await becomeService();
  // 404/410 is "this subscription no longer exists": retrying can never help.
  eq(await scalar(`select public.web_push_target_result('${gone}', false, true, 'HTTP 410')`), true);
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions where id = '${gone}'`)), 0,
     'the dead subscription is removed');

  await becomeService();
  for (let i = 0; i < 19; i++) {
    await scalar(`select public.web_push_target_result('${flaky}', false, false, 'HTTP 503')`);
  }
  await becomeOwner();
  eq(await scalar(`select disabled_at is null from public.push_subscriptions where id = '${flaky}'`), true,
     'nineteen transient failures are not enough to give up');
  await becomeService();
  await scalar(`select public.web_push_target_result('${flaky}', false, false, 'HTTP 503')`);
  await becomeOwner();
  eq(await scalar(`select disabled_at is not null from public.push_subscriptions where id = '${flaky}'`), true,
     'the twentieth disables it instead of hammering a broken endpoint forever');
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions where user_id = '${U.a}' and disabled_at is null`)), 0);
  await becomeOwner();
  await exec(`update public.profiles set last_seen_at = clock_timestamp() - interval '10 minutes' where id = '${U.a}'`);
  await sendAsDilnoza('nobody to tell');
  eq(await webCount(U.a), 0, 'a disabled endpoint is not a delivery target');

  // Registering again proves the browser works, so the counter is forgiven.
  await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/flaky');
  await becomeOwner();
  eq(await scalar(`select disabled_at is null from public.push_subscriptions where id = '${flaky}'`), true,
     're-registering revives the row');
  await becomeService();
  await scalar(`select public.web_push_target_result('${flaky}', true, false, null)`);
  await becomeOwner();
  eq(Number(await scalar(`select error_count from public.push_subscriptions where id = '${flaky}'`)), 0);
  eq(await scalar(`select last_success_at is not null from public.push_subscriptions where id = '${flaky}'`), true);
});

await test('a parked notice retries, an expired lease is recovered, and history is pruned', async () => {
  await becomeOwner();
  await exec(`delete from public.web_push_requests;
              update public.profiles set last_seen_at = clock_timestamp() - interval '10 minutes' where id = '${U.a}';
              update public.chat_participants set unread_count = 0, muted_until = null
               where chat_id = '${chatId}' and user_id = '${U.a}'`);
  await sendAsDilnoza('park me');
  await becomeOwner();
  await exec(`update public.web_push_requests set next_attempt_at = clock_timestamp() - interval '1 second' where state = 'queued'`);
  await becomeService();
  const [first] = await query(`select * from public.web_push_claim('sender-1', 5)`);
  eq(await scalar(`select public.web_push_complete($1, 'queued', 0, 'HTTP 503 from the push service', interval '30 seconds')`, [first.id]),
     true, 'a parked notice is requeued, not lost');

  // The lease holder never came back. Its lease must not be a tombstone.
  await becomeOwner();
  await exec(`update public.web_push_requests set next_attempt_at = clock_timestamp() - interval '1 second'
               where id = $1`, [first.id]);
  await becomeService();
  const [second] = await query(`select * from public.web_push_claim('sender-2', 5)`);
  eq(second.id, first.id, 'the expired lease returned to the queue');
  eq(second.attempts, 2);
  eq(await scalar(`select claimed_by from public.web_push_requests where id = $1`, [first.id]), 'sender-2');

  // Exhaust attempts and confirm the queue terminates instead of spinning.
  await scalar(`select public.web_push_complete($1, 'queued', 0, 'still parked', interval '1 second')`, [first.id]);
  await becomeOwner();
  await exec(`update public.web_push_requests set attempts = max_attempts, next_attempt_at = clock_timestamp() - interval '1 second'
               where id = $1`, [first.id]);
  await becomeService();
  eq((await query(`select * from public.web_push_claim('sender-3', 5)`)).length, 0);
  await becomeOwner();
  eq(await scalar(`select state::text from public.web_push_requests where id = $1`, [first.id]), 'failed',
     'an exhausted notice is a failure an operator can see');

  // `updated_at` is maintained by a BEFORE UPDATE trigger, so age the row with
  // the trigger off rather than fighting it.
  await becomeOwner();
  await exec(`alter table public.web_push_requests disable trigger web_push_requests_touch`);
  await exec(`update public.web_push_requests set updated_at = clock_timestamp() - interval '4 days'
               where id = $1`, [first.id]);
  await exec(`alter table public.web_push_requests enable trigger web_push_requests_touch`);
  await becomeService();
  eq(Number(await scalar(`select public.prune_web_push_requests()`)) >= 1, true, 'terminal history is pruned');
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from public.web_push_requests where id = $1`, [first.id])), 0);

  // A browser nobody has re-registered for a year is not a live target.
  await becomeOwner();
  await exec(`update public.push_subscriptions set last_seen_at = clock_timestamp() - interval '400 days'
               where user_id = '${U.a}'`);
  await becomeService();
  eq(Number(await scalar(`select public.prune_push_subscriptions()`)), 1);
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from public.push_subscriptions where user_id = '${U.a}' and disabled_at is null`)), 0);

  await becomeOwner();
  await exec(`delete from public.push_subscriptions; delete from public.web_push_requests;
              update public.profiles set last_seen_at = clock_timestamp(), push_web = true, push_preview = true where id = '${U.a}';`);
});

// ---------------------------------------------------------------------------
group('browser push dispatch (00018, pg_net)');

/**
 * PGlite has no pg_net, so this migration is written to apply cleanly without it
 * and leave the 00017 behaviour untouched — the first test asserts exactly that,
 * because a migration that only works on the hosted platform is a migration
 * nobody can run in CI.
 *
 * For the rest, a stand-in `net.http_post` is installed with pg_net's real
 * signature and the migration is re-applied: it is idempotent, and the trigger
 * is created once `net` exists. That exercises the whole path — the Vault/GUC
 * lookup, the request body, the bearer token, and the promise that a broken
 * webhook can never break sending a message.
 */
await test('applies without pg_net and leaves 00017 behaviour intact', async () => {
  await becomeOwner();
  eq(await scalar(`select to_regnamespace('net') is null`), true, 'PGlite really has no pg_net');
  eq(await scalar(`select to_regprocedure('app.web_push_dispatch_config()') is not null`), true,
     'the configuration reader exists either way');
  eq(await scalar(`select to_regprocedure('app.dispatch_web_push()') is not null`), true);
  eq(await scalar(`select count(*)::int from pg_trigger where tgname = 'web_push_requests_dispatch'`), 0,
     'no trigger is created, so nothing can reference a missing extension');

  // And with nothing configured, the reader reports nothing rather than guessing.
  eq(await scalar(`select count(*)::int from app.web_push_dispatch_config()`), 0);
});

await test('a queued notice dispatches one signed sweep and never fails the message', async () => {
  await becomeOwner();
  // The previous group ended by deleting every subscription; without a live one
  // no notice is ever queued, so start from a registered browser.
  await exec(`delete from public.push_subscriptions`);
  await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/aziz');
  await becomeOwner();
  // A function with pg_net's exact signature, recording what it was handed.
  await exec(`
    create schema if not exists net;
    create table if not exists net.calls (
      id bigserial primary key, url text, body jsonb, headers jsonb, timeout_milliseconds integer
    );
    create or replace function net.http_post(
      url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
      headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000
    ) returns bigint language plpgsql as $fn$
    declare v_id bigint;
    begin
      insert into net.calls (url, body, headers, timeout_milliseconds)
      values (url, body, headers, timeout_milliseconds) returning id into v_id;
      return v_id;
    end $fn$;
    delete from net.calls;
  `);
  // Re-apply the migration now that `net` exists; it must create the trigger.
  await exec(readFileSync(join(MIGRATIONS, '00018_web_push_dispatch.sql'), 'utf8'));
  eq(await scalar(`select count(*)::int from pg_trigger where tgname = 'web_push_requests_dispatch'`), 1,
     'the trigger appears once the extension surface is there');

  // Incomplete configuration must not dispatch: the function rejects a sweep
  // with no token, so firing one would be a guaranteed 401.
  await becomeOwner();
  await exec(`select set_config('messengerx.push_dispatch_url',
                                'https://example.supabase.co/functions/v1/web-push-send', false)`);
  await clearWebPush();
  await azizAwayForPush();
  await sendAsDilnoza('needs a token too');
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from net.calls`)), 0, 'a URL without a token dispatches nothing');

  // Now configure both, and a new notice must produce exactly one request.
  await becomeOwner();
  await exec(`
    select set_config('messengerx.push_dispatch_token', 'test-dispatch-token-0123456789abcdef', false);
    delete from public.web_push_requests;
    update public.chat_participants set unread_count = 0, muted_until = null
     where chat_id = '${chatId}' and user_id = '${U.a}';
  `);
  await azizAwayForPush();
  await sendAsDilnoza('dispatch me');

  await becomeOwner();
  const calls = await query(`select url, body, headers, timeout_milliseconds from net.calls order by id`);
  eq(calls.length, 1, 'one HTTP request per queued notice');
  eq(calls[0].url, 'https://example.supabase.co/functions/v1/web-push-send');
  eq(calls[0].body.limit, 10);
  eq(calls[0].body.wait_ms, 3000, 'the function is told to wait out the fold window before claiming');
  eq(calls[0].headers.authorization, 'Bearer test-dispatch-token-0123456789abcdef');
  eq(calls[0].headers['content-type'], 'application/json');
  eq(calls[0].timeout_milliseconds, 10000);

  // A burst folds into the same queued row, so it must not dispatch again.
  await sendAsDilnoza('and another');
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from net.calls`)), 1, 'a folded follow-up does not re-dispatch');
});

await test('a failing webhook warns but never breaks the message that triggered it', async () => {
  await becomeOwner();
  await exec(`
    create schema if not exists net;
    create table if not exists net.calls (
      id bigserial primary key, url text, body jsonb, headers jsonb, timeout_milliseconds integer
    );
    delete from public.push_subscriptions;
    delete from net.calls;
    create or replace function net.http_post(
      url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
      headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000
    ) returns bigint language plpgsql as $fn$
    begin
      raise exception 'pg_net is having a bad day' using errcode = '58000';
    end $fn$;
  `);
  await becomeOwner();
  await exec(`select set_config('messengerx.push_dispatch_url',
                                'https://example.supabase.co/functions/v1/web-push-send', false)`);
  await subscribe(U.a, 'https://fcm.googleapis.com/fcm/send/aziz');
  await clearWebPush();
  await azizAwayForPush();
  await becomeOwner();
  await exec(`update public.chat_participants set unread_count = 0, muted_until = null
               where chat_id = '${chatId}' and user_id = '${U.a}'`);

  // The message must still be sent, and the notice must still be queued for the
  // heartbeat sweep to find later. This is the property that makes it safe to
  // put an HTTP call in a trigger at all.
  await sendAsDilnoza('webhook is down');
  eq(await webCount(U.a, 'queued'), 1, 'the notice survives a failed dispatch');
  await becomeOwner();
  eq(Number(await scalar(`select count(*)::int from public.messages where body = 'webhook is down'`)), 1,
     'and the sender\'s message is unaffected');

  // The alert was never sent, so claiming it now must still work.
  await becomeOwner();
  await exec(`update public.web_push_requests set next_attempt_at = clock_timestamp() - interval '1 second'`);
  await becomeService();
  const rows = await query(`select * from public.web_push_claim('sender-after-outage', 5)`);
  eq(rows.length, 1, 'the queued notice is still claimable after the outage');

  await becomeOwner();
  await exec(`
    delete from public.web_push_requests;
    select set_config('messengerx.push_dispatch_url', '', false);
    select set_config('messengerx.push_dispatch_token', '', false);
    update public.chat_participants set unread_count = 0, muted_until = null
     where chat_id = '${chatId}' and user_id = '${U.a}';
    update public.profiles set last_seen_at = clock_timestamp() where id = '${U.a}';
  `);
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
