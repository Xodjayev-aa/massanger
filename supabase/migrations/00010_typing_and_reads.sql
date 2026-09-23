-- =============================================================================
-- 00010_typing_and_reads.sql
-- MessengerX — presence (typing) in both directions, and app→Telegram read
-- receipts.
--
-- Why a table and not Realtime broadcast only: a broadcast event is gone if the
-- phone is locked, and the bridge needs the *latest* state per chat, not a
-- replay of every keystroke. One tiny row per (chat, source) with a TTL gives us
-- both: Realtime renders it live, the bridge polls what it missed on wake-up,
-- and a crashed row simply expires.
--
-- Direction A (app → Telegram): the client upserts its own row at most every
-- ~3 s (set_typing), the worker forwards it as `sendChatAction`, and Telegram
-- shows "typing…". Rows older than the TTL are ignored, so a killed app never
-- leaves a stuck indicator.
--
-- Direction B (Telegram → app): `updateUserChatAction` for a private mirror chat
-- becomes a row with source='telegram'; the app shows "… is typing" for the
-- mirrored peer. Group chats are deliberately excluded: Telegram's per-member
-- typing would need a peer identity that is not a MessengerX account, and a
-- single "someone is typing" indicator in a group is misleading.
--
-- Read receipts: `mark_chat_read()` already advances chat_participants; the
-- bridge turns that into TDLib `viewMessages` so the other side sees the second
-- tick, and remembers the watermark on the mapping row so it never re-sends.
-- =============================================================================

create table if not exists public.chat_typing (
  chat_id     uuid        not null references public.chats (id) on delete cascade,
  user_id     uuid        not null references public.profiles (id) on delete cascade,
  source      text        not null default 'app' check (source in ('app', 'telegram')),
  -- 'typing' | 'upload_voice' | 'upload_photo' | 'record_audio' | 'choose_sticker'
  -- 'none' is never stored: stopping deletes the row.
  action      text        not null default 'typing',
  tg_chat_id  bigint,
  updated_at  timestamptz not null default clock_timestamp(),
  expires_at  timestamptz not null default (clock_timestamp() + interval '6 seconds'),
  primary key (chat_id, user_id, source),
  constraint chat_typing_action check (action in
    ('typing','upload_voice','upload_photo','upload_document','record_audio','record_video','choose_sticker','find_location'))
);

comment on table public.chat_typing is
  'Ephemeral typing/uploading presence, one row per (chat, member, source); TTL-bounded.';

create index if not exists chat_typing_expiry_idx on public.chat_typing (expires_at);
create index if not exists chat_typing_chat_idx   on public.chat_typing (chat_id, expires_at desc);

-- The watermark that lets the bridge send a read receipt to Telegram once.
alter table public.telegram_chats
  add column if not exists last_app_read_id  bigint,
  add column if not exists reads_synced_at   timestamptz;

comment on column public.telegram_chats.last_app_read_id is
  'Highest Telegram message id the owner has read in MessengerX; drives viewMessages().';

-- ---------------------------------------------------------------------------
-- client-side helpers
-- ---------------------------------------------------------------------------

-- The client throttles itself (≈3 s) and this RPC throttles again, so a badly
-- behaved app cannot turn presence into a write storm.
create or replace function public.set_typing(
  p_chat_id  uuid,
  p_on       boolean default true,
  p_action   text    default 'typing',
  p_ttl      interval default interval '6 seconds'
)
returns boolean
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  if not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'not a member of this chat' using errcode = '42501';
  end if;

  if not p_on then
    delete from public.chat_typing where chat_id = p_chat_id and user_id = v_uid and source = 'app';
    return false;
  end if;

  if p_action is null or not exists (
    select 1 from (values
      ('typing'),('upload_voice'),('upload_photo'),('upload_document'),
      ('record_audio'),('record_video'),('choose_sticker'),('find_location')) as allowed(action)
    where allowed.action = p_action
  ) then
    raise exception 'unsupported typing action %', p_action using errcode = '22023';
  end if;

  insert into public.chat_typing (chat_id, user_id, source, action, expires_at)
  values (p_chat_id, v_uid, 'app', p_action, clock_timestamp() + coalesce(p_ttl, interval '6 seconds'))
  on conflict (chat_id, user_id, source) do update
    set action = excluded.action,
        updated_at = excluded.updated_at,
        expires_at = excluded.expires_at
    -- 2.5 s floor: the indicator is a nicety, not a metric.
    where public.chat_typing.updated_at < excluded.updated_at - interval '2500 milliseconds';

  return found;
end;
$$;

-- Current presence for a chat, for the initial paint before Realtime catches up.
create or replace function public.chat_typing_state(p_chat_id uuid)
returns table (
  user_id    uuid,
  source     text,
  action     text,
  name       text,
  updated_at timestamptz
)
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null or not app.is_chat_member(p_chat_id, v_uid) then
    return;                                  -- render as "nobody", never raise
  end if;

  return query
  select t.user_id,
         t.source,
         t.action,
         coalesce(
           nullif(trim(p.display_name), ''),
           p.username,
           tp.display_name,
           'someone'
         )::text as name,
         t.updated_at
    from public.chat_typing t
    left join public.profiles p on p.id = t.user_id
    left join public.telegram_chats tc on tc.chat_id = t.chat_id and tc.owner_user_id = v_uid
    left join public.telegram_peers tp
      on tp.owner_user_id = v_uid and tp.tg_user_id = tc.peer_user_id
   where t.chat_id = p_chat_id
     and t.expires_at > clock_timestamp();
end;
$$;

-- ---------------------------------------------------------------------------
-- bridge-side RPCs (service_role only, like the rest of 00007)
-- ---------------------------------------------------------------------------

create or replace function public.bridge_pending_typing(
  p_owner uuid,
  p_since timestamptz default clock_timestamp() - interval '8 seconds',
  p_limit integer     default 20
)
returns table (
  chat_id    uuid,
  tg_chat_id bigint,
  action     text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not app.is_service_role() then
    raise exception 'service_role only' using errcode = '42501';
  end if;

  return query
  select t.chat_id,
         tc.tg_chat_id,
         t.action,
         t.updated_at
    from public.chat_typing t
    join public.telegram_chats tc
      on tc.chat_id = t.chat_id and tc.owner_user_id = t.user_id and tc.sync_direction in ('both','to_telegram')
    join public.telegram_accounts ta
      on ta.user_id = t.user_id and ta.auth_state = 'linked'
   where t.user_id = p_owner
     and t.source = 'app'
     and t.updated_at > p_since
     and t.expires_at > clock_timestamp()
   order by t.updated_at
   limit greatest(1, least(p_limit, 100));
end;
$$;

create or replace function public.bridge_report_typing(
  p_owner       uuid,
  p_tg_chat_id  bigint,
  p_action      text,
  p_ttl_seconds integer default 6
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_chat uuid;
begin
  if not app.is_service_role() then
    raise exception 'service_role only' using errcode = '42501';
  end if;

  select tc.chat_id into v_chat
    from public.telegram_chats tc
   where tc.owner_user_id = p_owner and tc.tg_chat_id = p_tg_chat_id;

  if v_chat is null then
    return false;
  end if;

  if p_action is null or p_action = 'chatActionNone' or p_action = 'none' then
    delete from public.chat_typing
     where chat_id = v_chat and user_id = p_owner and source = 'telegram';
    return true;
  end if;

  insert into public.chat_typing (chat_id, user_id, source, action, tg_chat_id, expires_at)
  values (
    v_chat, p_owner, 'telegram',
    case
      when p_action in ('chatActionTyping','typing') then 'typing'
      when p_action in ('chatActionRecordAudio','record_audio') then 'record_audio'
      when p_action in ('chatActionRecordVideo','record_video') then 'record_video'
      when p_action in ('chatActionUploadAudio','upload_voice') then 'upload_voice'
      when p_action in ('chatActionUploadPhoto','upload_photo') then 'upload_photo'
      when p_action in ('chatActionUploadDocument','upload_document') then 'upload_document'
      when p_action in ('chatActionChooseSticker','choose_sticker') then 'choose_sticker'
      when p_action in ('chatActionFindLocation','find_location') then 'find_location'
      else 'typing'
    end,
    p_tg_chat_id,
    clock_timestamp() + make_interval(secs => greatest(2, least(coalesce(p_ttl_seconds, 6), 30)))
  )
  on conflict (chat_id, user_id, source) do update
    set action = excluded.action,
        tg_chat_id = excluded.tg_chat_id,
        updated_at = clock_timestamp(),
        expires_at = excluded.expires_at;

  return true;
end;
$$;

-- Read receipts to send to Telegram: the app has read past what we last synced.
-- The watermark lives on the mapping row, so this is a cheap set-difference
-- (no per-message bookkeeping) and a worker restart cannot re-send stale ticks.
create or replace function public.bridge_pending_reads(
  p_owner uuid,
  p_limit integer default 25
)
returns table (
  chat_id             uuid,
  tg_chat_id          bigint,
  max_read_message_id bigint
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with watermarks as (
    select tc.chat_id,
           tc.tg_chat_id,
           coalesce(tc.last_app_read_id, 0) as synced_through,
           cp.last_read_at
      from public.telegram_chats tc
      join public.chat_participants cp
        on cp.chat_id = tc.chat_id and cp.user_id = tc.owner_user_id and cp.left_at is null
     where tc.owner_user_id = p_owner
       and tc.chat_id is not null
       and tc.sync_direction in ('both','to_telegram')
       and cp.last_read_at is not null
  ), computed as (
    select w.chat_id,
           w.tg_chat_id,
           w.synced_through,
           max(m.tg_message_id) as max_read
      from watermarks w
      join public.messages m
        on m.chat_id = w.chat_id
       and m.tg_message_id is not null
       and m.deleted_at is null
       and m.sent_at <= w.last_read_at
     group by w.chat_id, w.tg_chat_id, w.synced_through
  )
  select c.chat_id, c.tg_chat_id, c.max_read
    from computed c
   where c.max_read > c.synced_through
   order by c.chat_id
   limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

create or replace function public.bridge_mark_reads_synced(
  p_owner      uuid,
  p_tg_chat_id bigint,
  p_max_read   bigint
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not app.is_service_role() then
    raise exception 'service_role only' using errcode = '42501';
  end if;

  update public.telegram_chats
     set last_app_read_id = greatest(coalesce(last_app_read_id, 0), p_max_read),
         reads_synced_at  = clock_timestamp(),
         updated_at       = clock_timestamp()
   where owner_user_id = p_owner
     and tg_chat_id = p_tg_chat_id
     and (last_app_read_id is null or p_max_read > last_app_read_id);

  return found;
end;
$$;

-- Reading Telegram on another device must clear the badge in MessengerX. The
-- bridge sees `updateReadInboxChatHistory` (we read the chat) and calls this; it
-- mirrors mark_chat_read() but is driven by a Telegram message id.
create or replace function public.bridge_mark_inbox_read(
  p_owner                 uuid,
  p_tg_chat_id            bigint,
  p_up_to_tg_message_id   bigint default null
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_chat       uuid;
  v_boundary   uuid;
  v_inserted   integer;
begin
  if not app.is_service_role() then
    raise exception 'service_role only' using errcode = '42501';
  end if;

  select tc.chat_id into v_chat
    from public.telegram_chats tc
   where tc.owner_user_id = p_owner and tc.tg_chat_id = p_tg_chat_id;

  if v_chat is null then
    return 0;
  end if;

  select m.id into v_boundary
    from public.messages m
   where m.chat_id = v_chat
     and m.deleted_at is null
     and (p_up_to_tg_message_id is null or m.tg_message_id <= p_up_to_tg_message_id)
   order by m.tg_message_id desc nulls last, m.id desc
   limit 1;

  with marked as (
    insert into public.message_reads (message_id, user_id)
    select m.id, p_owner
      from public.messages m
     where m.chat_id = v_chat
       and m.sender_id is distinct from p_owner
       and m.deleted_at is null
       and (v_boundary is null or m.id <= v_boundary)
    on conflict (message_id, user_id) do nothing
    returning 1
  )
  select count(*) into v_inserted from marked;

  update public.messages m
     set state = 'read',
         read_at = coalesce(m.read_at, clock_timestamp())
   where m.chat_id = v_chat
     and m.sender_id is distinct from p_owner
     and m.deleted_at is null
     and m.state <> 'read'
     and (v_boundary is null or m.id <= v_boundary);

  update public.chat_participants cp
     set last_read_message_id = coalesce(v_boundary, cp.last_read_message_id),
         last_read_at         = clock_timestamp(),
         unread_count         = 0,
         updated_at           = clock_timestamp()
   where cp.chat_id = v_chat and cp.user_id = p_owner and cp.left_at is null;

  return v_inserted;
end;
$$;

-- Reply threading. The app replies with its own message uuid; TDLib needs the
-- Telegram id, which lives on the same row. Batched because a burst of replies
-- after a reconnect must not cost one query per message.
create or replace function public.bridge_message_tg_ids(p_message_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(
           jsonb_object_agg(m.id::text, m.tg_message_id),
           '{}'::jsonb
         )
    from public.messages m
   where m.id = any (coalesce(p_message_ids, '{}'::uuid[]))
     and m.tg_message_id is not null
     and m.deleted_at is null;
$$;

-- Boot / crash recovery: which accounts should this process be holding open?
-- `needs_reauth` is included on purpose: the session has to exist again so the
-- user's next code entry lands somewhere. States are the enum from 00001.
create or replace function public.bridge_list_sessions(
  p_worker text,
  p_limit  integer default 200
)
returns table (
  user_id         uuid,
  username        text,
  auth_state      text,
  session_ref     text,
  tg_user_id      bigint,
  api_id          integer,
  assigned_worker text,
  sync_direction  text,
  has_login_token boolean,
  last_sync_at    timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select ta.user_id,
         p.username,
         ta.auth_state::text,
         ta.session_ref,
         ta.tg_user_id,
         ta.api_id,
         ta.worker_id,
         ta.sync_direction::text,
         ta.login_token_enc is not null,
         ta.last_sync_at
    from public.telegram_accounts ta
    join public.profiles p on p.id = ta.user_id and p.deleted_at is null
   where ta.auth_state in ('linked','syncing','needs_reauth')
     and (p_worker is null or ta.worker_id = p_worker or ta.worker_id is null)
   order by ta.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 200), 1000));
$$;

-- Drop stale rows even if the app stops calling (a janitor-free TTL).
create or replace function public.prune_chat_typing()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count integer;
begin
  delete from public.chat_typing where expires_at < clock_timestamp() - interval '30 seconds';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- grants + RLS
-- ---------------------------------------------------------------------------

-- 00009's blanket grants ran before this table existed, so this migration owns
-- the privileges for its own objects (the pattern for anything added later).
grant select, insert, update, delete on public.chat_typing to authenticated;
grant all on public.chat_typing to service_role;
revoke all on public.chat_typing from anon;

revoke all on function public.set_typing(uuid, boolean, text, interval) from public, anon, authenticated;
revoke all on function public.chat_typing_state(uuid) from public, anon;
revoke all on function public.bridge_pending_typing(uuid, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.bridge_report_typing(uuid, bigint, text, integer) from public, anon, authenticated;
revoke all on function public.bridge_pending_reads(uuid, integer) from public, anon, authenticated;
revoke all on function public.bridge_mark_reads_synced(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.bridge_mark_reads_synced(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.prune_chat_typing() from public, anon, authenticated;
revoke all on function public.bridge_mark_inbox_read(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.bridge_list_sessions(text, integer) from public, anon, authenticated;
revoke all on function public.bridge_message_tg_ids(uuid[]) from public, anon, authenticated;

grant execute on function public.set_typing(uuid, boolean, text, interval) to authenticated, service_role;
grant execute on function public.chat_typing_state(uuid) to authenticated, service_role, anon;
grant execute on function public.bridge_pending_typing(uuid, timestamptz, integer) to service_role;
grant execute on function public.bridge_report_typing(uuid, bigint, text, integer) to service_role;
grant execute on function public.bridge_pending_reads(uuid, integer) to service_role;
grant execute on function public.bridge_mark_reads_synced(uuid, bigint, bigint) to service_role;
grant execute on function public.prune_chat_typing() to service_role;
grant execute on function public.bridge_mark_inbox_read(uuid, bigint, bigint) to service_role;
grant execute on function public.bridge_list_sessions(text, integer) to service_role;
grant execute on function public.bridge_message_tg_ids(uuid[]) to service_role;

alter table public.chat_typing enable row level security;

drop policy if exists chat_typing_read on public.chat_typing;
create policy chat_typing_read on public.chat_typing
  for select
  to authenticated
  using (
    exists (
      select 1 from public.chat_participants cp
       where cp.chat_id = chat_typing.chat_id
         and cp.user_id = (select app.current_uid())
    )
  );

-- A member may only maintain their own row, and only for 'app' sourced presence.
drop policy if exists chat_typing_write_own on public.chat_typing;
create policy chat_typing_write_own on public.chat_typing
  for insert
  to authenticated
  with check (user_id = (select app.current_uid()) and source = 'app');

drop policy if exists chat_typing_update_own on public.chat_typing;
create policy chat_typing_update_own on public.chat_typing
  for update
  to authenticated
  using (user_id = (select app.current_uid()) and source = 'app')
  with check (user_id = (select app.current_uid()) and source = 'app');

drop policy if exists chat_typing_delete_own on public.chat_typing;
create policy chat_typing_delete_own on public.chat_typing
  for delete
  to authenticated
  using (user_id = (select app.current_uid()) and source = 'app');

-- Realtime: presence is ephemeral, so INSERT/UPDATE carry it; a stopped
-- indicator arrives as an update to 'none'-equivalent expiry, and the client also
-- drops rows past `expires_at` on its own timer.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_typing'
     ) then
    begin
      execute 'alter publication supabase_realtime add table public.chat_typing';
    exception when others then
      raise notice 'could not add public.chat_typing to supabase_realtime: %', sqlerrm;
    end;
  end if;
end
$$;
