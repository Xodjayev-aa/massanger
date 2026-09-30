-- =============================================================================
-- 00021_social_and_longform.sql
-- MessengerX Super-App — the social graph, long-form video, one comment system
-- for both video surfaces, honest view counting and the read paths the three
-- tabs use (Home feed, Reels feed, global search).
--
-- Two content tables by design, not by accident:
--   * `shorts`  — vertical, ≤ 60 s, the Reels tab (phase 1, unchanged shape);
--   * `videos`  — long-form, up to 4 h, the Home tab.
-- Everything the two *share* (comments, views, likes, tips, notifications,
-- search) is one table keyed by `(subject_kind, subject_id)`, so a comment
-- written on a Reel and a comment written on a video go through exactly the
-- same code, policies and counters.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Follows — the entire difference between "For you" and "Following".
-- ---------------------------------------------------------------------------
create table if not exists public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default clock_timestamp(),
  primary key (follower_id, followee_id),
  constraint follows_not_self check (follower_id <> followee_id)
);

comment on table public.follows is
  'Directed follow edges. A follower may always read their own rows; the counts everyone sees come from profile_stats(), never from a public COUNT(*).';

create index if not exists follows_followee_idx on public.follows (followee_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 2. Long-form video.
--
-- Caps: 4 h / 2 GiB in the database as the outer bound; the `video-ticket`
-- function enforces the deployment's real limits before minting a URL, and
-- `shorts` keeps its own 60 s / 250 MB contract untouched.
-- ---------------------------------------------------------------------------
create table if not exists public.videos (
  id            uuid primary key default app.uuid_v7(),
  author_id     uuid not null references public.profiles (id) on delete cascade,
  object_key    text not null unique check (
    char_length(object_key) between 1 and 512
    and left(object_key, 1) <> '/'
    and position('..' in object_key) = 0
  ),
  -- Poster frame, same B2 bucket, `thumbs/` key space. Optional: the grid
  -- renders the first video frame when there is none.
  thumbnail_key text check (
    thumbnail_key is null or (
      char_length(thumbnail_key) between 1 and 512
      and left(thumbnail_key, 1) <> '/'
      and position('..' in thumbnail_key) = 0
    )
  ),
  mime          text not null default 'video/mp4' check (mime = 'video/mp4'),
  title         text not null check (char_length(btrim(title)) between 1 and 120),
  description   text check (description is null or char_length(description) <= 5000),
  duration_ms   integer not null check (duration_ms > 0 and duration_ms <= 14400000),
  size_bytes    bigint not null check (size_bytes > 0 and size_bytes <= 2147483648),
  -- `unlisted` is the YouTube "anyone with the link" state: readable by anyone
  -- signed in who has the id, absent from every feed and from search.
  visibility    text not null default 'public' check (visibility in ('public', 'unlisted')),
  chapters      jsonb not null default '[]'::jsonb check (jsonb_typeof(chapters) = 'array'),
  view_count    bigint not null default 0 check (view_count >= 0),
  like_count    integer not null default 0 check (like_count >= 0),
  comment_count integer not null default 0 check (comment_count >= 0),
  tip_stars     bigint not null default 0 check (tip_stars >= 0),
  published_at  timestamptz not null default clock_timestamp(),
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp(),
  deleted_at    timestamptz,
  search_tsv    tsvector
);

comment on table public.videos is
  'Long-form content (Home tab). Bytes live in Backblaze B2 under videos/<uid>/…; counters are trigger-maintained and never client-writable.';

create index if not exists videos_author_idx on public.videos (author_id, published_at desc) where deleted_at is null;
create index if not exists videos_feed_idx on public.videos (published_at desc, id desc) where deleted_at is null and visibility = 'public';
create index if not exists videos_search_idx on public.videos using gin (search_tsv);

-- Reels get the same counters the Home tab already has, so one comment table
-- and one view table can serve both without a special case.
alter table public.shorts
  add column if not exists view_count    bigint not null default 0,
  add column if not exists comment_count integer not null default 0,
  add column if not exists tip_stars     bigint not null default 0,
  add column if not exists thumbnail_key text,
  add column if not exists search_tsv    tsvector;

alter table public.shorts drop constraint if exists shorts_counters_nonneg;
alter table public.shorts add constraint shorts_counters_nonneg
  check (view_count >= 0 and comment_count >= 0 and tip_stars >= 0);

create index if not exists shorts_search_idx on public.shorts using gin (search_tsv);

-- Keep `videos.search_tsv` and `shorts.search_tsv` in sync the same way the
-- message search does it: a trigger, because a generated column would block the
-- REPLICA IDENTITY FULL that realtime needs on a table this hot.
create or replace function app.video_search_refresh()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.search_tsv :=
    setweight(to_tsvector('simple', coalesce(new.title, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(new.description, '')), 'B');
  new.updated_at := case when tg_op = 'UPDATE' then clock_timestamp() else new.updated_at end;
  return new;
end;
$$;

drop trigger if exists videos_search_refresh on public.videos;
create trigger videos_search_refresh
  before insert or update of title, description on public.videos
  for each row execute function app.video_search_refresh();

create or replace function app.short_search_refresh()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.search_tsv := setweight(to_tsvector('simple', coalesce(new.caption, '')), 'A');
  return new;
end;
$$;

drop trigger if exists shorts_search_refresh on public.shorts;
create trigger shorts_search_refresh
  before insert or update of caption on public.shorts
  for each row execute function app.short_search_refresh();

-- Existing rows (a phase-1 deployment upgrading in place) get their vectors.
update public.videos v
   set search_tsv = setweight(to_tsvector('simple', coalesce(v.title, '')), 'A')
                  || setweight(to_tsvector('simple', coalesce(v.description, '')), 'B')
 where v.search_tsv is null;

update public.shorts s
   set search_tsv = setweight(to_tsvector('simple', coalesce(s.caption, '')), 'A')
 where s.search_tsv is null;

-- ---------------------------------------------------------------------------
-- 3. Likes on long-form video (the Reels counter already exists in 00019).
-- ---------------------------------------------------------------------------
create table if not exists public.video_likes (
  video_id   uuid not null references public.videos (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (video_id, user_id)
);

create index if not exists video_likes_user_idx on public.video_likes (user_id, video_id);

create or replace function app.video_likes_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.videos set like_count = like_count + 1 where id = new.video_id;
  elsif tg_op = 'DELETE' then
    update public.videos set like_count = greatest(like_count - 1, 0) where id = old.video_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists video_likes_recount on public.video_likes;
create trigger video_likes_recount
  after insert or delete on public.video_likes
  for each row execute function app.video_likes_recount();

-- ---------------------------------------------------------------------------
-- 4. One comment system for videos and reels.
--
-- Threading is two levels deep, exactly like YouTube and TikTok: a top-level
-- comment (root_id = null) and its replies (root_id = the top-level comment).
-- `parent_id` records who was answered, which is what the mention line renders.
-- ---------------------------------------------------------------------------
create table if not exists public.content_comments (
  id            uuid primary key default app.uuid_v7(),
  subject_kind  text not null check (subject_kind in ('video', 'short')),
  subject_id    uuid not null,
  author_id     uuid not null references public.profiles (id) on delete cascade,
  parent_id     uuid references public.content_comments (id) on delete cascade,
  root_id       uuid references public.content_comments (id) on delete cascade,
  body          text not null check (char_length(btrim(body)) between 1 and 2000),
  like_count    integer not null default 0 check (like_count >= 0),
  reply_count   integer not null default 0 check (reply_count >= 0),
  is_pinned     boolean not null default false,
  edited_at     timestamptz,
  deleted_at    timestamptz,
  created_at    timestamptz not null default clock_timestamp(),
  search_tsv    tsvector
);

comment on table public.content_comments is
  'Comments for both content kinds. A soft delete keeps a thread readable; the counters are trigger-maintained.';

create index if not exists content_comments_subject_idx
  on public.content_comments (subject_kind, subject_id, created_at desc)
  where deleted_at is null and root_id is null;

create index if not exists content_comments_root_idx
  on public.content_comments (root_id, created_at)
  where deleted_at is null;

create index if not exists content_comments_author_idx
  on public.content_comments (author_id, created_at desc);

create table if not exists public.comment_likes (
  comment_id uuid not null references public.content_comments (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (comment_id, user_id)
);

-- The subject must exist and be visible before a comment points at it: a
-- polymorphic key has no foreign key to lean on, so this trigger is the
-- integrity check (and it is the one place that knows how to look up both
-- content kinds).
create or replace function app.guard_comment_insert()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_author uuid;
  v_parent public.content_comments%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.subject_kind = 'video' then
      select v.author_id into v_author
      from public.videos v
      where v.id = new.subject_id and v.deleted_at is null;
    else
      select s.author_id into v_author
      from public.shorts s
      where s.id = new.subject_id;
    end if;

    if v_author is null then
      raise exception 'that content does not exist' using errcode = '23503';
    end if;

    if not app.access_ok(new.author_id) then
      raise exception 'this account cannot comment right now' using errcode = '42501';
    end if;

    -- Replies are flattened to one level: answering a reply attaches to the
    -- same root, so a thread never becomes a tree a phone cannot render.
    if new.parent_id is not null then
      select * into v_parent from public.content_comments c where c.id = new.parent_id;
      if not found then
        raise exception 'the comment being answered no longer exists' using errcode = '23503';
      end if;
      if v_parent.subject_kind <> new.subject_kind or v_parent.subject_id <> new.subject_id then
        raise exception 'a reply must stay on the same content' using errcode = '22023';
      end if;
      new.root_id := coalesce(v_parent.root_id, v_parent.id);
    else
      new.root_id := null;
    end if;

    new.search_tsv := to_tsvector('simple', new.body);
  end if;

  if tg_op = 'UPDATE' then
    if new.body is distinct from old.body then
      new.edited_at := clock_timestamp();
      new.search_tsv := to_tsvector('simple', new.body);
    end if;
    new.search_tsv := coalesce(new.search_tsv, old.search_tsv);
  end if;

  return new;
end;
$$;

drop trigger if exists content_comments_guard on public.content_comments;
create trigger content_comments_guard
  before insert or update on public.content_comments
  for each row execute function app.guard_comment_insert();

-- Counters: on the parent, on the root and on the content itself.
create or replace function app.after_comment_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_verb text;
begin
  if tg_op = 'INSERT' then
    if new.root_id is not null then
      update public.content_comments set reply_count = reply_count + 1 where id = new.root_id;
      if new.parent_id is distinct from new.root_id then
        update public.content_comments set reply_count = reply_count + 1 where id = new.parent_id;
      end if;
    end if;

    if new.subject_kind = 'video' then
      update public.videos set comment_count = comment_count + 1 where id = new.subject_id;
    else
      update public.shorts set comment_count = comment_count + 1 where id = new.subject_id;
    end if;

    return new;
  end if;

  if tg_op = 'UPDATE' and old.deleted_at is null and new.deleted_at is not null then
    if new.root_id is not null then
      update public.content_comments set reply_count = greatest(reply_count - 1, 0) where id = new.root_id;
      if new.parent_id is distinct from new.root_id then
        update public.content_comments set reply_count = greatest(reply_count - 1, 0) where id = new.parent_id;
      end if;
    end if;

    if new.subject_kind = 'video' then
      update public.videos set comment_count = greatest(comment_count - 1, 0) where id = new.subject_id;
    else
      update public.shorts set comment_count = greatest(comment_count - 1, 0) where id = new.subject_id;
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists content_comments_after on public.content_comments;
create trigger content_comments_after
  after insert or update on public.content_comments
  for each row execute function app.after_comment_write();

create or replace function app.comment_likes_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.content_comments set like_count = like_count + 1 where id = new.comment_id;
  elsif tg_op = 'DELETE' then
    update public.content_comments set like_count = greatest(like_count - 1, 0) where id = old.comment_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists comment_likes_recount on public.comment_likes;
create trigger comment_likes_recount
  after insert or delete on public.comment_likes
  for each row execute function app.comment_likes_recount();

-- ---------------------------------------------------------------------------
-- 5. Views. One row per viewer per content per day; the counter is a trigger on
-- that row, so a refresh cannot inflate a number and a creator can see a real
-- daily curve in creator_stats().
-- ---------------------------------------------------------------------------
create table if not exists public.content_views (
  subject_kind text not null check (subject_kind in ('video', 'short')),
  subject_id   uuid not null,
  viewer_id    uuid not null references public.profiles (id) on delete cascade,
  view_day     date not null default ((now() at time zone 'utc')::date),
  watched_ms   integer not null default 0 check (watched_ms >= 0),
  updated_at   timestamptz not null default clock_timestamp(),
  primary key (subject_kind, subject_id, viewer_id, view_day)
);

comment on table public.content_views is
  'Daily unique views. register_view() is the only writer; the author is never counted viewing their own content.';

create index if not exists content_views_subject_idx on public.content_views (subject_kind, subject_id, view_day desc);
create index if not exists content_views_viewer_idx on public.content_views (viewer_id, view_day desc);

create or replace function public.register_view(
  p_subject_kind text,
  p_subject_id   uuid,
  p_watched_ms   integer default 0
)
returns table (counted boolean, total_views bigint)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_author  uuid;
  v_today   date := (now() at time zone 'utc')::date;
  v_new     boolean := false;
  v_total   bigint;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_subject_kind not in ('video', 'short') then
    raise exception 'unknown content kind' using errcode = '22023';
  end if;

  if p_subject_kind = 'video' then
    select v.author_id, v.view_count into v_author, v_total
    from public.videos v where v.id = p_subject_id and v.deleted_at is null;
  else
    select s.author_id, s.view_count into v_author, v_total
    from public.shorts s where s.id = p_subject_id;
  end if;

  if v_author is null then
    raise exception 'that content does not exist' using errcode = '23503';
  end if;

  -- The author watching their own video is not a view; that is how the number
  -- stays meaningful for a creator checking their own work.
  if v_author = v_uid then
    return query select false, v_total;
    return;
  end if;

  insert into public.content_views (subject_kind, subject_id, viewer_id, view_day, watched_ms)
  values (p_subject_kind, p_subject_id, v_uid, v_today, greatest(coalesce(p_watched_ms, 0), 0))
  on conflict (subject_kind, subject_id, viewer_id, view_day)
  do update set watched_ms = greatest(public.content_views.watched_ms, excluded.watched_ms),
                updated_at = clock_timestamp()
  returning (xmax = 0) into v_new;

  if v_new then
    if p_subject_kind = 'video' then
      update public.videos set view_count = view_count + 1 where id = p_subject_id
        returning view_count into v_total;
    else
      update public.shorts set view_count = view_count + 1 where id = p_subject_id
        returning view_count into v_total;
    end if;
  end if;

  return query select v_new, v_total;
end;
$$;

comment on function public.register_view(text, uuid, integer) is
  'Counts one view per viewer per content per UTC day and returns the running total. Returns counted=false for the author.';

-- ---------------------------------------------------------------------------
-- 6. Follow / unfollow.
-- ---------------------------------------------------------------------------
create or replace function public.follow(p_user_id uuid)
returns table (following boolean, followers integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_inserted boolean := false;
  v_count   integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_user_id is null or p_user_id = v_uid then
    raise exception 'You cannot follow yourself.' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles p where p.id = p_user_id and p.deleted_at is null) then
    raise exception 'unknown account' using errcode = '23503';
  end if;

  insert into public.follows (follower_id, followee_id)
  values (v_uid, p_user_id)
  on conflict do nothing;

  get diagnostics v_inserted = row_count;

  if v_inserted then
    perform app.notify(p_user_id, 'follow', v_uid, 'user', v_uid, 'started following you');
  end if;

  select count(*)::int into v_count from public.follows f where f.followee_id = p_user_id;
  return query select true, v_count;
end;
$$;

create or replace function public.unfollow(p_user_id uuid)
returns table (following boolean, followers integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  delete from public.follows f
   where f.follower_id = v_uid and f.followee_id = p_user_id;

  select count(*)::int into v_count from public.follows f where f.followee_id = p_user_id;
  return query select false, v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Read paths.
--
-- One author projection, defined once: handle, discriminator, badge, avatar,
-- follower flag. Every feed below returns exactly these columns plus its own
-- content fields, which is what lets the client use one model for all three.
-- ---------------------------------------------------------------------------
create or replace function public.feed_videos(
  p_following boolean default false,
  p_before_id uuid    default null,
  p_limit     integer default 12,
  p_author    uuid    default null
)
returns table (
  id            uuid,
  author_id     uuid,
  title         text,
  description   text,
  object_key    text,
  thumbnail_key text,
  duration_ms   integer,
  size_bytes    bigint,
  visibility    text,
  chapters      jsonb,
  view_count    bigint,
  like_count    integer,
  comment_count integer,
  tip_stars     bigint,
  published_at  timestamptz,
  liked_by_me   boolean,
  author_name   text,
  author_username text,
  author_discriminator text,
  author_avatar_path text,
  author_tag_label text,
  author_tag_color text,
  author_follower_count integer,
  following_author boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select v.id,
         v.author_id,
         v.title,
         v.description,
         v.object_key,
         v.thumbnail_key,
         v.duration_ms,
         v.size_bytes,
         v.visibility,
         v.chapters,
         v.view_count,
         v.like_count,
         v.comment_count,
         v.tip_stars,
         v.published_at,
         (vl.user_id is not null),
         coalesce(nullif(d.display_name, ''), d.username, 'MessengerX'),
         d.username,
         d.discriminator,
         d.avatar_path,
         d.tag_label,
         d.tag_color,
         (select count(*)::int from public.follows f where f.followee_id = v.author_id),
         (f.follower_id is not null)
  from public.videos v
  left join public.directory d on d.id = v.author_id
  left join public.video_likes vl on vl.video_id = v.id and vl.user_id = app.current_uid()
  left join public.follows f on f.followee_id = v.author_id and f.follower_id = app.current_uid()
  where v.deleted_at is null
    and v.visibility = 'public'
    and (p_author is null or v.author_id = p_author)
    and (
      not coalesce(p_following, false)
      or v.author_id = app.current_uid()
      or f.follower_id is not null
    )
    and (p_before_id is null or v.id < p_before_id)
  order by v.id desc
  limit least(greatest(coalesce(p_limit, 12), 1), 50);
$$;

create or replace function public.feed_shorts(
  p_following boolean default false,
  p_before_id uuid    default null,
  p_limit     integer default 10,
  p_author    uuid    default null
)
returns table (
  id            uuid,
  author_id     uuid,
  caption       text,
  object_key    text,
  thumbnail_key text,
  duration_ms   integer,
  size_bytes    integer,
  view_count    bigint,
  like_count    integer,
  comment_count integer,
  tip_stars     bigint,
  created_at    timestamptz,
  liked_by_me   boolean,
  author_name   text,
  author_username text,
  author_discriminator text,
  author_avatar_path text,
  author_tag_label text,
  author_tag_color text,
  author_follower_count integer,
  following_author boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select s.id,
         s.author_id,
         s.caption,
         s.object_key,
         s.thumbnail_key,
         s.duration_ms,
         s.size_bytes,
         s.view_count,
         s.like_count,
         s.comment_count,
         s.tip_stars,
         s.created_at,
         (sl.user_id is not null),
         coalesce(nullif(d.display_name, ''), d.username, 'MessengerX'),
         d.username,
         d.discriminator,
         d.avatar_path,
         d.tag_label,
         d.tag_color,
         (select count(*)::int from public.follows f where f.followee_id = s.author_id),
         (f.follower_id is not null)
  from public.shorts s
  left join public.directory d on d.id = s.author_id
  left join public.short_likes sl on sl.short_id = s.id and sl.user_id = app.current_uid()
  left join public.follows f on f.followee_id = s.author_id and f.follower_id = app.current_uid()
  where (p_author is null or s.author_id = p_author)
    and (
      not coalesce(p_following, false)
      or s.author_id = app.current_uid()
      or f.follower_id is not null
    )
    and (p_before_id is null or s.id < p_before_id)
  order by s.id desc
  limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;

-- Full-text + prefix search across people, videos and reels in one call — this
-- is what the search field under the logo uses.
create or replace function public.search_content(
  p_query text,
  p_limit integer default 24,
  p_kind  text    default null
)
returns table (
  kind        text,
  id          uuid,
  title       text,
  snippet     text,
  object_key  text,
  thumbnail_key text,
  duration_ms integer,
  view_count  bigint,
  like_count  integer,
  comment_count integer,
  created_at  timestamptz,
  author_id   uuid,
  author_name text,
  author_username text,
  author_discriminator text,
  author_avatar_path text,
  author_tag_label text,
  author_tag_color text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_q     text := btrim(coalesce(p_query, ''));
  v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 50);
  v_kind  text := nullif(btrim(coalesce(p_kind, '')), '');
  v_ts    tsquery;
begin
  if char_length(v_q) < app.setting_int('search.min_chars', 2) then
    return;
  end if;

  begin
    v_ts := websearch_to_tsquery('simple', v_q);
  exception when others then
    v_ts := null;
  end;

  -- Accounts first: searching a friend's name should not be buried under
  -- videos. `limit` is applied per block, so a narrow search still fills.
  if v_kind is null or v_kind = 'people' then
    return query
    select 'people',
           d.id,
           coalesce(nullif(d.display_name, ''), d.username),
           d.bio,
           null::text, null::text, null::integer, 0::bigint, 0::integer, 0::integer, null::timestamptz,
           d.id,
           coalesce(nullif(d.display_name, ''), d.username),
           d.username, d.discriminator, d.avatar_path, d.tag_label, d.tag_color
    from public.directory d
    where d.username ilike ('%' || v_q || '%')
       or d.display_name ilike ('%' || v_q || '%')
    order by d.username
    limit case when v_kind = 'people' then v_limit else greatest(v_limit / 3, 4) end;
  end if;

  if v_kind is null or v_kind = 'video' then
    return query
    select 'video',
           v.id,
           v.title,
           left(coalesce(v.description, ''), 240),
           v.object_key,
           v.thumbnail_key,
           v.duration_ms,
           v.view_count,
           v.like_count,
           v.comment_count,
           v.published_at,
           v.author_id,
           coalesce(nullif(d.display_name, ''), d.username),
           d.username, d.discriminator, d.avatar_path, d.tag_label, d.tag_color
    from public.videos v
    left join public.directory d on d.id = v.author_id
    where v.deleted_at is null
      and v.visibility = 'public'
      and (v_ts is null or v.search_tsv @@ v_ts or v.title ilike ('%' || v_q || '%') or v.author_id in (
        select p.id from public.profiles p
         where p.username ilike ('%' || v_q || '%') or p.display_name ilike ('%' || v_q || '%')
      ))
    order by (v.search_tsv @@ v_ts) desc nulls last, v.view_count desc, v.id desc
    limit case when v_kind = 'video' then v_limit else greatest(v_limit / 2, 6) end;
  end if;

  return query
  select 'short',
         s.id,
         coalesce(nullif(btrim(coalesce(s.caption, '')), ''), 'Reel'),
         left(coalesce(s.caption, ''), 240),
         s.object_key,
         s.thumbnail_key,
         s.duration_ms,
         s.view_count,
         s.like_count,
         s.comment_count,
         s.created_at,
         s.author_id,
         coalesce(nullif(d.display_name, ''), d.username),
         d.username, d.discriminator, d.avatar_path, d.tag_label, d.tag_color
  from public.shorts s
  left join public.directory d on d.id = s.author_id
  where (v_kind is null or v_kind = 'short')
    and (v_ts is null or s.search_tsv @@ v_ts or coalesce(s.caption, '') ilike ('%' || v_q || '%'))
  order by (s.search_tsv @@ v_ts) desc nulls last, s.view_count desc, s.id desc
  limit case when v_kind = 'short' then v_limit else greatest(v_limit / 2, 6) end;
end;
$$;

-- One profile's public numbers, including whether the caller follows them.
create or replace function public.profile_stats(p_user_id uuid)
returns table (
  user_id        uuid,
  username       text,
  discriminator  text,
  display_name   text,
  avatar_path    text,
  avatar_external_url text,
  bio            text,
  tag_label      text,
  tag_color      text,
  tag_emoji      text,
  is_online      boolean,
  followers      integer,
  following      integer,
  videos         integer,
  shorts         integer,
  total_views    bigint,
  total_likes    bigint,
  stars_earned   bigint,
  i_follow       boolean,
  follows_me     boolean,
  is_me          boolean,
  joined_at      timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.id,
         p.username,
         p.discriminator,
         coalesce(nullif(p.display_name, ''), p.username),
         p.avatar_path,
         p.avatar_external_url,
         p.bio,
         t.label,
         t.color,
         t.emoji,
         (p.last_seen_at > clock_timestamp() - (app.setting_int('realtime.presence_window', 5) || ' minutes')::interval),
         (select count(*)::int from public.follows f where f.followee_id = p.id),
         (select count(*)::int from public.follows f where f.follower_id = p.id),
         (select count(*)::int from public.videos v where v.author_id = p.id and v.deleted_at is null),
         (select count(*)::int from public.shorts s where s.author_id = p.id),
         (select coalesce(sum(v.view_count), 0)::bigint from public.videos v where v.author_id = p.id and v.deleted_at is null)
           + (select coalesce(sum(s.view_count), 0)::bigint from public.shorts s where s.author_id = p.id),
         (select coalesce(sum(v.like_count), 0)::bigint from public.videos v where v.author_id = p.id and v.deleted_at is null)
           + (select coalesce(sum(s.like_count), 0)::bigint from public.shorts s where s.author_id = p.id),
         (select coalesce(sum(l.delta), 0)::bigint from public.star_ledger l
           where l.user_id = p.id and l.delta > 0 and l.reason in ('tip_in', 'tag_sale')),
         exists (select 1 from public.follows f where f.follower_id = app.current_uid() and f.followee_id = p.id),
         exists (select 1 from public.follows f where f.followee_id = app.current_uid() and f.follower_id = p.id),
         (p.id = app.current_uid()),
         p.created_at
  from public.profiles p
  left join public.tags t on t.id = p.tag_id
  where p.id = p_user_id and p.deleted_at is null;
$$;

-- The "who to follow" rail on Home and on the empty Following tab.
create or replace function public.suggested_creators(p_limit integer default 12)
returns table (
  user_id       uuid,
  username      text,
  discriminator text,
  display_name  text,
  avatar_path   text,
  tag_label     text,
  tag_color     text,
  followers     integer,
  content_count integer,
  i_follow      boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.id,
         p.username,
         p.discriminator,
         coalesce(nullif(p.display_name, ''), p.username),
         p.avatar_path,
         t.label,
         t.color,
         (select count(*)::int from public.follows f where f.followee_id = p.id),
         (select count(*)::int from public.videos v where v.author_id = p.id and v.deleted_at is null)
           + (select count(*)::int from public.shorts s where s.author_id = p.id),
         exists (select 1 from public.follows f
                  where f.follower_id = app.current_uid() and f.followee_id = p.id)
  from public.profiles p
  left join public.tags t on t.id = p.tag_id
  where p.id <> coalesce(app.current_uid(), '00000000-0000-0000-0000-000000000000'::uuid)
    and p.deleted_at is null
    and p.account_kind = 'user'
    and not exists (select 1 from public.follows f
                     where f.follower_id = app.current_uid() and f.followee_id = p.id)
  order by (select count(*) from public.follows f where f.followee_id = p.id) desc,
           p.created_at desc
  limit least(greatest(coalesce(p_limit, 12), 1), 50);
$$;

-- ---------------------------------------------------------------------------
-- 8. Comments: read, write, like, pin.
-- ---------------------------------------------------------------------------
create or replace function public.comment_list(
  p_subject_kind text,
  p_subject_id   uuid,
  p_root_id      uuid    default null,
  p_before_id    uuid    default null,
  p_limit        integer default 20,
  p_sort         text    default 'top'    -- top | new
)
returns table (
  id             uuid,
  subject_kind   text,
  subject_id     uuid,
  root_id        uuid,
  parent_id      uuid,
  parent_author_name text,
  body           text,
  like_count     integer,
  reply_count    integer,
  is_pinned      boolean,
  is_mine        boolean,
  liked_by_me    boolean,
  edited_at      timestamptz,
  created_at     timestamptz,
  author_id      uuid,
  author_name    text,
  author_username text,
  author_discriminator text,
  author_avatar_path text,
  author_tag_label text,
  author_tag_color text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select c.id,
         c.subject_kind,
         c.subject_id,
         c.root_id,
         c.parent_id,
         pd.username,
         case when c.deleted_at is null then c.body else null end,
         c.like_count,
         c.reply_count,
         c.is_pinned,
         (c.author_id = app.current_uid()),
         (cl.user_id is not null),
         c.edited_at,
         c.created_at,
         c.author_id,
         case when c.deleted_at is null then coalesce(nullif(d.display_name, ''), d.username) else null end,
         case when c.deleted_at is null then d.username else null end,
         case when c.deleted_at is null then d.discriminator else null end,
         case when c.deleted_at is null then d.avatar_path else null end,
         case when c.deleted_at is null then d.tag_label else null end,
         case when c.deleted_at is null then d.tag_color else null end
  from public.content_comments c
  left join public.directory d on d.id = c.author_id
  left join public.directory pd on pd.id = c.parent_id
  left join public.comment_likes cl on cl.comment_id = c.id and cl.user_id = app.current_uid()
  where c.subject_kind = p_subject_kind
    and c.subject_id = p_subject_id
    and (
      (p_root_id is null and c.root_id is null)
      or (p_root_id is not null and c.root_id = p_root_id)
    )
    and (p_before_id is null or c.id < p_before_id)
  order by c.is_pinned desc,
           case when coalesce(p_sort, 'top') = 'new' then null else c.like_count end desc nulls last,
           c.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

create or replace function public.comment_add(
  p_subject_kind text,
  p_subject_id   uuid,
  p_body         text,
  p_parent_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid      uuid := app.current_uid();
  v_body     text := btrim(coalesce(p_body, ''));
  v_id       uuid;
  v_author   uuid;
  v_parent   public.content_comments%rowtype;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if char_length(v_body) < 1 then
    raise exception 'Write something first.' using errcode = '22023';
  end if;

  if char_length(v_body) > 2000 then
    raise exception 'Comments stay under 2000 characters.' using errcode = '22023';
  end if;

  -- A creator answering a thread is the one thing that outranks the sort.
  if p_subject_kind = 'video' then
    select v.author_id into v_author from public.videos v
     where v.id = p_subject_id and v.deleted_at is null;
  else
    select s.author_id into v_author from public.shorts s where s.id = p_subject_id;
  end if;

  insert into public.content_comments (subject_kind, subject_id, author_id, parent_id, body)
  values (p_subject_kind, p_subject_id, v_uid, p_parent_id, v_body)
  returning id into v_id;

  if p_parent_id is not null then
    select * into v_parent from public.content_comments c where c.id = p_parent_id;
    if found then
      perform app.notify(v_parent.author_id, 'reply', v_uid, 'comment', v_id,
        'replied: ' || left(v_body, 140));
    end if;
  end if;

  perform app.notify(v_author, 'comment', v_uid, p_subject_kind, p_subject_id,
    'commented: ' || left(v_body, 140));

  return v_id;
end;
$$;

create or replace function public.comment_delete(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  update public.content_comments c
     set deleted_at = clock_timestamp()
   where c.id = p_comment_id
     and c.deleted_at is null
     and (c.author_id = v_uid or app.is_service_call());

  if not found then
    raise exception 'You can only delete your own comment.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.comment_like(p_comment_id uuid, p_like boolean default true)
returns table (liked boolean, total_likes integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_author uuid;
  v_count  integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select c.author_id into v_author from public.content_comments c where c.id = p_comment_id;
  if v_author is null then
    raise exception 'unknown comment' using errcode = '23503';
  end if;

  if coalesce(p_like, true) then
    insert into public.comment_likes (comment_id, user_id)
    values (p_comment_id, v_uid)
    on conflict do nothing;

    if found then
      perform app.notify(v_author, 'comment_like', v_uid, 'comment', p_comment_id, 'liked your comment');
    end if;
  else
    delete from public.comment_likes cl
     where cl.comment_id = p_comment_id and cl.user_id = v_uid;
  end if;

  select c.like_count into v_count from public.content_comments c where c.id = p_comment_id;
  return query select coalesce(p_like, true), v_count;
end;
$$;

-- Pinning is the creator's privilege on their own content.
create or replace function public.comment_pin(p_comment_id uuid, p_pinned boolean default true)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_author uuid;
  v_target public.content_comments%rowtype;
begin
  select * into v_target from public.content_comments c where c.id = p_comment_id;
  if not found then
    raise exception 'unknown comment' using errcode = '23503';
  end if;

  if v_target.subject_kind = 'video' then
    select v.author_id into v_author from public.videos v where v.id = v_target.subject_id;
  else
    select s.author_id into v_author from public.shorts s where s.id = v_target.subject_id;
  end if;

  if v_author is distinct from v_uid and not app.is_service_call() then
    raise exception 'Only the creator can pin a comment.' using errcode = '42501';
  end if;

  if v_target.root_id is not null then
    raise exception 'Only top-level comments can be pinned.' using errcode = '22023';
  end if;

  update public.content_comments
     set is_pinned = coalesce(p_pinned, true)
   where id = p_comment_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Creator analytics: the curve behind "You → Studio".
-- ---------------------------------------------------------------------------
create or replace function public.creator_stats(p_days integer default 28)
returns table (
  day            date,
  views          bigint,
  likes          bigint,
  comments       bigint,
  followers      bigint,
  stars          bigint
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with span as (
    select generate_series(
      (now() at time zone 'utc')::date - (least(greatest(coalesce(p_days, 28), 1), 180) - 1),
      (now() at time zone 'utc')::date,
      interval '1 day'
    )::date as day
  ),
  mine as (
    select v.id, 'video'::text as kind from public.videos v
      where v.author_id = app.current_uid() and v.deleted_at is null
    union all
    select s.id, 'short'::text as kind from public.shorts s
      where s.author_id = app.current_uid()
  )
  select s.day,
         (select count(*)::bigint from public.content_views cv
           join mine m on m.id = cv.subject_id and m.kind = cv.subject_kind
          where cv.view_day = s.day),
         (select count(*)::bigint from public.video_likes vl join mine m on m.id = vl.video_id
           where m.kind = 'video' and vl.created_at::date = s.day)
           + (select count(*)::bigint from public.short_likes sl join mine m on m.id = sl.short_id
               where m.kind = 'short' and sl.created_at::date = s.day),
         (select count(*)::bigint from public.content_comments c join mine m on m.id = c.subject_id and m.kind = c.subject_kind
           where c.deleted_at is null and c.created_at::date = s.day),
         (select count(*)::bigint from public.follows f
           where f.followee_id = app.current_uid() and f.created_at::date = s.day),
         (select coalesce(sum(l.delta), 0)::bigint from public.star_ledger l
           where l.user_id = app.current_uid() and l.delta > 0
             and l.reason in ('tip_in', 'tag_sale') and l.created_at::date = s.day)
  from span s
  order by s.day;
$$;

create or replace function public.creator_earnings()
returns table (
  stars_earned  bigint,
  stars_tipped  bigint,
  tips_received integer,
  tags_sold     integer,
  followers     integer,
  total_views   bigint,
  total_likes   bigint,
  total_comments bigint
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as id)
  select
    (select coalesce(sum(l.delta), 0)::bigint from public.star_ledger l, me
      where l.user_id = me.id and l.delta > 0 and l.reason in ('tip_in', 'tag_sale')),
    (select coalesce(sum(-l.delta), 0)::bigint from public.star_ledger l, me
      where l.user_id = me.id and l.reason = 'tip_out'),
    (select count(*)::int from public.star_ledger l, me
      where l.user_id = me.id and l.reason = 'tip_in'),
    (select count(*)::int from public.star_ledger l, me
      where l.user_id = me.id and l.reason = 'tag_sale'),
    (select count(*)::int from public.follows f, me where f.followee_id = me.id),
    (select coalesce(sum(v.view_count), 0)::bigint from public.videos v, me where v.author_id = me.id and v.deleted_at is null)
      + (select coalesce(sum(s.view_count), 0)::bigint from public.shorts s, me where s.author_id = me.id),
    (select coalesce(sum(v.like_count), 0)::bigint from public.videos v, me where v.author_id = me.id and v.deleted_at is null)
      + (select coalesce(sum(s.like_count), 0)::bigint from public.shorts s, me where s.author_id = me.id),
    (select coalesce(sum(v.comment_count), 0)::bigint from public.videos v, me where v.author_id = me.id and v.deleted_at is null)
      + (select coalesce(sum(s.comment_count), 0)::bigint from public.shorts s, me where s.author_id = me.id);
$$;

-- ---------------------------------------------------------------------------
-- 10. The directory gains the follow flag the UI needs on every avatar row.
-- (Appended column only — `create or replace view` keeps the earlier order.)
-- ---------------------------------------------------------------------------
create or replace view public.directory
with (security_barrier = false)
as
select p.id,
       p.username,
       p.username_norm,
       p.display_name,
       p.avatar_path,
       p.avatar_external_url,
       p.bio,
       p.telegram_username,
       (p.last_seen_at > clock_timestamp() - (app.setting_int('realtime.presence_window', 5) || ' minutes')::interval) as is_online,
       p.last_seen_at,
       p.discriminator,
       p.account_kind,
       p.tag_id,
       t.slug  as tag_slug,
       t.label as tag_label,
       t.color as tag_color,
       t.emoji as tag_emoji,
       (p.tag_id is not null) as has_tag,
       exists (
         select 1 from public.follows f
         where f.follower_id = app.current_uid() and f.followee_id = p.id
       ) as is_following
from public.profiles p
left join public.tags t on t.id = p.tag_id
where p.deleted_at is null;

-- Trigger helpers and internal plumbing are not a client API.
/*
 * Trigger functions cannot be called directly from SQL, so the revoke is about
 * clarity rather than exposure; service_role keeps EXECUTE because the edge
 * runtime and the test harness raise some of them by hand.
 */
revoke all on function
  app.video_search_refresh(),
  app.short_search_refresh(),
  app.guard_comment_insert(),
  app.after_comment_write(),
  app.video_likes_recount(),
  app.comment_likes_recount()
  from public, anon;

grant execute on function
  app.video_search_refresh(),
  app.short_search_refresh(),
  app.guard_comment_insert(),
  app.after_comment_write(),
  app.video_likes_recount(),
  app.comment_likes_recount()
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 11. Grants, RLS and realtime.
-- ---------------------------------------------------------------------------
grant all on public.follows, public.videos, public.video_likes, public.content_comments,
  public.comment_likes, public.content_views to service_role;

grant select on public.follows, public.videos, public.video_likes, public.content_comments,
  public.comment_likes, public.content_views
  to authenticated;

grant select, insert, delete on public.follows to authenticated;
grant select, insert, update, delete on public.videos to authenticated;
grant select, insert, delete on public.video_likes, public.comment_likes to authenticated;
grant select, insert, update on public.content_comments to authenticated;

revoke all on public.videos, public.follows, public.video_likes, public.comment_likes,
  public.content_views from anon;

alter table public.follows           enable row level security;
alter table public.videos            enable row level security;
alter table public.video_likes       enable row level security;
alter table public.content_comments  enable row level security;
alter table public.comment_likes     enable row level security;
alter table public.content_views     enable row level security;

-- A follow edge is visible to the two accounts it joins, and to nobody else:
-- the aggregate counts come from profile_stats().
drop policy if exists follows_select_own on public.follows;
create policy follows_select_own on public.follows
  for select to authenticated
  using (follower_id = (select app.current_uid()) or followee_id = (select app.current_uid()));

drop policy if exists follows_insert_own on public.follows;
create policy follows_insert_own on public.follows
  for insert to authenticated
  with check (
    follower_id = (select app.current_uid())
    and app.access_ok((select app.current_uid()))
  );

drop policy if exists follows_delete_own on public.follows;
create policy follows_delete_own on public.follows
  for delete to authenticated
  using (follower_id = (select app.current_uid()));

-- Content: public to every signed-in user, writable by the author. The
-- eligibility rule is the same one a message insert passes.
drop policy if exists videos_select_all on public.videos;
create policy videos_select_all on public.videos
  for select to authenticated
  using (deleted_at is null);

drop policy if exists videos_insert_own on public.videos;
create policy videos_insert_own on public.videos
  for insert to authenticated
  with check (
    author_id = (select app.current_uid())
    and app.sender_may_post((select app.current_uid()))
  );

drop policy if exists videos_update_own on public.videos;
create policy videos_update_own on public.videos
  for update to authenticated
  using (author_id = (select app.current_uid()))
  with check (author_id = (select app.current_uid()));

drop policy if exists videos_delete_own on public.videos;
create policy videos_delete_own on public.videos
  for delete to authenticated
  using (author_id = (select app.current_uid()));

drop policy if exists video_likes_select_own on public.video_likes;
create policy video_likes_select_own on public.video_likes
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists video_likes_insert_own on public.video_likes;
create policy video_likes_insert_own on public.video_likes
  for insert to authenticated
  with check (user_id = (select app.current_uid()));

drop policy if exists video_likes_delete_own on public.video_likes;
create policy video_likes_delete_own on public.video_likes
  for delete to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists content_comments_select_all on public.content_comments;
create policy content_comments_select_all on public.content_comments
  for select to authenticated
  using (true);

drop policy if exists content_comments_insert_own on public.content_comments;
create policy content_comments_insert_own on public.content_comments
  for insert to authenticated
  with check (author_id = (select app.current_uid()));

drop policy if exists content_comments_update_own on public.content_comments;
create policy content_comments_update_own on public.content_comments
  for update to authenticated
  using (author_id = (select app.current_uid()))
  with check (author_id = (select app.current_uid()));

drop policy if exists comment_likes_select_own on public.comment_likes;
create policy comment_likes_select_own on public.comment_likes
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists comment_likes_insert_own on public.comment_likes;
create policy comment_likes_insert_own on public.comment_likes
  for insert to authenticated
  with check (user_id = (select app.current_uid()));

drop policy if exists comment_likes_delete_own on public.comment_likes;
create policy comment_likes_delete_own on public.comment_likes
  for delete to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists content_views_select_own on public.content_views;
create policy content_views_select_own on public.content_views
  for select to authenticated
  using (viewer_id = (select app.current_uid()));

-- Function grants ------------------------------------------------------------
grant execute on function
  public.follow(uuid),
  public.unfollow(uuid),
  public.feed_videos(boolean, uuid, integer, uuid),
  public.feed_shorts(boolean, uuid, integer, uuid),
  public.search_content(text, integer, text),
  public.profile_stats(uuid),
  public.suggested_creators(integer),
  public.comment_list(text, uuid, uuid, uuid, integer, text),
  public.comment_add(text, uuid, text, uuid),
  public.comment_delete(uuid),
  public.comment_like(uuid, boolean),
  public.comment_pin(uuid, boolean),
  public.register_view(text, uuid, integer),
  public.creator_stats(integer),
  public.creator_earnings()
  to authenticated;

do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['public.content_comments', 'public.videos'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = split_part(t, '.', 1)
          and tablename = split_part(t, '.', 2)
      ) then
        begin
          execute format('alter publication supabase_realtime add table %s', t);
        exception when others then
          raise notice 'could not add % to supabase_realtime: %', t, sqlerrm;
        end;
      end if;
    end loop;
  end if;
end
$$;

commit;
