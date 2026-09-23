-- MessengerX — local demo data. Applied by `supabase db reset` (config.toml →
-- [db.seed]); never run in production, and CI does not run it either, because it
-- intentionally uses the auth schema that only exists on a real Supabase instance.
--
-- Design rules for this file:
--   * Insert users through `auth.users` and let `app.handle_new_user()` build the
--     profile and the telegram_accounts row. Duplicating that logic here would make
--     the seed drift from the trigger on the next migration.
--   * Write messages through `public.messages` so the same triggers the app
--     depends on run: search_tsv, the sender-name snapshot, chat touch, read
--     receipts, and the Telegram outbox enqueue (which correctly stays silent
--     here because this chat is not a Telegram mirror).
--   * Fixed ids and `on conflict do nothing`, so a partial reset can be replayed.

begin;

-- Both accounts are seeded as email identities, which `handle_new_user()` marks
-- `active` immediately; a Google identity would sit in `pending_verification`
-- until the age gate passes. Password for both is "messengerx" (local only).
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user
)
values
  (
    '00000000-0000-0000-0000-000000000000',
    '11111111-1111-4111-8111-111111111111',
    'authenticated', 'authenticated', 'aziz@example.test',
    extensions.crypt('messengerx', extensions.gen_salt('bf', 10)),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Aziz Xodjayev"}'::jsonb,
    now() - interval '400 days', now() - interval '400 days', false
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '22222222-2222-4222-8222-222222222222',
    'authenticated', 'authenticated', 'dilnoza@example.test',
    extensions.crypt('messengerx', extensions.gen_salt('bf', 10)),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name":"Dilnoza Karimova"}'::jsonb,
    now() - interval '380 days', now() - interval '380 days', false
  )
on conflict (id) do nothing;

-- The direct chat. `kind = 'direct'` with no title is the shape the uniqueness
-- trigger (`enforce_unique_direct_pair`) expects; `chats_mirror_shape` is
-- satisfied because this chat is not bound to a Telegram peer.
insert into public.chats (id, kind, title, created_by)
values ('33333333-3333-4333-8333-333333333333', 'direct', null,
        '11111111-1111-4111-8111-111111111111')
on conflict (id) do nothing;

insert into public.chat_participants (chat_id, user_id, role)
values
  ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', 'owner'),
  ('33333333-3333-4333-8333-333333333333', '22222222-2222-4222-8222-222222222222', 'member')
on conflict (chat_id, user_id) do nothing;

-- Three messages, alternating senders, so the thread, the badges and the read
-- receipts all have something to render. `source = 'app'` and no `tg_*` columns:
-- these are native messages, and the after-insert trigger that mirrors them to
-- Telegram correctly finds nothing to do (the chat is not a mirror).
insert into public.messages (id, chat_id, sender_id, kind, body, source, sent_at, state, read_at)
values
  ('44444444-4444-4444-8444-444444444441',
   '33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111',
   'text', 'Salom! Bu lokal ishga tushirish uchun urg''atuvchi xabar.', 'app',
   now() - interval '3 hours', 'read', now() - interval '2 hours 50 minutes'),
  ('44444444-4444-4444-8444-444444444442',
   '33333333-3333-4333-8333-333333333333', '22222222-2222-4222-8222-222222222222',
   'text', 'Ikkinchisi — Realtime obunani tekshirish uchun ekranni yangilab ko''ring.', 'app',
   now() - interval '2 hours', 'read', now() - interval '2 hours'),
  ('44444444-4444-4444-8444-444444444443',
   '33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111',
   'text', 'Uchinchi xabar yuborilgan holatda qoladi: ko''prig''i ishga tushgach Telegramga uzatiladi.', 'app',
   now() - interval '1 hour', 'sent', null)
on conflict (id) do nothing;

-- Keep the chat header consistent with the seeded traffic (the trigger that does
-- this on write only fires for inserts, so a re-run needs the touch).
update public.chats c
set last_message_id = latest.id,
    last_message_at = latest.sent_at
from (
  select id, sent_at
  from public.messages
  where chat_id = '33333333-3333-4333-8333-333333333333'
  order by sent_at desc nulls last
  limit 1
) latest
where c.id = '33333333-3333-4333-8333-333333333333';

-- Mark the first two as read for the owner so the unread badge starts at one.
update public.chat_participants
set last_read_message_id = '44444444-4444-4444-8444-444444444442',
    last_read_at = now() - interval '2 hours',
    unread_count = 1
where chat_id = '33333333-3333-4333-8333-333333333333'
  and user_id = '11111111-1111-4111-8111-111111111111';

commit;
