-- =============================================================================
-- 00021_video_platform.sql
-- MessengerX 3.0 — the long-form video engine (the "Home" tab).
--
-- The 00019 phase shipped shorts and chat clips: one MP4 quality, ≤ 60 s, and a
-- `video/<uid>`-style object key in Backblaze B2 minted by `video-ticket`.
-- This migration is the YouTube half of the product on top of that same
-- pipeline:
--
--   • `videos` — long-form rows (title, description, thumbnail, category,
--     visibility, chapters, tags) with the caps raised for real content;
--   • `video_likes` / `video_views` / `watch_progress` — engagement, analytics
--     and resume-where-you-left-off;
--   • `comments` + `comment_likes` — the shared thread engine, used by both
--     long videos and shorts, so the UI has exactly one comment component;
--   • `playlists` incl. the reserved Watch Later list;
--   • `hashtags` / `video_hashtags` — derived by trigger, never by the client,
--     so search and trending cannot drift from the content.
--
-- Trust split is unchanged from 00019: rows here hold *metadata*. Bytes live in
-- B2 and are only reachable through `video-ticket`, which re-checks visibility
-- (00021 adds `app.video_visible`) before it signs a URL.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Categories — a real table, not a text column: the Home tab renders them as
--    chips and the operator can add one without a deploy.
-- ---------------------------------------------------------------------------
create table if not exists public.video_categories (
  id         smallint generated always as identity primary key,
  slug       text not null unique check (slug ~ '^[a-z0-9-]{2,32}$'),
  label      text not null check (char_length(label) between 1 and 40),
  emoji      text check (emoji is null or char_length(emoji) <= 8),
  position   smallint not null default 100 check (position between 0 and 9999),
  created_at timestamptz not null default clock_timestamp()
);

comment on table public.video_categories is
  'Browse chips on the Home tab. Read-only to clients; the operator seeds them.';

insert into public.video_categories (slug, label, emoji, position) values
  ('music',        'Music',        '🎵', 10),
  ('gaming',       'Gaming',       '🎮', 20),
  ('news',         'News',         '📰', 30),
  ('sports',       'Sports',       '⚽', 40),
  ('education',    'Education',    '🎓', 50),
  ('technology',   'Technology',   '💻', 60),
  ('comedy',       'Comedy',       '😂', 70),
  ('entertainment','Entertainment','🎬', 80),
  ('podcasts',     'Podcasts',     '🎙️', 90),
  ('cooking',      'Cooking',      '🍳', 100),
  ('travel',       'Travel',       '✈️', 110),
  ('fitness',      'Fitness',      '🏋️', 120),
  ('fashion',      'Fashion',      '👗', 130),
  ('science',      'Science',      '🔬', 140),
  ('art',          'Art',          '🎨', 150)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Sounds — a shared, reusable audio track (the "use this sound" loop).
--
-- A sound is either uploaded (`object_key` under `sounds/<uid>/`) or generated
-- on-device (the AI voice studio writes a local TTS render and uploads it the
-- same way). Origin is recorded so attribution can say "AI voice — Anna".
-- ---------------------------------------------------------------------------
create table if not exists public.sounds (
  id          uuid primary key default app.uuid_v7(),
  owner_id    uuid references public.profiles (id) on delete set null,
  title       text not null check (char_length(title) between 1 and 120),
  artist      text check (artist is null or char_length(artist) <= 120),
  object_key  text not null check (
    char_length(object_key) between 1 and 512
    and left(object_key, 1) <> '/'
    and position('..' in object_key) = 0
  ),
  mime        text not null default 'audio/mpeg' check (mime in ('audio/mpeg', 'audio/mp4', 'audio/wav', 'audio/ogg')),
  duration_ms integer not null check (duration_ms > 0 and duration_ms <= 3600000),
  size_bytes  integer not null check (size_bytes > 0 and size_bytes <= 52428800),
  origin      text not null default 'upload' check (origin in ('upload', 'tts', 'extracted', 'library')),
  license     text not null default 'user' check (license in ('user', 'cc0', 'cc-by', 'public-domain', 'library')),
  -- Only set for `origin = 'tts'`: the script is kept so the studio can reopen
  -- a voice-over and re-render it with a different voice.
  voice_script text check (voice_script is null or char_length(voice_script) <= 2000),
  voice_name   text check (voice_name is null or char_length(voice_name) <= 80),
  voice_locale text check (voice_locale is null or char_length(voice_locale) <= 16),
  use_count   integer not null default 0 check (use_count >= 0),
  created_at  timestamptz not null default clock_timestamp()
);

comment on table public.sounds is
  'Reusable audio: uploaded tracks and on-device AI voice-overs (origin = tts) share one row, so "use this sound" works for both.';
comment on column public.sounds.voice_script is
  'TTS source text. Stored so the voice studio can re-render, never rendered server-side (the device is the free speech engine).';

create index if not exists sounds_owner_idx on public.sounds (owner_id, created_at desc);
create index if not exists sounds_trending_idx on public.sounds (use_count desc, created_at desc);

-- ---------------------------------------------------------------------------
-- 3. videos — the long-form row.
-- ---------------------------------------------------------------------------
create table if not exists public.videos (
  id              uuid primary key default app.uuid_v7(),
  author_id       uuid not null references public.profiles (id) on delete cascade,
  category_id     smallint references public.video_categories (id) on delete set null,
  title           text not null check (char_length(title) between 1 and 200),
  description    text check (description is null or char_length(description) <= 20000),
  object_key     text not null check (
    char_length(object_key) between 1 and 512
    and left(object_key, 1) <> '/'
    and position('..' in object_key) = 0
  ),
  thumbnail_key  text check (thumbnail_key is null or (
    char_length(thumbnail_key) between 1 and 512
    and left(thumbnail_key, 1) <> '/'
    and position('..' in thumbnail_key) = 0
  )),
  mime            text not null default 'video/mp4' check (mime = 'video/mp4'),
  -- Phase 1 still ships a single MP4 quality: no transcoding ladder, no
  -- adaptive bitrate, and the docs say so instead of pretending.
  duration_ms     integer not null check (duration_ms > 0 and duration_ms <= 7200000),
  size_bytes      bigint not null check (size_bytes > 0 and size_bytes <= 2147483648),
  visibility      text not null default 'public' check (visibility in ('public', 'unlisted', 'private', 'followers')),
  language        text not null default 'en' check (char_length(language) between 2 and 16),
  tags            text[] not null default '{}'::text[],
  chapters        jsonb not null default '[]'::jsonb,
  sound_id        uuid references public.sounds (id) on delete set null,
  allow_comments  boolean not null default true,
  is_mature       boolean not null default false,
  is_removed      boolean not null default false,        -- moderation tombstone
  is_pinned       boolean not null default false,        -- creator-pinned on their channel
  like_count      integer not null default 0 check (like_count >= 0),
  dislike_count   integer not null default 0 check (dislike_count >= 0),
  comment_count   integer not null default 0 check (comment_count >= 0),
  view_count      bigint not null default 0 check (view_count >= 0),
  share_count     integer not null default 0 check (share_count >= 0),
  save_count      integer not null default 0 check (save_count >= 0),
  published_at    timestamptz not null default clock_timestamp(),
  created_at      timestamptz not null default clock_timestamp(),
  updated_at      timestamptz not null default clock_timestamp(),
  deleted_at      timestamptz,
  constraint videos_tags_shape check (array_length(tags, 1) is null or array_length(tags, 1) <= 20),
  constraint videos_chapters_shape check (
    jsonb_typeof(chapters) = 'array' and jsonb_array_length(chapters) <= 100
  )
);

comment on table public.videos is
  'Long-form videos. Bytes are a Backblaze B2 object (`object_key`); every read path goes through video-ticket, which re-checks visibility.';
comment on column public.videos.chapters is
  'Array of {"t": milliseconds, "label": text} — validated by app.validate_video_chapters() so the player can trust the shape.';

create index if not exists videos_feed_idx
  on public.videos (published_at desc, id desc)
  where deleted_at is null and is_removed = false and visibility in ('public', 'followers');
create index if not exists videos_author_idx
  on public.videos (author_id, published_at desc)
  where deleted_at is null and is_removed = false;
create index if not exists videos_category_idx
  on public.videos (category_id, published_at desc)
  where deleted_at is null and is_removed = false;
-- Trending is computed at query time in `video_feed` (see the `score` column):
-- a clock-dependent expression cannot live in an index, so hotness is a scan
-- over the recency index with an age-normalised ranking.

-- Engagement ---------------------------------------------------------------
create table if not exists public.video_likes (
  video_id   uuid not null references public.videos (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  -- YouTube's two-button version: `like` / `dislike` / absence. One row per
  -- (video, user), so switching is an UPDATE, never two counters drifting.
  verdict    text not null default 'like' check (verdict in ('like', 'dislike')),
  created_at timestamptz not null default clock_timestamp(),
  primary key (video_id, user_id)
);

create index if not exists video_likes_user_idx on public.video_likes (user_id, created_at desc);

create table if not exists public.video_views (
  id         bigint generated always as identity primary key,
  video_id   uuid not null references public.videos (id) on delete cascade,
  user_id    uuid references public.profiles (id) on delete set null,
  session_id text not null check (char_length(session_id) between 6 and 64),
  watched_ms integer not null default 0 check (watched_ms >= 0),
  position_ms integer not null default 0 check (position_ms >= 0),
  completed  boolean not null default false,
  liked_after boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);

comment on table public.video_views is
  'One row per watch session (deduplicated by video+session). Feeds view_count, the creator analytics and the recommendation signals.';

-- One row per (video, session): a refresh must not double-count a view, while a
-- genuinely later watch gets a new session id and does count.
create unique index if not exists video_views_session_key
  on public.video_views (video_id, session_id);
create index if not exists video_views_video_idx on public.video_views (video_id, created_at desc);
create index if not exists video_views_user_idx on public.video_views (user_id, created_at desc);

-- Resume + history ---------------------------------------------------------
create table if not exists public.watch_progress (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  video_id    uuid not null references public.videos (id) on delete cascade,
  position_ms integer not null default 0 check (position_ms >= 0),
  duration_ms integer not null default 0 check (duration_ms >= 0),
  completed   boolean not null default false,
  updated_at  timestamptz not null default clock_timestamp(),
  primary key (user_id, video_id)
);

create index if not exists watch_progress_recent_idx
  on public.watch_progress (user_id, updated_at desc);

-- Playlists (Watch Later is a reserved row per user, not a special case in code)
create table if not exists public.playlists (
  id          uuid primary key default app.uuid_v7(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  title       text not null check (char_length(title) between 1 and 120),
  description text check (description is null or char_length(description) <= 2000),
  visibility  text not null default 'private' check (visibility in ('public', 'unlisted', 'private')),
  cover_key   text,
  is_system   boolean not null default false,   -- Watch Later / Liked videos
  system_slug text,
  item_count  integer not null default 0 check (item_count >= 0),
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp(),
  unique (owner_id, system_slug)
);

comment on table public.playlists is
  'User playlists. `is_system` marks the two reserved lists (watch-later, liked) that are created on demand and cannot be renamed away.';

create table if not exists public.playlist_items (
  playlist_id uuid not null references public.playlists (id) on delete cascade,
  video_id    uuid not null references public.videos (id) on delete cascade,
  position    integer not null default 0,
  added_at    timestamptz not null default clock_timestamp(),
  primary key (playlist_id, video_id)
);

create index if not exists playlist_items_order_idx on public.playlist_items (playlist_id, position, added_at);

-- Comments ------------------------------------------------------------------
-- One engine for both surfaces: exactly one of (video_id, short_id) is set.
create table if not exists public.comments (
  id                uuid primary key default app.uuid_v7(),
  video_id          uuid references public.videos (id) on delete cascade,
  short_id          uuid references public.shorts (id) on delete cascade,
  author_id         uuid not null references public.profiles (id) on delete cascade,
  parent_id         uuid references public.comments (id) on delete cascade,
  body              text not null check (char_length(btrim(body)) between 1 and 4000),
  like_count        integer not null default 0 check (like_count >= 0),
  reply_count       integer not null default 0 check (reply_count >= 0),
  is_pinned         boolean not null default false,
  hearted_by_author boolean not null default false,
  is_removed        boolean not null default false,
  created_at        timestamptz not null default clock_timestamp(),
  updated_at        timestamptz not null default clock_timestamp(),
  edited_at         timestamptz,
  deleted_at        timestamptz,
  constraint comments_one_target check (
    (video_id is not null and short_id is null) or (video_id is null and short_id is not null)
  )
);

comment on table public.comments is
  'Comments for videos and shorts. `parent_id` is one level deep (YouTube-shaped): a reply to a reply is stored as a reply to the root thread.';

create index if not exists comments_video_idx
  on public.comments (video_id, is_pinned desc, created_at desc)
  where deleted_at is null;
create index if not exists comments_short_idx
  on public.comments (short_id, created_at desc)
  where deleted_at is null;
create index if not exists comments_thread_idx
  on public.comments (parent_id, created_at asc)
  where deleted_at is null;
create index if not exists comments_author_idx
  on public.comments (author_id, created_at desc);

create table if not exists public.comment_likes (
  comment_id uuid not null references public.comments (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (comment_id, user_id)
);

-- Hashtags ------------------------------------------------------------------
create table if not exists public.hashtags (
  tag        text primary key check (tag ~ '^[a-z0-9_]{2,50}$'),
  use_count  integer not null default 0 check (use_count >= 0),
  created_at timestamptz not null default clock_timestamp()
);

create table if not exists public.video_hashtags (
  video_id uuid not null references public.videos (id) on delete cascade,
  tag      text not null references public.hashtags (tag) on delete cascade,
  primary key (video_id, tag)
);

create table if not exists public.short_hashtags (
  short_id uuid not null references public.shorts (id) on delete cascade,
  tag      text not null references public.hashtags (tag) on delete cascade,
  primary key (short_id, tag)
);

create index if not exists video_hashtags_tag_idx on public.video_hashtags (tag, video_id);
create index if not exists short_hashtags_tag_idx on public.short_hashtags (tag, short_id);

-- ---------------------------------------------------------------------------
-- 3b. Notifications — the activity inbox every surface writes into.
--
-- Declared here (rather than in a late migration) because publishing a video
-- and posting a comment both notify in the same transaction; a queue that only
-- exists on paper would be worse than no queue. `payload` carries whatever the
-- row needs to render without a join (title excerpt, gift amount, …).
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default app.uuid_v7(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  kind        text not null check (kind in (
                'new_video', 'new_short', 'comment', 'reply', 'mention', 'like',
                'follow', 'follow_request', 'follow_accepted', 'gift', 'stars',
                'subscription', 'system', 'announcement', 'live', 'moderation')),
  actor_id    uuid references public.profiles (id) on delete set null,
  video_id    uuid references public.videos (id) on delete cascade,
  short_id    uuid references public.shorts (id) on delete cascade,
  comment_id  uuid references public.comments (id) on delete cascade,
  chat_id     uuid references public.chats (id) on delete cascade,
  payload     jsonb not null default '{}'::jsonb,
  read_at     timestamptz,
  created_at  timestamptz not null default clock_timestamp()
);

comment on table public.notifications is
  'Activity inbox rows (comments, follows, gifts, moderation). Written by SECURITY DEFINER triggers/RPCs so a client can never forge one.';

create index if not exists notifications_inbox_idx
  on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications (user_id, created_at desc) where read_at is null;

create or replace function public.notifications_list(p_before timestamptz default null, p_limit integer default 40)
returns table (
  id         uuid,
  kind       text,
  payload    jsonb,
  read_at    timestamptz,
  created_at timestamptz,
  actor_id   uuid,
  actor_name text,
  actor_username text,
  actor_avatar text,
  actor_verified boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select n.id, n.kind, n.payload, n.read_at, n.created_at,
         p.id,
         coalesce(nullif(btrim(p.display_name), ''), p.username),
         p.username, p.avatar_path, p.verified
    from public.notifications n
    left join public.profiles p on p.id = n.actor_id
   where n.user_id = app.current_uid()
     and (p_before is null or n.created_at < p_before)
   order by n.created_at desc
   limit least(greatest(coalesce(p_limit, 40), 1), 100);
$$;

create or replace function public.notifications_unread()
returns integer
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select count(*)::int from public.notifications n
   where n.user_id = app.current_uid() and n.read_at is null;
$$;

create or replace function public.notifications_mark_read(p_ids uuid[] default null)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.notifications n
     set read_at = clock_timestamp()
   where n.user_id = app.current_uid()
     and n.read_at is null
     and (p_ids is null or n.id = any (p_ids));
$$;

-- Shorts gain the comment counter here so the shared comment trigger has a
-- column to move; `view_count` / `share_count` arrive with the shorts upgrade.
alter table public.shorts
  add column if not exists comment_count integer not null default 0 check (comment_count >= 0);

-- ---------------------------------------------------------------------------
-- 4. Validators + maintenance triggers.
-- ---------------------------------------------------------------------------
create or replace function app.validate_video_chapters(p_chapters jsonb)
returns void
language plpgsql
immutable
as $$
declare
  v_item jsonb;
  v_last integer := -1;
begin
  if p_chapters is null or jsonb_typeof(p_chapters) <> 'array' then
    raise exception 'chapters must be a json array' using errcode = '22023';
  end if;
  for v_item in select * from jsonb_array_elements(p_chapters) loop
    if jsonb_typeof(v_item) <> 'object'
       or not (v_item ? 't') or not (v_item ? 'label')
       or jsonb_typeof(v_item -> 't') <> 'number'
       or jsonb_typeof(v_item -> 'label') <> 'string' then
      raise exception 'each chapter needs {"t": milliseconds, "label": text}'
        using errcode = '22023';
    end if;
    if (v_item ->> 't')::int <= v_last then
      raise exception 'chapters must be strictly increasing in time' using errcode = '22023';
    end if;
    if char_length(v_item ->> 'label') > 80 then
      raise exception 'a chapter label stays under 80 characters' using errcode = '22023';
    end if;
    v_last := (v_item ->> 't')::int;
  end loop;
end;
$$;

create or replace function app.videos_validate()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_tag text;
begin
  perform app.validate_video_chapters(coalesce(new.chapters, '[]'::jsonb));

  -- Tags are normalised here so `#Cooking` and `cooking` are one hashtag, and
  -- an empty tag array is never a thing.
  select coalesce(array_agg(distinct n.tag order by n.tag), '{}'::text[]) into new.tags
    from unnest(coalesce(new.tags, '{}'::text[])) as raw(val)
    cross join lateral (select lower(btrim(replace(raw.val, '#', ''))) as tag) as n
   where n.tag ~ '^[a-z0-9_]{2,50}$';

  if new.visibility = 'public' and new.thumbnail_key is null then
    -- A public row without a poster frame renders as a grey rectangle in the
    -- Home grid; the client always uploads one, and this is the server saying
    -- so instead of trusting it.
    raise exception 'a public video needs a thumbnail' using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists videos_validate on public.videos;
create trigger videos_validate
  before insert or update of tags, chapters, visibility, thumbnail_key on public.videos
  for each row execute function app.videos_validate();

drop trigger if exists videos_touch on public.videos;
create trigger videos_touch
  before update on public.videos
  for each row execute function app.set_updated_at();

-- Hashtag projection: derived from explicit tags + `#tokens` in the copy.
create or replace function app.video_hashtags_sync()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_video uuid := coalesce(new.id, old.id);
  v_tags  text[];
begin
  delete from public.video_hashtags vh where vh.video_id = v_video;

  if tg_op = 'DELETE' or new.deleted_at is not null then
    -- Counters are decremented by the `video_hashtags` delete trigger below, so
    -- nothing else is needed for a removed video.
    return coalesce(new, old);
  end if;

  select coalesce(array_agg(distinct t), '{}'::text[]) into v_tags
    from (
      select unnest(coalesce(new.tags, '{}'::text[])) as t
      union
      select lower(match[1])
        from regexp_matches(coalesce(new.title, '') || ' ' || coalesce(new.description, ''), '#([A-Za-z0-9_]{2,50})', 'g') as match
    ) s
   where t ~ '^[a-z0-9_]{2,50}$';

  insert into public.hashtags (tag) select unnest(v_tags) on conflict (tag) do nothing;
  insert into public.video_hashtags (video_id, tag)
    select v_video, unnest(v_tags)
    on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists videos_hashtags_sync on public.videos;
create trigger videos_hashtags_sync
  after insert or update of tags, title, description, deleted_at on public.videos
  for each row execute function app.video_hashtags_sync();

create or replace function app.hashtag_count_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.hashtags set use_count = use_count + 1 where tag = new.tag;
  elsif tg_op = 'DELETE' then
    update public.hashtags set use_count = greatest(use_count - 1, 0) where tag = old.tag;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists video_hashtags_recount on public.video_hashtags;
create trigger video_hashtags_recount
  after insert or delete on public.video_hashtags
  for each row execute function app.hashtag_count_recount();

-- Engagement counters -------------------------------------------------------
create or replace function app.video_likes_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    if new.verdict = 'like' then
      update public.videos set like_count = like_count + 1 where id = new.video_id;
    else
      update public.videos set dislike_count = dislike_count + 1 where id = new.video_id;
    end if;
  elsif tg_op = 'DELETE' then
    if old.verdict = 'like' then
      update public.videos set like_count = greatest(like_count - 1, 0) where id = old.video_id;
    else
      update public.videos set dislike_count = greatest(dislike_count - 1, 0) where id = old.video_id;
    end if;
  elsif tg_op = 'UPDATE' and old.verdict <> new.verdict then
    if new.verdict = 'like' then
      update public.videos
         set like_count = like_count + 1, dislike_count = greatest(dislike_count - 1, 0)
       where id = new.video_id;
    else
      update public.videos
         set dislike_count = dislike_count + 1, like_count = greatest(like_count - 1, 0)
       where id = new.video_id;
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists video_likes_recount on public.video_likes;
create trigger video_likes_recount
  after insert or update or delete on public.video_likes
  for each row execute function app.video_likes_recount();

create or replace function app.comments_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_delta int := 0;
  v_root  uuid;
begin
  if tg_op = 'INSERT' then
    -- The root thread counts replies; the surface counts root comments only
    -- (YouTube's "1.2K comments" is threads, not replies).
    if new.parent_id is not null then
      update public.comments set reply_count = reply_count + 1 where id = new.parent_id;
    else
      v_delta := 1;
    end if;
  elsif tg_op = 'DELETE' then
    if old.parent_id is not null then
      update public.comments set reply_count = greatest(reply_count - 1, 0) where id = old.parent_id;
    else
      v_delta := -1;
    end if;
  end if;

  if v_delta <> 0 then
    if coalesce(new.video_id, old.video_id) is not null then
      update public.videos
         set comment_count = greatest(comment_count + v_delta, 0)
       where id = coalesce(new.video_id, old.video_id);
    else
      update public.shorts
         set comment_count = greatest(comment_count + v_delta, 0)
       where id = coalesce(new.short_id, old.short_id);
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists comments_recount on public.comments;
create trigger comments_recount
  after insert or delete on public.comments
  for each row execute function app.comments_recount();

create or replace function app.comment_likes_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.comments set like_count = like_count + 1 where id = new.comment_id;
  elsif tg_op = 'DELETE' then
    update public.comments set like_count = greatest(like_count - 1, 0) where id = old.comment_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists comment_likes_recount on public.comment_likes;
create trigger comment_likes_recount
  after insert or delete on public.comment_likes
  for each row execute function app.comment_likes_recount();

create or replace function app.playlist_items_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.playlists set item_count = item_count + 1, updated_at = clock_timestamp()
     where id = new.playlist_id;
  elsif tg_op = 'DELETE' then
    update public.playlists set item_count = greatest(item_count - 1, 0), updated_at = clock_timestamp()
     where id = old.playlist_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists playlist_items_recount on public.playlist_items;
create trigger playlist_items_recount
  after insert or delete on public.playlist_items
  for each row execute function app.playlist_items_recount();

-- ---------------------------------------------------------------------------
-- 5. Visibility helper — video-ticket calls this before it signs a GET, and the
--    feed policies call it too, so there is one answer to "may this person
--    watch this?".
-- ---------------------------------------------------------------------------
create or replace function app.video_visible(p_video_id uuid, p_viewer uuid default null)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
      from public.videos v
     where v.id = p_video_id
       and v.deleted_at is null
       and v.is_removed = false
       and (
         v.author_id = p_viewer
         or (v.visibility = 'unlisted')
         or (v.visibility = 'public' and app.can_view_user(p_viewer, v.author_id))
         or (v.visibility = 'followers' and app.is_following(p_viewer, v.author_id))
       )
  );
$$;

comment on function app.video_visible(uuid, uuid) is
  'Single visibility gate for a video (public | unlisted | followers | private). Media tickets and feed RPCs both call it.';

-- ---------------------------------------------------------------------------
-- 6. Feed + write RPCs.
-- ---------------------------------------------------------------------------

-- The Home tab. `p_tab`:
--   for_you   → ranked public videos (engagement + freshness + affinity)
--   following → authors the caller follows
--   trending  → 48h engagement normalised by age
--   category  → filtered by slug
-- Keyset pagination on (published_at, id) via `p_before_at`/`p_before_id`, which
-- is what keeps a scrolling grid from re-reading pages.
create or replace function public.video_feed(
  p_tab        text default 'for_you',
  p_category   text default null,
  p_before_at  timestamptz default null,
  p_before_id  uuid default null,
  p_limit      integer default 24,
  p_query      text default null
)
returns table (
  id             uuid,
  title          text,
  description    text,
  thumbnail_key  text,
  duration_ms    integer,
  view_count     bigint,
  like_count     integer,
  comment_count  integer,
  published_at   timestamptz,
  visibility     text,
  is_mature      boolean,
  category_slug  text,
  category_label text,
  sound_id       uuid,
  author_id      uuid,
  author_name    text,
  author_username text,
  author_discriminator smallint,
  author_avatar  text,
  author_verified boolean,
  author_followers bigint,
  followed_by_me boolean,
  my_verdict     text,
  progress_ms    integer
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as uid), q as (
    select nullif(btrim(coalesce(p_query, '')), '') as needle
  ), base as (
    select v.*,
           case when p_tab = 'trending' then
             (coalesce(v.view_count, 0) + 30 * coalesce(v.like_count, 0) + 80 * coalesce(v.comment_count, 0))
             / greatest(extract(epoch from clock_timestamp() - v.published_at) / 3600.0, 3.0)
           else 0 end as score
      from public.videos v
     where v.deleted_at is null
       and v.is_removed = false
       and v.visibility in ('public', 'followers')
       and (v.visibility = 'public' or app.is_following((select uid from me), v.author_id))
       and app.can_view_user((select uid from me), v.author_id)
       and (
         p_category is null
         or v.category_id = (select c.id from public.video_categories c where c.slug = p_category)
       )
       and (
         (select needle from q) is null
         or v.title ilike '%' || (select needle from q) || '%'
         or coalesce(v.description, '') ilike '%' || (select needle from q) || '%'
       )
       and (
         p_tab <> 'following'
         or app.is_following((select uid from me), v.author_id)
       )
       and (
         p_before_at is null
         or (v.published_at, v.id) < (p_before_at, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
       )
  )
  select b.id,
         b.title,
         b.description,
         b.thumbnail_key,
         b.duration_ms,
         b.view_count,
         b.like_count,
         b.comment_count,
         b.published_at,
         b.visibility,
         b.is_mature,
         c.slug,
         c.label,
         b.sound_id,
         p.id,
         coalesce(nullif(btrim(p.display_name), ''), p.username),
         p.username,
         p.discriminator,
         p.avatar_path,
         p.verified,
         p.follower_count::bigint,
         case when (select uid from me) is null then false
              else app.is_following((select uid from me), p.id) end,
         (select vl.verdict from public.video_likes vl
           where vl.video_id = b.id and vl.user_id = (select uid from me)),
         (select wp.position_ms from public.watch_progress wp
           where wp.video_id = b.id and wp.user_id = (select uid from me) and not wp.completed)
    from base b
    join public.profiles p on p.id = b.author_id and p.deleted_at is null
    left join public.video_categories c on c.id = b.category_id
   order by
     case when p_tab = 'trending' then b.score end desc nulls last,
     b.published_at desc,
     b.id desc
   limit least(greatest(coalesce(p_limit, 24), 1), 60);
$$;

comment on function public.video_feed(text, text, timestamptz, uuid, integer, text) is
  'Home-tab feed: for_you | following | trending | category, keyset-paginated, already joined with author + the caller''s like/resume state.';

create or replace function public.video_detail(p_video_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_watch jsonb;
  v_video jsonb;
begin
  if not app.video_visible(p_video_id, v_uid) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;

  select to_jsonb(x) into v_video from (
    select v.id,
           v.title,
           v.description,
           v.object_key,
           v.thumbnail_key,
           v.duration_ms,
           v.size_bytes,
           v.view_count,
           v.like_count,
           v.dislike_count,
           v.comment_count,
           v.share_count,
           v.save_count,
           v.published_at,
           v.updated_at,
           v.visibility,
           v.is_mature,
           v.allow_comments,
           v.tags,
           v.chapters,
           v.sound_id,
           v.author_id,
           coalesce(nullif(btrim(p.display_name), ''), p.username) as author_name,
           p.username as author_username,
           p.discriminator as author_discriminator,
           p.avatar_path as author_avatar,
           p.verified as author_verified,
           p.follower_count::bigint as author_followers,
           p.bio as author_bio,
           (select count(*) from public.videos v2
             where v2.author_id = p.id and v2.deleted_at is null and v2.is_removed = false
               and v2.visibility = 'public')::bigint as author_video_count,
           c.slug as category_slug,
           c.label as category_label,
           case when v_uid is null then false else app.is_following(v_uid, p.id) end as followed_by_me,
           (select vl.verdict from public.video_likes vl where vl.video_id = v.id and vl.user_id = v_uid) as my_verdict,
           exists (select 1 from public.watch_progress wp where wp.video_id = v.id and wp.user_id = v_uid) as in_history
      from public.videos v
      join public.profiles p on p.id = v.author_id
      left join public.video_categories c on c.id = v.category_id
     where v.id = p_video_id
  ) x;

  if v_uid is not null then
    select to_jsonb(w) into v_watch
      from (
        select position_ms, duration_ms, completed, updated_at
          from public.watch_progress wp
         where wp.video_id = p_video_id and wp.user_id = v_uid
      ) w;
  end if;

  return jsonb_build_object(
    'video', v_video,
    'watch', coalesce(v_watch, 'null'::jsonb),
    'sound', (
      select to_jsonb(s) from (
        select so.id, so.title, so.artist, so.origin, so.voice_name, so.voice_locale, so.duration_ms
          from public.videos v join public.sounds so on so.id = v.sound_id
         where v.id = p_video_id
      ) s
    ),
    'up_next'::text, (
      -- The rail beside the player: same author first, then the same category.
      select coalesce(jsonb_agg(n order by n.published_at desc), '[]'::jsonb)
        from (
          select nv.id, nv.title, nv.thumbnail_key, nv.duration_ms, nv.view_count,
                 nv.published_at, npa.username as author_username,
                 coalesce(nullif(btrim(npa.display_name), ''), npa.username) as author_name,
                 npa.avatar_path as author_avatar
            from public.videos nv
            join public.profiles npa on npa.id = nv.author_id
            join public.videos cur on cur.id = p_video_id
           where nv.id <> p_video_id
             and nv.deleted_at is null
             and nv.is_removed = false
             and nv.visibility = 'public'
             and app.can_view_user(v_uid, nv.author_id)
             and (nv.author_id = cur.author_id or nv.category_id = cur.category_id)
           order by nv.published_at desc
           limit 12
        ) n
    )
  );
end;
$$;

comment on function public.video_detail(uuid) is
  'Everything the watch page needs in one round trip: the row, the caller''s resume state, the sound, and an up-next rail.';

-- Publish. Called after `video-ticket confirm` proved the real size/duration.
create or replace function public.publish_video(
  p_object_key     text,
  p_thumbnail_key  text,
  p_title          text,
  p_description    text default null,
  p_duration_ms    integer default null,
  p_size_bytes     bigint default null,
  p_visibility     text default 'public',
  p_category       text default null,
  p_tags           text[] default '{}'::text[],
  p_chapters       jsonb default '[]'::jsonb,
  p_sound_id       uuid default null,
  p_allow_comments boolean default true,
  p_is_mature      boolean default false,
  p_language       text default 'en'
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_id      uuid;
  v_cat     smallint;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'this account may not publish yet' using errcode = '42501';
  end if;
  if not app.sender_may_post(v_uid) then
    raise exception 'this account is restricted' using errcode = '42501';
  end if;
  -- The key must belong to the caller: a ticket mints `video/<uid>/…`, so a key
  -- that does not start with the author's folder is either a mistake or an
  -- attempt to publish somebody else's object.
  if p_object_key is null or p_object_key not like 'video/' || v_uid::text || '/%' then
    raise exception 'the video key does not belong to this account' using errcode = '42501';
  end if;
  if p_thumbnail_key is not null and p_thumbnail_key not like 'thumb/' || v_uid::text || '/%' then
    raise exception 'the thumbnail key does not belong to this account' using errcode = '42501';
  end if;
  if p_duration_ms is null or p_duration_ms <= 0 then
    raise exception 'a video needs a verified duration' using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes <= 0 then
    raise exception 'a video needs a verified size' using errcode = '22023';
  end if;

  if p_category is not null then
    select id into v_cat from public.video_categories c where c.slug = p_category;
    if v_cat is null then
      raise exception 'unknown category %', p_category using errcode = '22023';
    end if;
  end if;

  insert into public.videos (
    author_id, category_id, title, description, object_key, thumbnail_key,
    duration_ms, size_bytes, visibility, tags, chapters, sound_id,
    allow_comments, is_mature, language
  ) values (
    v_uid, v_cat, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''),
    p_object_key, p_thumbnail_key, p_duration_ms, p_size_bytes,
    coalesce(p_visibility, 'public'), coalesce(p_tags, '{}'::text[]),
    coalesce(p_chapters, '[]'::jsonb), p_sound_id,
    coalesce(p_allow_comments, true), coalesce(p_is_mature, false),
    coalesce(nullif(btrim(p_language), ''), 'en')
  )
  returning id into v_id;

  -- Post counter for the creator profile.
  update public.profiles set post_count = post_count + 1, updated_at = clock_timestamp()
   where id = v_uid;

  -- A new upload notifies the author's subscribers (bounded, one row each).
  insert into public.notifications (user_id, kind, actor_id, video_id, payload)
  select f.follower_id, 'new_video', v_uid, v_id,
         jsonb_build_object('title', btrim(p_title))
    from public.follows f
   where f.followee_id = v_uid
     and f.state = 'accepted'
     and f.notify_level <> 'none';

  return v_id;
end;
$$;

create or replace function public.update_video(
  p_video_id       uuid,
  p_title          text default null,
  p_description    text default null,
  p_visibility     text default null,
  p_category       text default null,
  p_tags           text[] default null,
  p_chapters       jsonb default null,
  p_allow_comments boolean default null,
  p_thumbnail_key  text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_cat smallint;
begin
  if not exists (select 1 from public.videos v where v.id = p_video_id and v.author_id = v_uid) then
    raise exception 'only the author may edit this video' using errcode = '42501';
  end if;
  if p_category is not null then
    select id into v_cat from public.video_categories c where c.slug = p_category;
  end if;

  update public.videos v set
    title          = coalesce(nullif(btrim(p_title), ''), v.title),
    description    = case when p_description is null then v.description else nullif(btrim(p_description), '') end,
    visibility     = coalesce(p_visibility, v.visibility),
    category_id    = coalesce(v_cat, v.category_id),
    tags           = coalesce(p_tags, v.tags),
    chapters       = coalesce(p_chapters, v.chapters),
    allow_comments = coalesce(p_allow_comments, v.allow_comments),
    thumbnail_key  = coalesce(p_thumbnail_key, v.thumbnail_key)
   where v.id = p_video_id;
end;
$$;

create or replace function public.delete_video(p_video_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  update public.videos v
     set deleted_at = clock_timestamp(), updated_at = clock_timestamp()
   where v.id = p_video_id
     and (v.author_id = v_uid or app.caller_is_service_role());
  if not found then
    raise exception 'only the author may delete this video' using errcode = '42501';
  end if;
  update public.profiles set post_count = greatest(post_count - 1, 0)
   where id = v_uid and post_count > 0;
end;
$$;

-- Like / dislike: one call, idempotent, no client-side counter arithmetic.
create or replace function public.rate_video(p_video_id uuid, p_verdict text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_verdict not in ('like', 'dislike', 'none') then
    raise exception 'verdict must be like | dislike | none' using errcode = '22023';
  end if;
  if not app.video_visible(p_video_id, v_uid) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;

  if p_verdict = 'none' then
    delete from public.video_likes vl where vl.video_id = p_video_id and vl.user_id = v_uid;
    return 'none';
  end if;

  insert into public.video_likes (video_id, user_id, verdict)
  values (p_video_id, v_uid, p_verdict)
  on conflict (video_id, user_id) do update set verdict = excluded.verdict;
  return p_verdict;
end;
$$;

-- A watch session. Deduplicated on (video, session): a refresh does not double
-- count, but a real second watch later does (a new session id).
create or replace function public.record_video_view(
  p_video_id   uuid,
  p_session_id text,
  p_watched_ms integer default 0,
  p_position_ms integer default 0,
  p_completed  boolean default false,
  p_liked_after boolean default false
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_new_id  uuid;
begin
  if p_session_id is null or char_length(p_session_id) < 6 then
    raise exception 'a view needs a session id' using errcode = '22023';
  end if;
  if not app.video_visible(p_video_id, v_uid) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;

  -- `returning` is the only reliable insert-vs-conflict signal: the `xmax = 0`
  -- trick reports "inserted" for rows this same transaction already touched,
  -- which double-counted replays of the same session.
  insert into public.video_views (video_id, user_id, session_id, watched_ms, position_ms, completed, liked_after)
  values (p_video_id, v_uid, p_session_id, greatest(coalesce(p_watched_ms, 0), 0),
          greatest(coalesce(p_position_ms, 0), 0), coalesce(p_completed, false), coalesce(p_liked_after, false))
  on conflict (video_id, session_id) do nothing
  returning video_id into v_new_id;

  if v_new_id is not null then
    update public.videos set view_count = view_count + 1 where id = p_video_id;
  end if;

  if v_uid is not null then
    insert into public.watch_progress (user_id, video_id, position_ms, duration_ms, completed)
    select v_uid, p_video_id, greatest(coalesce(p_position_ms, 0), 0), v.duration_ms, coalesce(p_completed, false)
      from public.videos v where v.id = p_video_id
    on conflict (user_id, video_id) do update
      -- Furthest progress wins: a late flush from an old session (or a
      -- backgrounded player) must not rewind where the person actually got to.
      set position_ms = greatest(public.watch_progress.position_ms, coalesce(excluded.position_ms, 0)),
          duration_ms = excluded.duration_ms,
          completed   = public.watch_progress.completed or excluded.completed,
          updated_at  = clock_timestamp();
  end if;
end;
$$;

create or replace function public.video_share(p_video_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not app.video_visible(p_video_id, app.current_uid()) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;
  update public.videos set share_count = share_count + 1 where id = p_video_id;
end;
$$;

-- Watch Later / Liked are system playlists created on demand.
create or replace function app.system_playlist(p_user uuid, p_slug text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
  v_title text;
begin
  if p_slug not in ('watch-later', 'liked') then
    raise exception 'unknown system playlist %', p_slug using errcode = '22023';
  end if;
  v_title := case p_slug when 'watch-later' then 'Watch later' else 'Liked videos' end;

  select pl.id into v_id from public.playlists pl
   where pl.owner_id = p_user and pl.system_slug = p_slug;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.playlists (owner_id, title, visibility, is_system, system_slug)
  values (p_user, v_title, 'private', true, p_slug)
  on conflict (owner_id, system_slug) do update set title = excluded.title
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.toggle_watch_later(p_video_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_pid uuid;
  v_present boolean;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.video_visible(p_video_id, v_uid) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;
  v_pid := app.system_playlist(v_uid, 'watch-later');

  select exists (select 1 from public.playlist_items pi
                  where pi.playlist_id = v_pid and pi.video_id = p_video_id) into v_present;

  if v_present then
    delete from public.playlist_items pi where pi.playlist_id = v_pid and pi.video_id = p_video_id;
    update public.videos set save_count = greatest(save_count - 1, 0) where id = p_video_id;
    return false;
  end if;

  insert into public.playlist_items (playlist_id, video_id, position)
  values (v_pid, p_video_id, coalesce((select max(pi.position) + 1 from public.playlist_items pi where pi.playlist_id = v_pid), 0));
  update public.videos set save_count = save_count + 1 where id = p_video_id;
  return true;
end;
$$;

create or replace function public.my_playlists()
returns table (
  id         uuid,
  title      text,
  visibility text,
  is_system  boolean,
  system_slug text,
  item_count integer,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select pl.id, pl.title, pl.visibility, pl.is_system, pl.system_slug, pl.item_count, pl.updated_at
    from public.playlists pl
   where pl.owner_id = app.current_uid()
   order by pl.is_system desc, pl.updated_at desc;
$$;

create or replace function public.watch_history(p_limit integer default 50)
returns table (
  video_id      uuid,
  title         text,
  thumbnail_key text,
  duration_ms   integer,
  position_ms   integer,
  completed     boolean,
  watched_at    timestamptz,
  author_username text,
  author_name   text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select v.id, v.title, v.thumbnail_key, v.duration_ms, wp.position_ms, wp.completed, wp.updated_at,
         p.username, coalesce(nullif(btrim(p.display_name), ''), p.username)
    from public.watch_progress wp
    join public.videos v on v.id = wp.video_id and v.deleted_at is null
    join public.profiles p on p.id = v.author_id
   where wp.user_id = app.current_uid()
   order by wp.updated_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

create or replace function public.clear_watch_history()
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  delete from public.watch_progress wp where wp.user_id = app.current_uid();
$$;

-- ---------------------------------------------------------------------------
-- 7. Comment RPCs (shared by videos and shorts).
-- ---------------------------------------------------------------------------
create or replace function public.comment_thread(
  p_video_id  uuid default null,
  p_short_id  uuid default null,
  p_parent_id uuid default null,
  p_before_at timestamptz default null,
  p_limit     integer default 20,
  p_sort      text default 'top'
)
returns table (
  id                uuid,
  parent_id         uuid,
  body              text,
  like_count        integer,
  reply_count       integer,
  is_pinned         boolean,
  hearted_by_author boolean,
  created_at        timestamptz,
  edited_at         timestamptz,
  author_id         uuid,
  author_name       text,
  author_username   text,
  author_avatar     text,
  author_verified   boolean,
  liked_by_me       boolean,
  is_mine           boolean,
  can_reply         boolean
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if (p_video_id is null) = (p_short_id is null) then
    raise exception 'a comment thread needs exactly one target' using errcode = '22023';
  end if;
  if p_video_id is not null and not app.video_visible(p_video_id, v_uid) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;

  return query
  select c.id,
         c.parent_id,
         c.body,
         c.like_count,
         c.reply_count,
         c.is_pinned,
         c.hearted_by_author,
         c.created_at,
         c.edited_at,
         p.id,
         coalesce(nullif(btrim(p.display_name), ''), p.username),
         p.username,
         p.avatar_path,
         p.verified,
         exists (select 1 from public.comment_likes cl where cl.comment_id = c.id and cl.user_id = v_uid),
         c.author_id = v_uid,
         case
           when c.video_id is not null then coalesce((select v.allow_comments from public.videos v where v.id = c.video_id), true)
           else true
         end
    from public.comments c
    join public.profiles p on p.id = c.author_id
   where c.deleted_at is null
     and c.is_removed = false
     and app.can_view_user(v_uid, c.author_id)
     and case
           when p_parent_id is null then
             c.parent_id is null
             and ((p_video_id is not null and c.video_id = p_video_id)
                  or (p_short_id is not null and c.short_id = p_short_id))
             and (p_before_at is null or c.created_at < p_before_at)
           else
             c.parent_id = p_parent_id
         end
   order by
     case when p_parent_id is null and p_sort = 'top' then c.is_pinned end desc nulls last,
     case when p_parent_id is null and p_sort = 'top' then c.like_count end desc nulls last,
     case when p_parent_id is null and p_sort = 'new' then c.created_at end desc nulls last,
     c.created_at desc
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
end;
$$;

create or replace function public.comment_create(
  p_body     text,
  p_video_id uuid default null,
  p_short_id uuid default null,
  p_parent_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_id    uuid;
  v_root  uuid;
  v_owner uuid;
  v_allow boolean := true;
  v_parent public.comments%rowtype;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'this account may not comment yet' using errcode = '42501';
  end if;
  if (p_video_id is null) = (p_short_id is null) then
    raise exception 'a comment needs exactly one target' using errcode = '22023';
  end if;

  if p_video_id is not null then
    if not app.video_visible(p_video_id, v_uid) then
      raise exception 'that video is not available' using errcode = '42501';
    end if;
    select v.allow_comments, v.author_id into v_allow, v_owner from public.videos v where v.id = p_video_id;
  else
    select true, s.author_id into v_allow, v_owner from public.shorts s where s.id = p_short_id;
  end if;

  if not coalesce(v_allow, true) then
    raise exception 'comments are turned off for this video' using errcode = '42501';
  end if;

  if p_parent_id is not null then
    select * into v_parent from public.comments c where c.id = p_parent_id and c.deleted_at is null;
    if not found then
      raise exception 'that comment no longer exists' using errcode = '22023';
    end if;
    -- YouTube-shaped nesting: replying to a reply attaches to the root thread,
    -- so the thread never grows past one visible level.
    v_root := coalesce(v_parent.parent_id, v_parent.id);
  end if;

  insert into public.comments (video_id, short_id, author_id, parent_id, body)
  values (p_video_id, p_short_id, v_uid, v_root, btrim(p_body))
  returning id into v_id;

  -- Notify the creator (and the parent commenter on a reply), never yourself.
  if v_owner is not null and v_owner <> v_uid then
    insert into public.notifications (user_id, kind, actor_id, video_id, short_id, comment_id, payload)
    values (v_owner,
            case when p_parent_id is null then 'comment' else 'reply' end,
            v_uid, p_video_id, p_short_id, v_id,
            jsonb_build_object('excerpt', left(btrim(p_body), 140)));
  end if;
  if p_parent_id is not null and v_parent.author_id <> v_uid and v_parent.author_id <> v_owner then
    insert into public.notifications (user_id, kind, actor_id, video_id, short_id, comment_id, payload)
    values (v_parent.author_id, 'reply', v_uid, p_video_id, p_short_id, v_id,
            jsonb_build_object('excerpt', left(btrim(p_body), 140)));
  end if;

  return v_id;
end;
$$;

create or replace function public.comment_update(p_comment_id uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  update public.comments c
     set body = btrim(p_body), edited_at = clock_timestamp(), updated_at = clock_timestamp()
   where c.id = p_comment_id and c.author_id = v_uid and c.deleted_at is null;
  if not found then
    raise exception 'only the author may edit this comment' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.comment_delete(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_author uuid;
  v_video  uuid;
  v_short  uuid;
begin
  select c.author_id, c.video_id, c.short_id into v_author, v_video, v_short
    from public.comments c where c.id = p_comment_id and c.deleted_at is null;
  if v_author is null then
    return;
  end if;
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  -- Three roles may remove a comment: its author (real delete), the creator of
  -- the surface it sits on (tombstone), or the service role (moderation).
  if v_author <> v_uid and not app.caller_is_service_role() then
    if not (
      (v_video is not null and exists (select 1 from public.videos v where v.id = v_video and v.author_id = v_uid))
      or (v_short is not null and exists (select 1 from public.shorts s where s.id = v_short and s.author_id = v_uid))
    ) then
      raise exception 'not allowed to delete this comment' using errcode = '42501';
    end if;
  end if;

  if v_author = v_uid then
    -- The author's own delete is a real delete: the row stops counting.
    delete from public.comments c where c.id = p_comment_id;
  else
    -- A moderator's delete tombstones ("removed by the creator") and keeps the
    -- thread's reply structure intact.
    update public.comments c
       set is_removed = true, body = '[removed]', updated_at = clock_timestamp()
     where c.id = p_comment_id;
  end if;
end;
$$;

create or replace function public.comment_like(p_comment_id uuid, p_like boolean default true)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_like then
    insert into public.comment_likes (comment_id, user_id) values (p_comment_id, v_uid)
    on conflict do nothing;
  else
    delete from public.comment_likes cl where cl.comment_id = p_comment_id and cl.user_id = v_uid;
  end if;
  select c.like_count into v_count from public.comments c where c.id = p_comment_id;
  return coalesce(v_count, 0);
end;
$$;

create or replace function public.comment_pin(p_comment_id uuid, p_pinned boolean default true)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_video uuid;
  v_short uuid;
  v_owner uuid;
begin
  select c.video_id, c.short_id into v_video, v_short from public.comments c where c.id = p_comment_id;
  if v_video is not null then
    select v.author_id into v_owner from public.videos v where v.id = v_video;
  elsif v_short is not null then
    select s.author_id into v_owner from public.shorts s where s.id = v_short;
  end if;
  if v_owner is null or (v_owner <> v_uid and not app.caller_is_service_role()) then
    raise exception 'only the creator may pin a comment' using errcode = '42501';
  end if;

  if p_pinned then
    -- One pinned comment per surface, which is the rule YouTube enforces too.
    update public.comments c set is_pinned = false
     where (c.video_id = v_video or c.short_id = v_short) and c.is_pinned;
  end if;
  update public.comments c set is_pinned = p_pinned where c.id = p_comment_id;
end;
$$;

create or replace function public.comment_heart(p_comment_id uuid, p_hearted boolean default true)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_video uuid;
  v_short uuid;
  v_owner uuid;
begin
  select c.video_id, c.short_id into v_video, v_short from public.comments c where c.id = p_comment_id;
  if v_video is not null then
    select v.author_id into v_owner from public.videos v where v.id = v_video;
  elsif v_short is not null then
    select s.author_id into v_owner from public.shorts s where s.id = v_short;
  end if;
  if v_owner is null or (v_owner <> v_uid and not app.caller_is_service_role()) then
    raise exception 'only the creator may heart a comment' using errcode = '42501';
  end if;
  update public.comments c set hearted_by_author = p_hearted where c.id = p_comment_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. RLS + grants.
-- ---------------------------------------------------------------------------
alter table public.video_categories enable row level security;
alter table public.sounds           enable row level security;
alter table public.videos           enable row level security;
alter table public.video_likes      enable row level security;
alter table public.video_views      enable row level security;
alter table public.watch_progress   enable row level security;
alter table public.playlists        enable row level security;
alter table public.playlist_items   enable row level security;
alter table public.comments         enable row level security;
alter table public.comment_likes    enable row level security;
alter table public.hashtags         enable row level security;
alter table public.video_hashtags   enable row level security;
alter table public.short_hashtags   enable row level security;

drop policy if exists video_categories_read on public.video_categories;
create policy video_categories_read on public.video_categories
  for select to authenticated, anon using (true);

-- Sounds are shared by design: using somebody's track is the feature.
drop policy if exists sounds_read on public.sounds;
create policy sounds_read on public.sounds
  for select to authenticated using (true);

drop policy if exists sounds_insert_own on public.sounds;
create policy sounds_insert_own on public.sounds
  for insert to authenticated
  with check (owner_id = (select app.current_uid()) and app.access_ok((select app.current_uid())));

drop policy if exists sounds_delete_own on public.sounds;
create policy sounds_delete_own on public.sounds
  for delete to authenticated
  using (owner_id = (select app.current_uid()));

drop policy if exists videos_read_visible on public.videos;
create policy videos_read_visible on public.videos
  for select to authenticated
  using (
    deleted_at is null
    and (
      author_id = (select app.current_uid())
      or (
        is_removed = false
        and case visibility
              when 'public'    then app.can_view_user((select app.current_uid()), author_id)
              when 'followers' then app.is_following((select app.current_uid()), author_id)
              when 'unlisted'  then true
              else false
            end
      )
    )
  );

-- Writes only through publish_video / update_video / delete_video: every one of
-- them re-derives the author, validates the verified numbers and keeps the
-- counters server-side.
drop policy if exists videos_update_own on public.videos;
create policy videos_update_own on public.videos
  for update to authenticated
  using (author_id = (select app.current_uid()));

drop policy if exists video_likes_read_own on public.video_likes;
create policy video_likes_read_own on public.video_likes
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists video_likes_write_own on public.video_likes;
create policy video_likes_write_own on public.video_likes
  for insert to authenticated
  with check (user_id = (select app.current_uid()));
drop policy if exists video_likes_delete_own on public.video_likes;
create policy video_likes_delete_own on public.video_likes
  for delete to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists watch_progress_own on public.watch_progress;
create policy watch_progress_own on public.watch_progress
  for all to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

drop policy if exists video_views_own on public.video_views;
create policy video_views_own on public.video_views
  for insert to authenticated
  with check (user_id = (select app.current_uid()));
drop policy if exists video_views_read_own on public.video_views;
create policy video_views_read_own on public.video_views
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists playlists_read on public.playlists;
create policy playlists_read on public.playlists
  for select to authenticated
  using (owner_id = (select app.current_uid()) or visibility = 'public');
drop policy if exists playlists_write_own on public.playlists;
create policy playlists_write_own on public.playlists
  for insert to authenticated
  with check (owner_id = (select app.current_uid()) and not is_system);
drop policy if exists playlists_update_own on public.playlists;
create policy playlists_update_own on public.playlists
  for update to authenticated
  using (owner_id = (select app.current_uid()) and not is_system);
drop policy if exists playlists_delete_own on public.playlists;
create policy playlists_delete_own on public.playlists
  for delete to authenticated
  using (owner_id = (select app.current_uid()) and not is_system);

drop policy if exists playlist_items_read on public.playlist_items;
create policy playlist_items_read on public.playlist_items
  for select to authenticated
  using (exists (
    select 1 from public.playlists pl
     where pl.id = public.playlist_items.playlist_id
       and (pl.owner_id = (select app.current_uid()) or pl.visibility = 'public')
  ));
drop policy if exists playlist_items_write_own on public.playlist_items;
create policy playlist_items_write_own on public.playlist_items
  for insert to authenticated
  with check (exists (
    select 1 from public.playlists pl
     where pl.id = public.playlist_items.playlist_id
       and pl.owner_id = (select app.current_uid())
  ));
drop policy if exists playlist_items_delete_own on public.playlist_items;
create policy playlist_items_delete_own on public.playlist_items
  for delete to authenticated
  using (exists (
    select 1 from public.playlists pl
     where pl.id = public.playlist_items.playlist_id
       and pl.owner_id = (select app.current_uid())
  ));

drop policy if exists comments_read_visible on public.comments;
create policy comments_read_visible on public.comments
  for select to authenticated
  using (deleted_at is null and app.can_view_user((select app.current_uid()), author_id));

drop policy if exists comment_likes_read_own on public.comment_likes;
create policy comment_likes_read_own on public.comment_likes
  for select to authenticated
  using (user_id = (select app.current_uid()));
drop policy if exists comment_likes_write_own on public.comment_likes;
create policy comment_likes_write_own on public.comment_likes
  for insert to authenticated
  with check (user_id = (select app.current_uid()));
drop policy if exists comment_likes_delete_own on public.comment_likes;
create policy comment_likes_delete_own on public.comment_likes
  for delete to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists hashtags_read on public.hashtags;
create policy hashtags_read on public.hashtags for select to authenticated using (true);
drop policy if exists video_hashtags_read on public.video_hashtags;
create policy video_hashtags_read on public.video_hashtags for select to authenticated using (true);
drop policy if exists short_hashtags_read on public.short_hashtags;
create policy short_hashtags_read on public.short_hashtags for select to authenticated using (true);

grant select on public.video_categories to anon, authenticated;
grant select, insert, delete on public.sounds to authenticated;
grant select on public.videos to authenticated;
-- Column-level UPDATE: the author may edit the copy, never the counters.
grant update (title, description, visibility, category_id, tags, chapters,
              thumbnail_key, allow_comments, is_mature, sound_id)
  on public.videos to authenticated;
grant select on public.video_likes to authenticated;
grant select on public.video_views to authenticated;
grant select, insert, update on public.watch_progress to authenticated;
grant select, insert, update, delete on public.playlists to authenticated;
grant select, insert, delete on public.playlist_items to authenticated;
grant select on public.comments to authenticated;
grant select on public.comment_likes to authenticated;
grant select on public.hashtags, public.video_hashtags, public.short_hashtags to authenticated;
revoke all on public.videos, public.video_likes, public.comments, public.comment_likes,
              public.video_views, public.watch_progress, public.playlists, public.playlist_items
  from anon;

alter table public.notifications enable row level security;

drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists notifications_mark_read on public.notifications;
create policy notifications_mark_read on public.notifications
  for update to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

grant select, update on public.notifications to authenticated;
revoke all on public.notifications from anon;

grant execute on function
  public.notifications_list(timestamptz, integer),
  public.notifications_unread(),
  public.notifications_mark_read(uuid[])
to authenticated;

grant execute on function
  public.video_feed(text, text, timestamptz, uuid, integer, text),
  public.video_detail(uuid),
  public.publish_video(text, text, text, text, integer, bigint, text, text, text[], jsonb, uuid, boolean, boolean, text),
  public.update_video(uuid, text, text, text, text, text[], jsonb, boolean, text),
  public.delete_video(uuid),
  public.rate_video(uuid, text),
  public.record_video_view(uuid, text, integer, integer, boolean, boolean),
  public.video_share(uuid),
  public.toggle_watch_later(uuid),
  public.my_playlists(),
  public.watch_history(integer),
  public.clear_watch_history(),
  public.comment_thread(uuid, uuid, uuid, timestamptz, integer, text),
  public.comment_create(text, uuid, uuid, uuid),
  public.comment_update(uuid, text),
  public.comment_delete(uuid),
  public.comment_like(uuid, boolean),
  public.comment_pin(uuid, boolean),
  public.comment_heart(uuid, boolean)
to authenticated;

commit;
