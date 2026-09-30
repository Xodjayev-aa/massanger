-- =============================================================================
-- 00022_shorts_upgrade.sql
-- MessengerX 3.0 — the Shorts engine (the TikTok half of the product).
--
-- 00019 created `shorts` as the minimum a feed needs: a row, a key, a caption,
-- a like counter. This migration turns it into the real thing:
--
--   • For You / Following are two queries over the same rows, not two products:
--     `shorts_feed` takes the tab and joins the follow graph from 00020;
--   • a sound can be attached and re-used ("use this sound"), with its use
--     counter maintained by trigger — that is the loop that makes a sound trend;
--   • saves, shares, views and the private/unlisted/followers visibility levels
--     mirror the long-form engine, so the two surfaces behave identically;
--   • `shorts_saves` doubles as the "Liked" equivalent for the Saved tab.
--
-- Everything writable stays behind SECURITY DEFINER RPCs: a client sends
-- "watched 4s of this" or "save this", never "view_count = view_count + 1".
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columns the feed needs on the existing table.
-- ---------------------------------------------------------------------------
alter table public.shorts
  add column if not exists view_count     bigint  not null default 0 check (view_count >= 0),
  add column if not exists share_count    integer not null default 0 check (share_count >= 0),
  add column if not exists save_count     integer not null default 0 check (save_count >= 0),
  add column if not exists comment_count  integer not null default 0 check (comment_count >= 0),
  add column if not exists sound_id       uuid references public.sounds (id) on delete set null,
  add column if not exists visibility     text not null default 'public'
                                          check (visibility in ('public', 'unlisted', 'private', 'followers')),
  add column if not exists is_removed     boolean not null default false,
  add column if not exists allow_comments boolean not null default true,
  add column if not exists language       text not null default 'en'
                                          check (char_length(language) between 2 and 16),
  -- Rendered on device (Canvas/paint-over) and uploaded like any other poster
  -- frame; the feed grid uses it where a video element would be wasteful.
  add column if not exists thumbnail_key  text,
  -- Duet / stitch pointers: the short this one answers, if any.
  add column if not exists reply_to_short uuid references public.shorts (id) on delete set null,
  add column if not exists kind           text not null default 'original'
                                          check (kind in ('original', 'duet', 'stitch', 'tiktok-style-repost'));

comment on column public.shorts.kind is
  'original | duet | stitch | repost. A duet/stitch keeps `reply_to_short`, which the player renders as the split/segmented source.';

create index if not exists shorts_feed_idx
  on public.shorts (created_at desc, id desc)
  where is_removed = false and visibility in ('public', 'followers');
create index if not exists shorts_author_idx
  on public.shorts (author_id, created_at desc) where is_removed = false;
create index if not exists shorts_sound_idx
  on public.shorts (sound_id, created_at desc) where sound_id is not null and is_removed = false;

-- A short with a non-public visibility is a draft/private post: it must not be
-- reachable by id either.
create or replace function app.short_visible(p_short_id uuid, p_viewer uuid default null)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.shorts s
     where s.id = p_short_id
       and s.is_removed = false
       and (
         s.author_id = p_viewer
         or (s.visibility = 'unlisted')
         or (s.visibility = 'public' and app.can_view_user(p_viewer, s.author_id))
         or (s.visibility = 'followers' and app.is_following(p_viewer, s.author_id))
       )
  );
$$;

comment on function app.short_visible(uuid, uuid) is
  'Visibility gate for one short; video-ticket calls it before signing a playback URL.';

-- ---------------------------------------------------------------------------
-- 2. Saves (bookmarks) — the Saved tab and the `save_count` counter.
-- ---------------------------------------------------------------------------
create table if not exists public.short_saves (
  short_id   uuid not null references public.shorts (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (short_id, user_id)
);

create index if not exists short_saves_user_idx on public.short_saves (user_id, created_at desc);

create or replace function app.short_saves_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.shorts set save_count = save_count + 1 where id = new.short_id;
  elsif tg_op = 'DELETE' then
    update public.shorts set save_count = greatest(save_count - 1, 0) where id = old.short_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists short_saves_recount on public.short_saves;
create trigger short_saves_recount
  after insert or delete on public.short_saves
  for each row execute function app.short_saves_recount();

-- ---------------------------------------------------------------------------
-- 3. Watch events — the signal the For You ranking is actually built from.
--
-- `completed` + `replayed` + `skipped_early` are the three numbers a
-- recommendation engine needs: watched to the end, watched twice, or swiped
-- away in the first second.
-- ---------------------------------------------------------------------------
create table if not exists public.short_views (
  id            bigint generated always as identity primary key,
  short_id      uuid not null references public.shorts (id) on delete cascade,
  user_id       uuid references public.profiles (id) on delete set null,
  session_id    text not null check (char_length(session_id) between 6 and 64),
  watched_ms    integer not null default 0 check (watched_ms >= 0),
  completed     boolean not null default false,
  replayed      boolean not null default false,
  skipped_early boolean not null default false,
  created_at    timestamptz not null default clock_timestamp()
);

create unique index if not exists short_views_session_key on public.short_views (short_id, session_id);
create index if not exists short_views_short_idx on public.short_views (short_id, created_at desc);
create index if not exists short_views_user_idx on public.short_views (user_id, created_at desc);

-- Sound usage follows the same rule: attaching a sound to a real short counts
-- once, deleting the short gives it back. Nothing else may touch `use_count`.
create or replace function app.shorts_sound_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    if new.sound_id is not null then
      update public.sounds set use_count = use_count + 1 where id = new.sound_id;
    end if;
  elsif tg_op = 'DELETE' then
    if old.sound_id is not null then
      update public.sounds set use_count = greatest(use_count - 1, 0) where id = old.sound_id;
    end if;
  elsif tg_op = 'UPDATE' and old.sound_id is distinct from new.sound_id then
    if old.sound_id is not null then
      update public.sounds set use_count = greatest(use_count - 1, 0) where id = old.sound_id;
    end if;
    if new.sound_id is not null then
      update public.sounds set use_count = use_count + 1 where id = new.sound_id;
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists shorts_sound_recount on public.shorts;
create trigger shorts_sound_recount
  after insert or update of sound_id or delete on public.shorts
  for each row execute function app.shorts_sound_recount();

-- ---------------------------------------------------------------------------
-- 4. The feed. One RPC, two tabs, plus `sound` and `saved` modes.
--
--   for_you   ranked by engagement rate (finish + like + share) with a recency
--             decay and an author-affinity term
--   following authors the caller follows
--   sound     every short using one sound
--   saved     the caller's own saves
--   profile   one author's shorts (that person's Shorts tab)
-- ---------------------------------------------------------------------------
create or replace function public.shorts_feed(
  p_tab       text default 'for_you',
  p_before_at timestamptz default null,
  p_before_id uuid default null,
  p_limit     integer default 10,
  p_sound_id  uuid default null,
  p_author_id uuid default null
)
returns table (
  id             uuid,
  author_id      uuid,
  object_key     text,
  thumbnail_key  text,
  duration_ms    integer,
  size_bytes     integer,
  caption        text,
  kind           text,
  visibility     text,
  like_count     integer,
  comment_count  integer,
  view_count     bigint,
  share_count    integer,
  save_count     integer,
  created_at     timestamptz,
  liked_by_me    boolean,
  saved_by_me    boolean,
  author_name    text,
  author_username text,
  author_discriminator smallint,
  author_avatar  text,
  author_verified boolean,
  followed_by_me boolean,
  sound_id       uuid,
  sound_title    text,
  sound_artist   text,
  sound_origin   text,
  reply_to_short uuid
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as uid), base as (
    select s.*
      from public.shorts s
     where s.is_removed = false
       and app.can_view_user((select uid from me), s.author_id)
       and (
         case p_tab
           when 'saved'     then exists (select 1 from public.short_saves sv
                                          where sv.short_id = s.id and sv.user_id = (select uid from me))
           when 'sound'     then s.sound_id = p_sound_id
           when 'profile'   then s.author_id = p_author_id
           when 'following' then app.is_following((select uid from me), s.author_id)
           else false
         end
         or (
           p_tab = 'for_you'
           and s.visibility = 'public'
         )
       )
       and (
         -- for_you only shows public content; the other tabs respect visibility.
         p_tab <> 'for_you'
         or s.visibility = 'public'
       )
       and (
         p_tab in ('saved', 'profile')
         or s.visibility in ('public', 'followers')
       )
  )
  select s.id,
         s.author_id,
         s.object_key,
         s.thumbnail_key,
         s.duration_ms,
         s.size_bytes,
         s.caption,
         s.kind,
         s.visibility,
         s.like_count,
         s.comment_count,
         s.view_count,
         s.share_count,
         s.save_count,
         s.created_at,
         exists (select 1 from public.short_likes sl
                  where sl.short_id = s.id and sl.user_id = (select uid from me)),
         exists (select 1 from public.short_saves sv
                  where sv.short_id = s.id and sv.user_id = (select uid from me)),
         coalesce(nullif(btrim(p.display_name), ''), p.username),
         p.username,
         p.discriminator,
         p.avatar_path,
         p.verified,
         case when (select uid from me) is null then false
              else app.is_following((select uid from me), p.id) end,
         s.sound_id,
         so.title,
         so.artist,
         so.origin,
         s.reply_to_short
    from base s
    join public.profiles p on p.id = s.author_id and p.deleted_at is null
    left join public.sounds so on so.id = s.sound_id
   where p_before_at is null
      or (s.created_at, s.id) < (p_before_at, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
   order by
     -- The For You ranking: engagement per view, decayed by age, plus a small
     -- affinity bonus for people the viewer already follows. Everything here is
     -- deterministic and inspectable — no black box in a $0 stack.
     case when p_tab = 'for_you' then (
       (
         coalesce(s.like_count, 0) * 2.0
         + coalesce(s.comment_count, 0) * 4.0
         + coalesce(s.share_count, 0) * 6.0
         + (coalesce(s.view_count, 0) * 0.25)
       ) / greatest(extract(epoch from clock_timestamp() - s.created_at) / 3600.0 + 2.0, 2.0)
       + case when app.is_following((select uid from me), s.author_id) then 5.0 else 0.0 end
     ) end desc nulls last,
     s.created_at desc,
     s.id desc
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

comment on function public.shorts_feed(text, timestamptz, uuid, integer, uuid, uuid) is
  'Shorts feed: for_you | following | sound | saved | profile, keyset-paginated, with author, sound and the caller''s like/save state.';

-- ---------------------------------------------------------------------------
-- 5. Write RPCs.
-- ---------------------------------------------------------------------------
create or replace function public.publish_short(
  p_object_key    text,
  p_duration_ms   integer,
  p_size_bytes    integer,
  p_caption       text default null,
  p_visibility    text default 'public',
  p_sound_id      uuid default null,
  p_kind          text default 'original',
  p_reply_to_short uuid default null,
  p_thumbnail_key text default null,
  p_allow_comments boolean default true,
  p_language      text default 'en'
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) or not app.sender_may_post(v_uid) then
    raise exception 'this account may not post yet' using errcode = '42501';
  end if;
  if p_object_key is null or p_object_key not like 'shorts/' || v_uid::text || '/%' then
    raise exception 'the short key does not belong to this account' using errcode = '42501';
  end if;
  if p_thumbnail_key is not null and p_thumbnail_key not like 'thumb/' || v_uid::text || '/%' then
    raise exception 'the thumbnail key does not belong to this account' using errcode = '42501';
  end if;
  if p_duration_ms is null or p_duration_ms <= 0 or p_duration_ms > 60000 then
    raise exception 'shorts stay between 0 and 60 seconds' using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes <= 0 then
    raise exception 'a short needs a verified size' using errcode = '22023';
  end if;
  if p_kind not in ('original', 'duet', 'stitch', 'tiktok-style-repost') then
    raise exception 'unknown short kind %', p_kind using errcode = '22023';
  end if;
  if p_kind <> 'original' and p_reply_to_short is null then
    raise exception 'a duet or stitch needs the short it answers' using errcode = '22023';
  end if;
  if p_reply_to_short is not null and not app.short_visible(p_reply_to_short, v_uid) then
    raise exception 'that short is not available' using errcode = '42501';
  end if;

  insert into public.shorts (author_id, object_key, thumbnail_key, duration_ms, size_bytes,
                             caption, visibility, sound_id, kind, reply_to_short,
                             allow_comments, language)
  values (v_uid, p_object_key, p_thumbnail_key, p_duration_ms, p_size_bytes,
          nullif(btrim(coalesce(p_caption, '')), ''), coalesce(p_visibility, 'public'),
          p_sound_id, p_kind, p_reply_to_short, coalesce(p_allow_comments, true),
          coalesce(nullif(btrim(p_language), ''), 'en'))
  returning id into v_id;

  update public.profiles set post_count = post_count + 1, updated_at = clock_timestamp()
   where id = v_uid;

  -- Subscribers hear about it; the profile is opted in through notify_level.
  insert into public.notifications (user_id, kind, actor_id, short_id, payload)
  select f.follower_id, 'new_short', v_uid, v_id,
         jsonb_build_object('caption', left(coalesce(btrim(p_caption), ''), 140))
    from public.follows f
   where f.followee_id = v_uid and f.state = 'accepted' and f.notify_level <> 'none';

  return v_id;
end;
$$;

create or replace function public.rate_short(p_short_id uuid, p_kind text default 'like')
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_on  boolean;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_kind not in ('like', 'save') then
    raise exception 'kind must be like | save' using errcode = '22023';
  end if;
  if not app.short_visible(p_short_id, v_uid) then
    raise exception 'that short is not available' using errcode = '42501';
  end if;

  if p_kind = 'like' then
    select exists (select 1 from public.short_likes l
                    where l.short_id = p_short_id and l.user_id = v_uid) into v_on;
    -- like_count is owned by app.short_likes_recount() (00019): the insert and
    -- delete below are the whole write path, never a second manual bump.
    if v_on then
      delete from public.short_likes l where l.short_id = p_short_id and l.user_id = v_uid;
      return false;
    end if;
    insert into public.short_likes (short_id, user_id) values (p_short_id, v_uid) on conflict do nothing;
    -- A like on somebody else's short is a notification, never a self-notify.
    insert into public.notifications (user_id, kind, actor_id, short_id, payload)
    select s.author_id, 'like', v_uid, s.id, '{}'::jsonb
      from public.shorts s where s.id = p_short_id and s.author_id <> v_uid;
    return true;
  end if;

  select exists (select 1 from public.short_saves sv
                  where sv.short_id = p_short_id and sv.user_id = v_uid) into v_on;
  if v_on then
    delete from public.short_saves sv where sv.short_id = p_short_id and sv.user_id = v_uid;
    return false;
  end if;
  insert into public.short_saves (short_id, user_id) values (p_short_id, v_uid) on conflict do nothing;
  return true;
end;
$$;

comment on function public.rate_short(uuid, text) is
  'Toggle like or save on a short. Returns the new state; the counter moves server-side only.';

create or replace function public.record_short_view(
  p_short_id   uuid,
  p_session_id text,
  p_watched_ms integer default 0,
  p_completed  boolean default false,
  p_replayed   boolean default false,
  p_skipped_early boolean default false
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_new_id uuid;
begin
  if p_session_id is null or char_length(p_session_id) < 6 then
    raise exception 'a view needs a session id' using errcode = '22023';
  end if;
  if not app.short_visible(p_short_id, v_uid) then
    raise exception 'that short is not available' using errcode = '42501';
  end if;

  -- Two reasons for the CTE: only the transaction that actually inserted gets a
  -- row back (so concurrent replays of one session count once), and the
  -- engagement columns still fold in every replay's numbers.
  with ins as (
    insert into public.short_views (short_id, user_id, session_id, watched_ms, completed, replayed, skipped_early)
    values (p_short_id, v_uid, p_session_id, greatest(coalesce(p_watched_ms, 0), 0),
            coalesce(p_completed, false), coalesce(p_replayed, false), coalesce(p_skipped_early, false))
    on conflict (short_id, session_id) do nothing
    returning short_id
  )
  select short_id into v_new_id from ins;

  if v_new_id is not null then
    update public.shorts set view_count = view_count + 1 where id = p_short_id;
  else
    -- Already seen this session: merge the replay signals into the one row.
    update public.short_views sv
       set watched_ms    = greatest(sv.watched_ms, greatest(coalesce(p_watched_ms, 0), 0)),
           completed     = sv.completed or coalesce(p_completed, false),
           replayed      = sv.replayed or coalesce(p_replayed, false),
           skipped_early = sv.skipped_early and coalesce(p_skipped_early, false)
     where sv.short_id = p_short_id and sv.session_id = p_session_id;
  end if;
end;
$$;

create or replace function public.share_short(p_short_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not app.short_visible(p_short_id, app.current_uid()) then
    raise exception 'that short is not available' using errcode = '42501';
  end if;
  update public.shorts set share_count = share_count + 1 where id = p_short_id;
end;
$$;

create or replace function public.delete_short(p_short_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  delete from public.shorts s
   where s.id = p_short_id and (s.author_id = v_uid or app.caller_is_service_role());
  if not found then
    raise exception 'only the author may delete this short' using errcode = '42501';
  end if;
  update public.profiles set post_count = greatest(post_count - 1, 0)
   where id = v_uid and post_count > 0;
end;
$$;

-- Sounds ------------------------------------------------------------------
create or replace function public.create_sound(
  p_title       text,
  p_object_key  text,
  p_duration_ms integer,
  p_size_bytes  integer,
  p_mime        text default 'audio/mpeg',
  p_origin      text default 'upload',
  p_artist      text default null,
  p_license     text default 'user',
  p_voice_script text default null,
  p_voice_name  text default null,
  p_voice_locale text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_object_key is null or p_object_key not like 'sounds/' || v_uid::text || '/%' then
    raise exception 'the sound key does not belong to this account' using errcode = '42501';
  end if;
  if p_origin not in ('upload', 'tts', 'extracted', 'library') then
    raise exception 'unknown sound origin %', p_origin using errcode = '22023';
  end if;
  if p_origin = 'tts' and coalesce(btrim(p_voice_script), '') = '' then
    raise exception 'an AI voice-over keeps its script' using errcode = '22023';
  end if;
  if p_license not in ('user', 'cc0', 'cc-by', 'public-domain', 'library') then
    raise exception 'unknown license %', p_license using errcode = '22023';
  end if;

  insert into public.sounds (owner_id, title, artist, object_key, mime, duration_ms,
                             size_bytes, origin, license, voice_script, voice_name, voice_locale)
  values (v_uid, btrim(p_title), nullif(btrim(coalesce(p_artist, '')), ''), p_object_key,
          coalesce(p_mime, 'audio/mpeg'), p_duration_ms, p_size_bytes, p_origin,
          coalesce(p_license, 'user'), nullif(btrim(coalesce(p_voice_script, '')), ''),
          nullif(btrim(coalesce(p_voice_name, '')), ''), nullif(btrim(coalesce(p_voice_locale, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.sounds_feed(p_query text default null, p_limit integer default 30)
returns table (
  id          uuid,
  title       text,
  artist      text,
  origin      text,
  duration_ms integer,
  use_count   integer,
  created_at  timestamptz,
  owner_name  text,
  owner_username text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select so.id, so.title, so.artist, so.origin, so.duration_ms, so.use_count, so.created_at,
         coalesce(nullif(btrim(p.display_name), ''), p.username),
         p.username
    from public.sounds so
    left join public.profiles p on p.id = so.owner_id
   where (nullif(btrim(coalesce(p_query, '')), '') is null
          or so.title ilike '%' || btrim(p_query) || '%'
          or coalesce(so.artist, '') ilike '%' || btrim(p_query) || '%')
   order by so.use_count desc, so.created_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- ---------------------------------------------------------------------------
-- 6. RLS + grants.
-- ---------------------------------------------------------------------------
alter table public.short_saves enable row level security;
alter table public.short_views enable row level security;

-- 00019's `shorts_select` policy was `using (true)`; visibility makes it
-- narrower, and the shortcut of "a short is public" is now an explicit rule.
drop policy if exists shorts_select on public.shorts;
create policy shorts_select on public.shorts
  for select to authenticated
  using (
    is_removed = false
    and (
      author_id = (select app.current_uid())
      or case visibility
           when 'public'    then app.can_view_user((select app.current_uid()), author_id)
           when 'followers' then app.is_following((select app.current_uid()), author_id)
           when 'unlisted'  then true
           else false
         end
    )
  );

drop policy if exists shorts_update_own on public.shorts;
create policy shorts_update_own on public.shorts
  for update to authenticated
  using (author_id = (select app.current_uid()))
  with check (author_id = (select app.current_uid()));

drop policy if exists short_saves_read_own on public.short_saves;
create policy short_saves_read_own on public.short_saves
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists short_views_own on public.short_views;
create policy short_views_own on public.short_views
  for select to authenticated
  using (user_id = (select app.current_uid()));

grant select on public.shorts to authenticated;
grant update (caption, visibility, allow_comments) on public.shorts to authenticated;
grant select on public.short_saves to authenticated;
grant select on public.short_views to authenticated;
revoke all on public.short_saves, public.short_views from anon;

grant execute on function
  public.shorts_feed(text, timestamptz, uuid, integer, uuid, uuid),
  public.publish_short(text, integer, integer, text, text, uuid, text, uuid, text, boolean, text),
  public.rate_short(uuid, text),
  public.record_short_view(uuid, text, integer, boolean, boolean, boolean),
  public.share_short(uuid),
  public.delete_short(uuid),
  public.create_sound(text, text, integer, integer, text, text, text, text, text, text, text),
  public.sounds_feed(text, integer)
to authenticated;

comment on function public.publish_short(text, integer, integer, text, text, uuid, text, uuid, text, boolean, text) is
  'Publish a short after video-ticket verified the real size/duration. Notifies the author''s subscribers.';

commit;
