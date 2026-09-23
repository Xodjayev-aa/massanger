#!/usr/bin/env node
/**
 * tools/sql-test/seed-check.mjs — proves `supabase/seed.sql` applies cleanly.
 *
 * The seed is the first thing a new contributor runs (`supabase db reset`), so a
 * stale column name in it costs every fresh clone an hour. PGlite has no auth
 * password hashing and no `extensions` schema, so this script creates the two
 * users the way the migration suite does and then executes everything in seed.sql
 * after the users are expected to exist. That keeps the check honest about the
 * part that actually rots: the public-table inserts and the trigger interactions.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const MIGRATIONS = join(ROOT, 'supabase', 'migrations');

const AZIZ = '11111111-1111-4111-8111-111111111111';
const DILNOZA = '22222222-2222-4222-8222-222222222222';
const CHAT = '33333333-3333-4333-8333-333333333333';

// The marker the seed uses to separate "create accounts" from "demo content".
const SPLIT_AT = '-- The direct chat.';

const pg = await PGlite.create({ name: 'messengerx-seedcheck' });
const exec = async (sql) => pg.exec(sql);
const scalar = async (sql) => Object.values((await pg.query(sql)).rows[0] ?? {})[0];

await exec(readFileSync(join(HERE, 'fixtures', 'supabase_stub.sql'), 'utf8'));
for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort()) {
  await exec(readFileSync(join(MIGRATIONS, file), 'utf8'));
}

// Same insertion the migration suite uses, minus the bcrypt password columns.
await exec(`
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
    ('${AZIZ}', 'aziz@example.test', '{"provider":"email"}', '{"full_name":"Aziz Xodjayev"}'),
    ('${DILNOZA}', 'dilnoza@example.test', '{"provider":"email"}', '{"full_name":"Dilnoza Karimova"}');
`);

const seed = readFileSync(join(ROOT, 'supabase', 'seed.sql'), 'utf8');
const index = seed.indexOf(SPLIT_AT);
if (index < 0) throw new Error(`seed.sql no longer contains the "${SPLIT_AT}" marker`);
const body = seed.slice(index).replace(/^\s*begin;$/m, '').replace(/^\s*commit;\s*$/m, '');

let statements = 0;
for (const raw of body.split(/;\s*\n/)) {
  const sql = raw.replace(/^\s*--[^\n]*$/gm, '').trim();
  if (sql === '') continue;
  try {
    await exec(sql);
    statements++;
  } catch (err) {
    console.error(`\n✖ seed.sql statement failed:\n${sql.slice(0, 400)}\n\n${err.message}\n`);
    process.exit(1);
  }
}

const checks = [];
const expect = async (label, sql, wanted) => {
  const got = await scalar(sql);
  checks.push({ label, ok: got === wanted, wanted, got });
};

await expect('three messages seeded', `select count(*)::int from public.messages`, 3);
await expect('chat has both participants', `select count(*)::int from public.chat_participants where chat_id = '${CHAT}'`, 2);
await expect(
  'sender-name snapshot filled by trigger',
  `select count(*)::int from public.messages where sender_name <> ''`,
  3,
);
await expect(
  'search index populated by trigger',
  `select count(*)::int from public.messages where search_tsv is not null`,
  3,
);
await expect(
  'non-mirror chat produces no Telegram outbox rows',
  `select count(*)::int from public.telegram_outbox`,
  0,
);
await expect('chat header points at the newest message', `select (last_message_id is not null)::int from public.chats where id = '${CHAT}'`, 1);
await expect(
  'search works through the seed',
  `select count(*)::int from public.messages where search_tsv @@ plainto_tsquery('simple', 'Realtime')`,
  1,
);
await expect(
  'owner has exactly one unread',
  `select unread_count::int from public.chat_participants where chat_id = '${CHAT}' and user_id = '${AZIZ}'`,
  1,
);

const failed = checks.filter((check) => !check.ok);
for (const check of checks) {
  console.log(`${check.ok ? '✓' : '✖'} ${check.label}${check.ok ? '' : ` (wanted ${check.wanted}, got ${check.got})`}`);
}
console.log(`\nseed.sql applied in ${statements} statements; ${checks.length - failed.length}/${checks.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);
