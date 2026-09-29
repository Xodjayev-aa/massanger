-- =============================================================================
-- 00019_video_and_shorts.sql
-- MessengerX — Phase 1: video messages and the Shorts feed.
--
-- Video never touches Supabase Storage (the free tier's egress and file caps
-- make a video there a suspension waiting to happen; avatars, photos and voice
-- stay). The bytes live in a Backblaze B2 bucket, addressed by an object key
-- and reached through presigned S3 URLs minted by the `video-ticket` edge
-- function, which does the authorization (chat membership / account standing)
-- and enforces the hard caps:
--
--   • one MP4 quality — no transcoding pipeline, ever;
--   • ≤ 60 s per clip (chat video and shorts alike in Phase 1);
--   • ≤ 250 MB per object;
--   • ≤ 1080p / ~2 Mbps by construction of what the client accepts.
--
-- This migration adds the `video` value to `message_kind`, teaches
-- `app.validate_message_media` the video media contract, and creates the
-- `shorts` / `short_likes` pair with RLS. The Telegram outbox deliberately
-- skips video (see app.after_message_write below): a presigned link expires,
-- and Telegram must never receive a dead one.
--
-- Transaction note: Postgres refuses to *use* an enum value in the same
-- transaction that adds it. The only places that matter are SQL statements
-- evaluated immediately — notably the `messages_shape` CHECK. Its new arm is
-- therefore written as `kind not in ('text','image','voice','system')`, which
-- expresses "any kind the enum grows to accept follows the attachment shape"
-- without naming `video`. Function bodies are parsed at first execution, so
-- they may say 'video' freely.
-- =============================================================================

begin;

-- 1. The enum. `if not exists` keeps a re-apply a no-op.
-- ---------------------------------------------------------------------------
alter type public.message_kind add value if not exists 'video';

-- 2. messages_shape — extend the per-kind contract.
--
-- Verbatim arms from 00002 plus the forward-compatible arm described in the
-- header: a kind outside the original four must carry a real sender and media.
-- ---------------------------------------------------------------------------
alter table public.messages drop constraint if exists messages_shape;
alter table public.messages add constraint messages_shape check (
  (kind = 'text'  and coalesce(sender_id, sender_peer_id) is not null
                    and btrim(coalesce(body, '')) <> '' and media is null) or
  (kind = 'image' and coalesce(sender_id, sender_peer_id) is not null
                    and (media is not null or btrim(coalesce(body, '')) <> '')) or
  (kind = 'voice' and coalesce(sender_id, sender_peer_id) is not null and media is not null) or
  (kind = 'system' and sender_id is null and sender_peer_id is null
                     and btrim(coalesce(body, '')) <> '') or
  (kind not in ('text', 'image', 'voice', 'system')
     and coalesce(sender_id, sender_peer_id) is not null
     and media is not null)
);

-- 3. The media contract for video, in app.validate_message_media.
--
-- Replaces 00004 wholesale (create or replace keeps the triggers pointing at
-- it). Video is the first kind that does NOT live in a Supabase bucket: the
-- `store`/`key` pair names a B2 object, `bucket` is refused outright, and the
-- duration/size caps are enforced here so no code path can bypass them.
-- ---------------------------------------------------------------------------
create or replace function app.validate_message_media(p_kind public.message_kind, p_media jsonb)
returns void
language plpgsql
stable
set search_path = pg_catalog, public
as $$
begin
  if p_kind in ('text', 'system') then
    if p_media is not null then
      raise exception 'media must be null for % messages', p_kind
        using errcode = '22023';
    end if;
    return;
  end if;

  if p_media is null then
    raise exception 'media is required for % messages', p_kind
      using errcode = '22023';
  end if;

  if p_media ? 'bucket' and coalesce(p_media ->> 'bucket', '') not in ('images', 'voice-notes', 'avatars') then
    raise exception 'unsupported storage bucket \"%\" (expected images|voice-notes|avatars)', p_media ->> 'bucket'
      using errcode = '22023';
  end if;

  if p_kind = 'image' then
    if not (p_media ? 'path' or p_media ? 'url') then
      raise exception 'image media needs `path` (storage) or `url` (external)'
        using errcode = '22023';
    end if;
  elsif p_kind = 'voice' then
    if not (p_media ? 'path' or p_media ? 'url') then
      raise exception 'voice media needs `path` (storage) or `url` (external)'
        using errcode = '22023';
    end if;
    if coalesce((p_media ->> 'duration_ms')::int, 0) <= 0 then
      raise exception 'voice media requires a positive duration_ms'
        using errcode = '22023';
    end if;
    if p_media ? 'waveform' and jsonb_typeof(p_media -> 'waveform') <> 'array' then
      raise exception 'voice waveform must be a json array'
        using errcode = '22023';
    end if;
  elsif p_kind = 'video' then
    -- Not in a Supabase bucket — the bucket check above already rejects unknown
    -- bucket names, and *any* bucket reference is wrong for video.
    if p_media ? 'bucket' then
      raise exception 'video media must not reference a Supabase storage bucket (B2 object expected)'
        using errcode = '22023';
    end if;
    if coalesce(p_media ->> 'store', '') <> 'b2' then
      raise exception 'video media requires store = \"b2\"'
        using errcode = '22023';
    end if;
    if coalesce(p_media ->> 'key', '') = '' then
      raise exception 'video media requires an object key'
        using errcode = '22023';
    end if;
    if char_length(p_media ->> 'key') > 512
       or left(p_media ->> 'key', 1) = '/'
       or position('..' in p_media ->> 'key') > 0 then
      raise exception 'video media key must be a relative object path under 512 characters'
        using errcode = '22023';
    end if;
    -- Phase 1 is single-quality MP4 on purpose: there is no transcoding
    -- pipeline and there will not be one in this phase.
    if coalesce(p_media ->> 'mime', '') <> 'video/mp4' then
      raise exception 'video media must be video/mp4 (no transcoding pipeline)'
        using errcode = '22023';
    end if;
    if coalesce((p_media ->> 'duration_ms')::int, 0) <= 0 then
      raise exception 'video media requires a positive duration_ms'
        using errcode = '22023';
    end if;
    if (p_media ->> 'duration_ms')::int > 60000 then
      raise exception 'video media must stay under 60000 ms'
        using errcode = '22023';
    end if;
    if coalesce((p_media ->> 'size_bytes')::bigint, 0) <= 0 then
      raise exception 'video media requires a positive size_bytes'
        using errcode = '22023';
    end if;
    if (p_media ->> 'size_bytes')::bigint > 262144000 then
      raise exception 'video media must stay under 262144000 bytes (250 MB)'
        using errcode = '22023';
    end if;
  end if;
end;
$$;

-- 4. Telegram outbox: video is in-app only (reasoning lives in the function).
-- ---------------------------------------------------------------------------
create or replace function app.after_message_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_account public.telegram_accounts%rowtype;
  v_map     public.telegram_chats%rowtype;
begin
  if tg_op = 'INSERT' then
    update public.chats c
       set last_message_id   = new.id,
           last_message_at   = new.created_at,
           updated_at        = clock_timestamp()
     where c.id = new.chat_id
       and (c.last_message_at is null or c.last_message_at < new.created_at);

    update public.chat_participants cp
       set unread_count = cp.unread_count + 1,
           updated_at = clock_timestamp()
     where cp.chat_id = new.chat_id
       and cp.user_id <> new.sender_id
       and cp.left_at is null
       and new.sender_id is not null
       and (cp.last_read_message_id is null
            or cp.last_read_message_id < new.id);

    -- Transactional outbox: only app-originated content is forwarded.
    --
    -- `video` (00019) is deliberately excluded: Telegram needs a durable public
    -- media URL, while every B2 link this app mints expires by design. Forwarding
    -- one would send a dead link. The bridge path for video arrives with the
    -- Telegram-side hosting story, not here.
    if new.source = 'app'
       and new.kind <> 'system'
       and new.kind <> 'video'
       and new.sender_id is not null
       and new.deleted_at is null
    then
      select * into v_account from public.telegram_accounts ta where ta.user_id = new.sender_id;
      if found and v_account.auth_state = 'linked'
                  and v_account.sync_direction in ('both', 'to_telegram')
      then
        select * into v_map
        from public.telegram_chats tc
        where tc.owner_user_id = new.sender_id
          and (tc.chat_id = new.chat_id or tc.tg_chat_id = (select tg_peer_id from public.chats where id = new.chat_id))
        limit 1;

        if v_map.tg_chat_id is not null
           and coalesce(v_map.sync_direction, 'both') in ('both', 'to_telegram')
        then
          insert into public.telegram_outbox (
            message_id, owner_user_id, chat_id, tg_chat_id, kind, payload, state
          ) values (
            new.id, new.sender_id, new.chat_id, v_map.tg_chat_id, new.kind,
            jsonb_strip_nulls(jsonb_build_object(
              'text',       new.body,
              'media',      new.media,
              'reply_to',   new.reply_to_id,
              'tg_reply_to', (select m.tg_message_id from public.messages m where m.id = new.reply_to_id),
              'chat_kind',  (select c.kind::text || '' from public.chats c where c.id = new.chat_id),
              'created_at', new.created_at
            )),
            'queued'
          )
          on conflict (message_id) do nothing;
        end if;
      end if;
    end if;

    return new;
  end if;

  if new.deleted_at is not null and old.deleted_at is null then
    update public.chats c
       set last_message_id = (
             select m.id from public.messages m
             where m.chat_id = new.chat_id and m.deleted_at is null
             order by m.id desc limit 1
           ),
           last_message_at = (
             select m.created_at from public.messages m
             where m.chat_id = new.chat_id and m.deleted_at is null
             order by m.id desc limit 1
           ),
           updated_at = clock_timestamp()
     where c.id = new.chat_id;
  end if;

  return new;
end;
$$;



-- 5. Chat-list preview: a video with no caption renders as "Video".
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
        'MessengerX chat'
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
      -- ::text, not the enum: `language sql` bodies are parsed at CREATE time
      -- and Postgres refuses a not-yet-committed enum value in the same
      -- transaction (00019 added 'video' above).
      case lm.kind::text when 'image' then 'Photo'
                          when 'voice' then 'Voice message'
                          when 'video' then 'Video'
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


-- 6. Shorts: the vertical, full-screen, swipeable feed.
--
-- The row is the source of truth for the feed (keys are unguessable but the
-- list comes from the database, not from listing the bucket), and `object_key`
-- points at the same B2 bucket as chat video — scope prefixes (`shorts/<uid>/`)
-- keep the two apart, and `video-ticket` re-checks ownership on every
-- ticket. Hard deletes: the row disappearing is the feed's truth, and the B2
-- object is reclaimed by the orphan sweep documented in the runbook, exactly
-- like an unattached chat photo.
-- ---------------------------------------------------------------------------
create table if not exists public.shorts (
  id          uuid primary key default app.uuid_v7(),
  author_id   uuid not null references public.profiles (id) on delete cascade,
  object_key  text not null check (
    char_length(object_key) between 1 and 512
    and left(object_key, 1) <> '/'
    and position('..' in object_key) = 0
  ),
  mime        text not null default 'video/mp4' check (mime = 'video/mp4'),
  duration_ms integer not null check (duration_ms > 0 and duration_ms <= 60000),
  size_bytes  integer not null check (size_bytes > 0 and size_bytes <= 262144000),
  caption     text check (caption is null or char_length(caption) <= 500),
  like_count  integer not null default 0 check (like_count >= 0),
  created_at  timestamptz not null default clock_timestamp()
);

comment on table public.shorts is
  'Shorts feed rows. Bytes live in Backblaze B2 (object_key); RLS exposes the feed to signed-in users and writes to the author only. Hard delete — the B2 object is reclaimed by the orphan sweep.';

create table if not exists public.short_likes (
  short_id   uuid not null references public.shorts (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (short_id, user_id)
);

comment on table public.short_likes is
  'One row per (short, user) like. like_count on `shorts` is maintained by a SECURITY DEFINER trigger so clients cannot write the counter itself.';

create index if not exists short_likes_user_idx on public.short_likes (user_id, short_id);

-- 7. like_count maintenance. SECURITY DEFINER because the invoking role has no
-- UPDATE grant on `shorts` beyond `caption` — without definer rights the
-- trigger would silently update zero rows and every count would freeze.
-- ---------------------------------------------------------------------------
create or replace function app.short_likes_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.shorts set like_count = like_count + 1 where id = new.short_id;
  elsif tg_op = 'DELETE' then
    update public.shorts set like_count = greatest(like_count - 1, 0) where id = old.short_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists short_likes_recount on public.short_likes;
create trigger short_likes_recount
  after insert or delete on public.short_likes
  for each row execute function app.short_likes_recount();

-- 8. Grants. Narrow on purpose: `shorts` gets table-level SELECT/INSERT/DELETE
-- but only a COLUMN-level UPDATE on `caption`, which is the one field an
-- author may edit — `like_count` stays server-only (the trigger above updates
-- as the table owner, which ignores grants and RLS).
-- ---------------------------------------------------------------------------
grant all on public.shorts, public.short_likes to service_role;
grant select, insert, delete on public.shorts to authenticated;
grant update (caption) on public.shorts to authenticated;
grant select, insert, delete on public.short_likes to authenticated;
revoke all on public.shorts, public.short_likes from public, anon;

-- 9. RLS.
-- ---------------------------------------------------------------------------
alter table public.shorts enable row level security;
alter table public.short_likes enable row level security;

-- The feed is public to signed-in users (it is the product's Shorts tab);
-- writing is the author, gated by the same eligibility rule as a message.
drop policy if exists shorts_select on public.shorts;
create policy shorts_select on public.shorts
  for select to authenticated
  using (true);

drop policy if exists shorts_insert_own on public.shorts;
create policy shorts_insert_own on public.shorts
  for insert to authenticated
  with check (
    author_id = (select app.current_uid())
    and app.sender_may_post((select app.current_uid()))
  );

drop policy if exists shorts_update_own on public.shorts;
create policy shorts_update_own on public.shorts
  for update to authenticated
  using (author_id = (select app.current_uid()))
  with check (author_id = (select app.current_uid()));

drop policy if exists shorts_delete_own on public.shorts;
create policy shorts_delete_own on public.shorts
  for delete to authenticated
  using (author_id = (select app.current_uid()));

drop policy if exists short_likes_select_own on public.short_likes;
create policy short_likes_select_own on public.short_likes
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists short_likes_insert_own on public.short_likes;
create policy short_likes_insert_own on public.short_likes
  for insert to authenticated
  with check (user_id = (select app.current_uid()));

drop policy if exists short_likes_delete_own on public.short_likes;
create policy short_likes_delete_own on public.short_likes
  for delete to authenticated
  using (user_id = (select app.current_uid()));

-- 10. Function comments that name the new kind.
-- ---------------------------------------------------------------------------
comment on function public.send_message(uuid, public.message_kind, text, jsonb, uuid, uuid) is
  'Send text/image/voice/video. Idempotent on p_client_message_id. Enqueues Telegram forwarding in the same transaction (never for video).';

commit;
