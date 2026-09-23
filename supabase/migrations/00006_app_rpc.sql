-- =============================================================================
-- 00006_app_rpc.sql
-- Massanger — the RPC surface consumed by the Flutter client.
--
-- Rules of thumb used here:
--   * read paths are SECURITY INVOKER ⇒ RLS is the authorisation layer;
--   * write paths that must touch several rows (or another user's row, e.g.
--     delivery receipts) are SECURITY DEFINER with explicit checks inside;
--   * every function clamps its own limits and never trusts client ids.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- chat_feed — one paged window of a conversation, already resolved for the UI
-- (sender snapshot + quoted-reply preview + tick timestamps).
-- ---------------------------------------------------------------------------
create or replace function public.chat_feed(
  p_chat_id   uuid,
  p_before_id uuid    default null,   -- last (newest) loaded id, for "load older"
  p_limit     integer default 30
)
returns table (
  id                    uuid,
  chat_id               uuid,
  kind                  text,
  body                  text,
  media                 jsonb,
  sender_id             uuid,
  sender_name           text,
  sender_avatar_path    text,
  is_mine               boolean,
  state                 text,
  created_at            timestamptz,
  sent_at               timestamptz,
  delivered_at          timestamptz,
  read_at               timestamptz,
  edited_at             timestamptz,
  failure_code          text,
  failure_reason        text,
  reply_to_id           uuid,
  reply_sender_name     text,
  reply_body            text,
  reply_kind            text,
  source                text,
  client_message_id     uuid,
  tg_message_id         bigint,
  synced_to_telegram_at timestamptz
)
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  if app.current_uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not app.is_chat_member(p_chat_id, app.current_uid()) then
    raise exception 'not a participant of chat %', p_chat_id using errcode = '42501';
  end if;

  return query
  select
    m.id,
    m.chat_id,
    m.kind::text,
    m.body,
    m.media,
    m.sender_id,
    m.sender_name,
    m.sender_avatar_path,
    (m.sender_id = app.current_uid()),
    m.state::text,
    m.created_at,
    m.sent_at,
    m.delivered_at,
    m.read_at,
    m.edited_at,
    m.failure_code,
    m.failure_reason,
    m.reply_to_id,
    r.sender_name,
    left(coalesce(r.body, case r.kind when 'image' then 'Photo' when 'voice' then 'Voice message'
                                    when 'system' then r.body else '' end), 160),
    r.kind::text,
    m.source::text,
    m.client_message_id,
    m.tg_message_id,
    m.synced_to_telegram_at
  from public.messages m
  left join public.messages r
    on r.id = m.reply_to_id
   and r.deleted_at is null
  where m.chat_id = p_chat_id
    and m.deleted_at is null
    and (p_before_id is null or m.id < p_before_id)
  order by m.id desc
  limit v_limit;
end;
$$;

-- ---------------------------------------------------------------------------
-- chat_summaries — the home screen in a single round-trip:
-- preview + unread badge + peer presence + Telegram mirror status, and the
-- search bar is just `p_query` on the same shape.
-- ---------------------------------------------------------------------------
create or replace function public.chat_summaries(
  p_query text    default null,
  p_limit integer default 60
)
returns table (
  chat_id            uuid,
  kind               text,
  title              text,
  avatar_path        text,
  avatar_external_url text,
  is_telegram_mirror boolean,
  tg_chat_id         bigint,
  tg_chat_type       text,
  sync_direction     text,
  last_message_id    uuid,
  last_message_at    timestamptz,
  preview_body       text,
  preview_sender     text,
  preview_kind       text,
  preview_state      text,
  preview_is_mine    boolean,
  unread_count       integer,
  is_muted           boolean,
  pinned_at          timestamptz,
  peer_id            uuid,
  peer_username      text,
  peer_display_name  text,
  peer_avatar_path   text,
  peer_is_online     boolean,
  telegram_auth_state text,
  telegram_username  text
)
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  with me as (
    select app.current_uid() as uid
  ),
  q as (
    select nullif(btrim(coalesce(p_query, '')), '') as needle
  ),
  base as (
    select
      c.id,
      c.kind,
      c.title,
      c.avatar_path,
      c.avatar_external_url,
      c.is_telegram_mirror,
      c.tg_peer_id,
      c.tg_chat_type,
      c.last_message_id,
      c.last_message_at,
      cp.unread_count,
      cp.pinned_at,
      (cp.muted_until is not null and cp.muted_until > clock_timestamp()) as is_muted,
      coalesce(tc.sync_direction, ta.sync_direction, 'off'::public.sync_direction) as sync_direction,
      ta.auth_state                                   as telegram_auth_state,
      ta.tg_username                                  as telegram_username,
      coalesce(
        nullif(btrim(c.title), ''),
        case when p2.username is not null then '@' || p2.username else null end,
        tp.display_name,
        tp.username,
        'Massanger chat'
      ) as resolved_title,
      p2.id            as peer_id,
      p2.username      as peer_username,
      p2.display_name  as peer_display_name,
      p2.avatar_path   as peer_avatar_path,
      (p2.last_seen_at > clock_timestamp() - interval '5 minutes') as peer_is_online
    from me
    cross join q
    join public.chat_participants cp on cp.user_id = me.uid and cp.left_at is null
    join public.chats c               on c.id = cp.chat_id
    left join public.chat_participants other
           on other.chat_id = c.id
          and other.user_id <> me.uid
          and other.left_at is null
          and c.kind = 'direct'
    -- `directory`, not `profiles`: a client may only read its own profile row,
    -- so the peer's identity has to come from the public projection.
    left join public.directory p2     on p2.id = other.user_id
    left join public.telegram_chats tc on tc.chat_id = c.id and tc.owner_user_id = me.uid
    left join public.telegram_accounts ta on ta.user_id = me.uid
    left join public.telegram_peers tp
           on tp.id = (
                select pm.sender_peer_id from public.messages pm
                where pm.chat_id = c.id and pm.sender_peer_id is not null
                order by pm.id desc limit 1
              )
    where q.needle is null
       or coalesce(nullif(btrim(c.title), ''), '') ilike '%' || q.needle || '%'
       or coalesce(p2.username, '') ilike '%' || q.needle || '%'
       or coalesce(p2.display_name, '') ilike '%' || q.needle || '%'
       or coalesce(tp.display_name, '') ilike '%' || q.needle || '%'
       or coalesce(tp.username, '') ilike '%' || q.needle || '%'
  )
  select
    b.id,
    b.kind::text,
    b.resolved_title,
    b.avatar_path,
    b.avatar_external_url,
    b.is_telegram_mirror,
    b.tg_peer_id,
    b.tg_chat_type,
    b.sync_direction::text,
    lm.id,
    coalesce(lm.created_at, b.last_message_at),
    coalesce(
      nullif(btrim(lm.body), ''),
      case lm.kind when 'image' then 'Photo'
                   when 'voice' then 'Voice message'
                   else null end
    ),
    case when lm.sender_id is not null and lm.sender_id = (select uid from me)
         then 'You' else lm.sender_name end,
    lm.kind::text,
    lm.state::text,
    (lm.sender_id = (select uid from me)),
    b.unread_count,
    b.is_muted,
    b.pinned_at,
    b.peer_id,
    b.peer_username,
    b.peer_display_name,
    b.peer_avatar_path,
    b.peer_is_online,
    b.telegram_auth_state::text,
    b.telegram_username
  from base b
  left join lateral (
    select m.id, m.body, m.kind, m.sender_id, m.sender_name, m.created_at, m.state
    from public.messages m
    where m.chat_id = b.id and m.deleted_at is null
    order by m.id desc
    limit 1
  ) lm on true
  where (select uid from me) is not null
  order by (b.pinned_at is not null) desc,
           coalesce(lm.created_at, b.last_message_at) desc nulls last,
           b.id desc
  limit least(greatest(coalesce(p_limit, 60), 1), 200);
$$;

-- ---------------------------------------------------------------------------
-- search_messages — full-text (tsvector GIN) with an ILIKE fallback so short
-- or partial queries still match, and every result is RLS-filtered.
-- ---------------------------------------------------------------------------
create or replace function public.search_messages(
  p_query   text,
  p_chat_id uuid    default null,
  p_limit   integer default 40
)
returns table (
  id          uuid,
  chat_id     uuid,
  chat_title  text,
  body        text,
  snippet     text,
  kind        text,
  sender_name text,
  is_mine     boolean,
  created_at  timestamptz
)
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  with q as (
    select nullif(btrim(coalesce(p_query, '')), '') as needle
  ),
  hits as (
    select m.id, m.chat_id, m.body, m.kind, m.sender_name, m.sender_id, m.created_at
    from q
    join public.messages m
      on (p_chat_id is null or m.chat_id = p_chat_id)
     and m.deleted_at is null
     and q.needle is not null
     and (
       (length(q.needle) >= 3 and m.search_tsv @@ websearch_to_tsquery('simple', q.needle))
       or m.body ilike '%' || q.needle || '%'
     )
    order by m.id desc
    limit least(greatest(coalesce(p_limit, 40), 1) * 4, 400)
  )
  select
    h.id,
    h.chat_id,
    coalesce(nullif(btrim(c.title), ''), 'Direct'),
    h.body,
    left(h.body, 140),
    h.kind::text,
    h.sender_name,
    (h.sender_id = app.current_uid()),
    h.created_at
  from hits h
  join public.chats c on c.id = h.chat_id
  where app.is_chat_member(h.chat_id, app.current_uid())
  order by h.id desc
  limit least(greatest(coalesce(p_limit, 40), 1), 200);
$$;

-- ---------------------------------------------------------------------------
-- send_message — the single write path for outgoing content.
-- Idempotent on (sender_id, client_message_id) so a flaky network, a retry, or
-- a duplicate Realtime echo can never produce two bubbles.
-- ---------------------------------------------------------------------------
create or replace function public.send_message(
  p_chat_id           uuid,
  p_kind              public.message_kind,
  p_body              text    default null,
  p_media             jsonb   default null,
  p_reply_to_id       uuid    default null,
  p_client_message_id uuid    default null
)
returns public.messages
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_row public.messages%rowtype;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_kind = 'system' or p_kind is null then
    raise exception 'clients cannot write system messages' using errcode = '42501';
  end if;
  if not app.sender_may_post(v_uid) then
    raise exception 'account cannot send (eligibility check pending or account restricted)'
      using errcode = '42501';
  end if;
  if not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'not a participant of chat %', p_chat_id using errcode = '42501';
  end if;

  if p_client_message_id is not null then
    select * into v_row
    from public.messages m
    where m.sender_id = v_uid and m.client_message_id = p_client_message_id;
    if found then
      return v_row;                      -- replay of an earlier attempt
    end if;
  end if;

  begin
    insert into public.messages (
      chat_id, sender_id, kind, body, media, reply_to_id, source, state, client_message_id
    ) values (
      p_chat_id, v_uid, p_kind,
      nullif(btrim(coalesce(p_body, '')), ''),
      nullif(coalesce(p_media, '{}'::jsonb), '{}'::jsonb),
      p_reply_to_id,
      'app',
      case when p_client_message_id is not null then 'sending'::public.delivery_state else 'pending'::public.delivery_state end,
      p_client_message_id
    )
    returning * into v_row;
  exception when unique_violation then
    select * into v_row
    from public.messages m
    where m.sender_id = v_uid and m.client_message_id = p_client_message_id;
    if not found then
      raise;
    end if;
  end;

  return v_row;
end;
$$;

comment on function public.send_message is
  'Persists an outgoing message and (via trigger) enqueues its Telegram outbox job atomically.';

-- ---------------------------------------------------------------------------
-- create_direct_chat — find-or-create, so two users tapping each other at the
-- same moment converge on one chat instead of a unique violation.
-- ---------------------------------------------------------------------------
create or replace function public.create_direct_chat(
  p_peer_id       uuid default null,
  p_peer_username text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_peer    public.profiles%rowtype;
  v_chat_id uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'account is not eligible yet' using errcode = '42501';
  end if;

  select * into v_peer
  from public.profiles p
  where p.deleted_at is null
    and (p.id = p_peer_id or lower(p.username) = lower(btrim(coalesce(p_peer_username, ''))));

  if not found then
    raise exception 'peer not found' using errcode = 'P0002';
  end if;
  if v_peer.id = v_uid then
    raise exception 'cannot start a chat with yourself' using errcode = '22023';
  end if;

  select c.id into v_chat_id
  from public.chats c
  join public.chat_participants a on a.chat_id = c.id and a.user_id = v_uid and a.left_at is null
  join public.chat_participants b on b.chat_id = c.id and b.user_id = v_peer.id and b.left_at is null
  where c.kind = 'direct'
  limit 1;

  if v_chat_id is not null then
    -- Rejoin silently if the user had left/hid the conversation.
    update public.chat_participants cp
       set left_at = null, updated_at = clock_timestamp()
     where cp.chat_id = v_chat_id and cp.left_at is not null;
    return v_chat_id;
  end if;

  insert into public.chats (kind, created_by)
  values ('direct', v_uid)
  returning id into v_chat_id;

  insert into public.chat_participants (chat_id, user_id, role)
  values (v_chat_id, v_uid, 'owner'), (v_chat_id, v_peer.id, 'member');

  return v_chat_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Read / delivery receipts (drive the ticks on the *other* side).
-- ---------------------------------------------------------------------------
create or replace function public.mark_chat_read(p_chat_id uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid      uuid := app.current_uid();
  v_newest   uuid;
  v_advanced integer;
begin
  if v_uid is null or not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'not a participant of chat %', p_chat_id using errcode = '42501';
  end if;

  -- no max(uuid) aggregate in Postgres; the feed index answers this directly
  select m.id into v_newest
  from public.messages m
  where m.chat_id = p_chat_id
    and m.deleted_at is null
    and m.sender_id is distinct from v_uid
  order by m.id desc
  limit 1;

  update public.chat_participants cp
     set last_read_message_id = coalesce(v_newest, cp.last_read_message_id),
         last_read_at         = clock_timestamp(),
         unread_count         = 0,
         updated_at           = clock_timestamp()
   where cp.chat_id = p_chat_id and cp.user_id = v_uid;

  with marked as (
    insert into public.message_reads (message_id, user_id)
    select m.id, v_uid
    from public.messages m
    where m.chat_id = p_chat_id
      and m.sender_id is not null
      and m.sender_id <> v_uid
      and m.deleted_at is null
      and (v_newest is null or m.id <= v_newest)
    on conflict (message_id, user_id) do nothing
    returning 1
  )
  select count(*) into v_advanced from marked;

  update public.messages m
     set state = 'read'
   where m.chat_id = p_chat_id
     and m.sender_id is not null
     and m.sender_id <> v_uid
     and m.deleted_at is null
     and m.state <> 'read'
     and (v_newest is null or m.id <= v_newest);

  return coalesce(v_advanced, 0);
end;
$$;

create or replace function public.mark_messages_delivered(p_message_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_rows integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if coalesce(array_length(p_message_ids, 1), 0) = 0 then
    return 0;
  end if;

  with ids as (select unnest(p_message_ids) as id)
  update public.messages m
     set state = 'delivered'
   from ids
   where m.id = ids.id
     and m.deleted_at is null
     and m.source = 'app'
     and m.state in ('sending', 'pending', 'sent')
     and m.sender_id is distinct from v_uid
     and app.is_chat_member(m.chat_id, v_uid)
     -- only a *participant* may confirm receipt, never a stranger guessing ids
     and exists (select 1 from public.chat_participants cp
                  where cp.chat_id = m.chat_id and cp.user_id = v_uid and cp.left_at is null);

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

-- ---------------------------------------------------------------------------
-- Housekeeping the UI needs
-- ---------------------------------------------------------------------------
create or replace function public.delete_message(p_message_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  update public.messages m
     set deleted_at = clock_timestamp()
   where m.id = p_message_id
     and m.deleted_at is null
     -- RLS already proved the caller can see the row; ownership is the rule.
     and m.sender_id = v_uid;
  return found;
end;
$$;

create or replace function public.retry_message(p_message_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_msg     public.messages%rowtype;
  v_map     public.telegram_chats%rowtype;
begin
  select * into v_msg from public.messages m where m.id = p_message_id;
  if not found or v_msg.sender_id is distinct from v_uid or v_msg.deleted_at is not null then
    raise exception 'message not retryable' using errcode = '42501';
  end if;
  if not app.sender_may_post(v_uid) then
    raise exception 'account is not eligible to send' using errcode = '42501';
  end if;

  update public.messages m
     set state = 'pending', failure_code = null, failure_reason = null,
         state_changed_at = clock_timestamp()
   where m.id = p_message_id;

  select * into v_map
  from public.telegram_chats tc
  where tc.owner_user_id = v_uid and tc.chat_id = v_msg.chat_id;

  if v_map.tg_chat_id is not null
     and app.telegram_send_allowed(v_uid)
     and v_map.sync_direction in ('both', 'to_telegram')
  then
    insert into public.telegram_outbox (
      message_id, owner_user_id, chat_id, tg_chat_id, kind, payload, state,
      attempts, next_attempt_at, last_error
    ) values (
      v_msg.id, v_uid, v_msg.chat_id, v_map.tg_chat_id, v_msg.kind,
      jsonb_strip_nulls(jsonb_build_object(
        'text', v_msg.body, 'media', v_msg.media, 'reply_to', v_msg.reply_to_id,
        'tg_reply_to', (select m.tg_message_id from public.messages m where m.id = v_msg.reply_to_id)
      )),
      'queued', 0, clock_timestamp(), null
    )
    on conflict (message_id)
    do update set state = 'queued', attempts = 0, next_attempt_at = clock_timestamp(),
                  last_error = null, updated_at = clock_timestamp();
  end if;

  return true;
end;
$$;

-- Explicit re-sync entry point (the `telegram-send` edge function calls it).
-- Mirrors the conditions of app.after_message_write() for messages that were
-- written before a mapping/link existed. Idempotent: an outbox row that is
-- already queued, in flight or sent is never resurrected.
create or replace function public.enqueue_telegram_outbox(p_message_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_tg_chat bigint;
  r         record;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if coalesce(array_length(p_message_ids, 1), 0) = 0 then
    return 0;
  end if;
  if not app.sender_may_post(v_uid) then
    raise exception 'account is not eligible to send' using errcode = '42501';
  end if;
  if not app.telegram_send_allowed(v_uid) then
    return 0;                      -- nothing linked: not an error, just nothing to do
  end if;

  for r in
    select m.id as message_id, m.chat_id, m.kind, m.body, m.media, m.reply_to_id
    from public.messages m
    where m.id = any (select unnest(p_message_ids))
      and m.sender_id = v_uid
      and m.source = 'app'
      and m.kind <> 'system'
      and m.deleted_at is null
  loop
    select tc.tg_chat_id into v_tg_chat
    from public.telegram_chats tc
    where tc.owner_user_id = v_uid
      and tc.chat_id = r.chat_id
      and tc.sync_direction in ('both', 'to_telegram')
    limit 1;

    if v_tg_chat is null then
      continue;
    end if;

    insert into public.telegram_outbox (
      message_id, owner_user_id, chat_id, tg_chat_id, kind, payload, state
    ) values (
      r.message_id, v_uid, r.chat_id, v_tg_chat, r.kind,
      jsonb_strip_nulls(jsonb_build_object(
        'text',      r.body,
        'media',     r.media,
        'reply_to',  r.reply_to_id,
        'tg_reply_to', (select m.tg_message_id from public.messages m where m.id = r.reply_to_id)
      )),
      'queued'
    )
    on conflict (message_id) do nothing;
  end loop;

  return sql%rowcount;
end;
$$;

create or replace function public.heartbeat()
returns timestamptz
language sql
security invoker
set search_path = pg_catalog, public
as $$
  update public.profiles p
     set last_seen_at = clock_timestamp()
   where p.id = app.current_uid()
  returning p.last_seen_at;
$$;

create or replace function public.unread_total()
returns integer
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  select coalesce(sum(cp.unread_count)::int, 0)
  from public.chat_participants cp
  where cp.user_id = app.current_uid()
    and cp.left_at is null;
$$;

-- Profile writes funnel through here: the only place that knows which columns
-- a client is allowed to change, with storage-path validation for the avatar.
create or replace function public.update_profile(
  p_display_name      text default null,
  p_bio               text default null,
  p_avatar_path       text default null,
  p_telegram_username text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_row public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_avatar_path is not null
     and p_avatar_path not like (v_uid::text || '/%')
     and p_avatar_path not like 'avatars/' || (v_uid::text || '/%')
  then
    raise exception 'avatar path must live under your own storage prefix'
      using errcode = '42501';
  end if;

  update public.profiles p
     set display_name      = coalesce(left(nullif(btrim(p_display_name), ''), 64), p.display_name),
         bio               = coalesce(left(nullif(btrim(p_bio), ''), 280), p.bio),
         avatar_path       = coalesce(nullif(btrim(p_avatar_path), ''), p.avatar_path),
         telegram_username = coalesce(
           lower(nullif(btrim(regexp_replace(coalesce(p_telegram_username, ''), '^@', '')), '')),
           p.telegram_username
         )
   where p.id = v_uid
  returning * into v_row;

  return v_row;
end;
$$;

-- The gate screen state, in one call (never trusts a cached session claim).
create or replace function public.eligibility_status()
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'access_state',   p.access_state::text,
    'reason',         p.access_state_reason,
    'verified_at',    p.eligibility_verified_at,
    'attempts',       p.eligibility_attempts,
    'method',         p.eligibility_method,
    'google_email',   p.google_email,
    'created_at',     p.google_account_created_at,
    'age_days',       p.google_account_age_days,
    'username',       p.username
  ))
  from public.profiles p
  where p.id = app.current_uid();
$$;

-- ---------------------------------------------------------------------------
-- Telegram bridge, client-facing half (the Profile screen toggle + wizard).
-- ---------------------------------------------------------------------------
create or replace function public.telegram_link_state()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'auth_state',      ta.auth_state::text,
    'note',            ta.auth_step_note,
    'tg_user_id',      ta.tg_user_id,
    'tg_username',     ta.tg_username,
    'display_name',    ta.display_name,
    'sync_direction',  ta.sync_direction::text,
    'auto_download_voice', ta.auto_download_voice,
    'auto_download_media', ta.auto_download_media,
    'mirror_to_app',   ta.mirror_to_app,
    'linked_at',       ta.linked_at,
    'last_sync_at',    ta.last_sync_at,
    'last_error',      ta.last_error,
    'mirrored_chats',  (select count(*) from public.telegram_chats tc
                        where tc.owner_user_id = ta.user_id and tc.chat_id is not null),
    'pending_request', (
      select jsonb_build_object(
               'id', lr.id, 'kind', lr.kind::text, 'status', lr.status::text,
               'step', lr.step, 'qr_code', lr.qr_code, 'error', lr.error,
               'expires_at', lr.expires_at
             )
      from public.telegram_link_requests lr
      where lr.user_id = ta.user_id
        and lr.status in ('queued', 'claimed', 'awaiting_user')
      order by lr.created_at desc
      limit 1
    )
  ))
  from public.telegram_accounts ta
  where ta.user_id = app.current_uid();
$$;

create or replace function public.telegram_link_start(
  p_envelope jsonb  default null,   -- sealed {phone} (see app.valid_link_envelope)
  p_use_qr   boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'account is not eligible; complete verification first'
      using errcode = '42501';
  end if;

  -- One live handshake per user, and never while already linked.
  if exists (select 1 from public.telegram_accounts ta
             where ta.user_id = v_uid and ta.auth_state = 'linked') then
    raise exception 'a Telegram account is already linked' using errcode = '23505';
  end if;

  update public.telegram_link_requests lr
     set status = 'expired', step = 'cancelled', error = 'superseded', completed_at = clock_timestamp()
   where lr.user_id = v_uid and lr.status in ('queued', 'claimed', 'awaiting_user');

  if p_envelope is not null and not app.valid_link_envelope(p_envelope) then
    raise exception 'malformed credential envelope' using errcode = '22023';
  end if;

  insert into public.telegram_link_requests (user_id, kind, status, step, payload, expires_at)
  values (
    v_uid, 'link', 'queued', 'queued',
    coalesce(p_envelope, '{}'::jsonb) || jsonb_build_object('use_qr', p_use_qr),
    clock_timestamp() + interval '10 minutes'
  )
  returning id into v_id;

  update public.telegram_accounts ta
     set auth_state = 'awaiting_phone', auth_step_note = 'Starting secure session…'
   where ta.user_id = v_uid;

  return jsonb_build_object('request_id', v_id, 'step', 'queued',
                            'expires_at', (select expires_at from public.telegram_link_requests where id = v_id));
end;
$$;

-- The client only ever *appends* user input; the bridge clears it on read.
create or replace function public.telegram_link_submit(
  p_request_id uuid,
  p_envelope   jsonb
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_row     public.telegram_link_requests%rowtype;
  v_payload jsonb;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_row
  from public.telegram_link_requests lr
  where lr.id = p_request_id and lr.user_id = v_uid
  for update;

  if not found then
    raise exception 'link request not found' using errcode = 'P0002';
  end if;
  if v_row.expires_at < clock_timestamp() then
    raise exception 'link request expired; start again' using errcode = 'P0001';
  end if;
  if v_row.status = 'succeeded' then
    return false;
  end if;

  if not app.valid_link_envelope(p_envelope) then
    raise exception 'malformed credential envelope' using errcode = '22023';
  end if;
  v_payload := p_envelope;

  update public.telegram_link_requests lr
     set payload = coalesce(lr.payload, '{}'::jsonb) || v_payload,
         status  = 'queued',
         error   = null
   where lr.id = p_request_id;

  return true;
end;
$$;

create or replace function public.telegram_link_cancel(p_request_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.telegram_link_requests lr
     set status = 'failed', step = 'cancelled', error = 'cancelled_by_user',
         payload = null, completed_at = clock_timestamp()
   where lr.id = p_request_id
     and lr.user_id = app.current_uid()
     and lr.status in ('queued', 'claimed', 'awaiting_user')
  returning true;
$$;

create or replace function public.telegram_unlink()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.telegram_accounts ta
     set auth_state = 'revoked', unlinked_at = clock_timestamp(),
         auth_step_note = null, worker_id = null
   where ta.user_id = v_uid;

  update public.telegram_chats tc
     set sync_direction = 'off'
   where tc.owner_user_id = v_uid;

  insert into public.telegram_link_requests (user_id, kind, status, step, payload, expires_at)
  values (v_uid, 'unlink', 'queued', 'queued', jsonb_build_object('reason', 'user_unlink'),
          clock_timestamp() + interval '5 minutes')
  returning id into v_id;

  return jsonb_build_object('request_id', v_id);
end;
$$;

-- Profile-screen switches: they only ever touch preference columns.
create or replace function public.telegram_set_preferences(
  p_sync_direction      public.sync_direction default null,
  p_auto_download_voice boolean              default null,
  p_auto_download_media boolean              default null,
  p_mirror_to_app       boolean              default null
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.telegram_accounts ta
     set sync_direction      = coalesce(p_sync_direction, ta.sync_direction),
         auto_download_voice = coalesce(p_auto_download_voice, ta.auto_download_voice),
         auto_download_media = coalesce(p_auto_download_media, ta.auto_download_media),
         mirror_to_app       = coalesce(p_mirror_to_app, ta.mirror_to_app)
   where ta.user_id = app.current_uid()
  returning jsonb_build_object(
    'sync_direction', ta.sync_direction::text,
    'auto_download_voice', ta.auto_download_voice,
    'auto_download_media', ta.auto_download_media,
    'mirror_to_app', ta.mirror_to_app
  );
$$;

create or replace function public.telegram_set_chat_sync(
  p_chat_id uuid,
  p_direction public.sync_direction
)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.telegram_chats tc
     set sync_direction = p_direction
   where tc.chat_id = p_chat_id
     and tc.owner_user_id = app.current_uid()
  returning true;
$$;
