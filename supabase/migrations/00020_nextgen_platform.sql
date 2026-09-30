-- =============================================================================
-- 00020_nextgen_platform.sql
-- MessengerX Next-Gen: YouTube + TikTok + Telegram + Discord Hybrid
--
-- 1. Discord-style user roles, tags, discriminators, and badges.
-- 2. Enhanced shorts/videos schema with dual feeds:
--      • feed_type: 'short' (9:16 vertical reels) vs 'long' (16:9 YouTube video)
--      • view_count tracking and RPC incrementer
--      • comments on videos with threading & parent_id
--      • user following/followers system for the 'Following' feed
--      • community server channels (#general, #announcements, etc.)
-- =============================================================================

begin;

-- 1. Profiles additions: discord tag / role / banner
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists discriminator smallint default floor(random() * 9000 + 1000)::smallint,
  add column if not exists role_badge text default 'Member',
  add column if not exists role_color text default '#5865F2',
  add column if not exists custom_status text;

-- Update directory view to include the new Discord-style tags & roles
drop view if exists public.directory cascade;
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
       p.discriminator,
       p.role_badge,
       p.role_color,
       p.custom_status,
       (p.last_seen_at > clock_timestamp() - interval '5 minutes') as is_online,
       p.last_seen_at
from public.profiles p
where p.deleted_at is null;

comment on view public.directory is
  'Safe public projection of profiles with Discord-style role tags and discriminator.';

grant select on public.directory to anon, authenticated;

-- 2. User Follow System (Following vs For You / FYP feeds)
-- -----------------------------------------------------------------------------
create table if not exists public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (follower_id, following_id),
  constraint no_self_follow check (follower_id <> following_id)
);

create index if not exists follows_following_idx on public.follows (following_id);
create index if not exists follows_follower_idx on public.follows (follower_id);

alter table public.follows enable row level security;

drop policy if exists follows_select on public.follows;
create policy follows_select on public.follows
  for select to authenticated
  using (true);

drop policy if exists follows_insert_own on public.follows;
create policy follows_insert_own on public.follows
  for insert to authenticated
  with check (follower_id = (select app.current_uid()));

drop policy if exists follows_delete_own on public.follows;
create policy follows_delete_own on public.follows
  for delete to authenticated
  using (follower_id = (select app.current_uid()));

grant select, insert, delete on public.follows to authenticated;
grant all on public.follows to service_role;

-- 3. Extend shorts table to support YouTube long-form videos & metrics
-- -----------------------------------------------------------------------------
alter table public.shorts
  add column if not exists feed_type text not null default 'short' check (feed_type in ('short', 'long')),
  add column if not exists title text check (title is null or char_length(title) <= 200),
  add column if not exists description text check (description is null or char_length(description) <= 5000),
  add column if not exists thumbnail_path text,
  add column if not exists view_count bigint not null default 0 check (view_count >= 0);

create index if not exists shorts_feed_type_idx on public.shorts (feed_type, created_at desc);
create index if not exists shorts_author_idx on public.shorts (author_id, created_at desc);

-- RPC to increment video views cleanly without race conditions
create or replace function public.increment_video_views(p_video_id uuid)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_new_count bigint;
begin
  update public.shorts
     set view_count = view_count + 1
   where id = p_video_id
  returning view_count into v_new_count;

  return coalesce(v_new_count, 0);
end;
$$;

grant execute on function public.increment_video_views(uuid) to authenticated, anon;

-- 4. Video Comments (YouTube & TikTok style comments)
-- -----------------------------------------------------------------------------
create table if not exists public.video_comments (
  id uuid primary key default app.uuid_v7(),
  video_id uuid not null references public.shorts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  parent_id uuid references public.video_comments(id) on delete cascade,
  content text not null check (char_length(btrim(content)) between 1 and 2000),
  like_count integer not null default 0 check (like_count >= 0),
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists video_comments_video_idx on public.video_comments (video_id, created_at desc);

alter table public.video_comments enable row level security;

drop policy if exists video_comments_select on public.video_comments;
create policy video_comments_select on public.video_comments
  for select to authenticated
  using (true);

drop policy if exists video_comments_insert_own on public.video_comments;
create policy video_comments_insert_own on public.video_comments
  for insert to authenticated
  with check (
    author_id = (select app.current_uid())
    and app.sender_may_post((select app.current_uid()))
  );

drop policy if exists video_comments_delete_own on public.video_comments;
create policy video_comments_delete_own on public.video_comments
  for delete to authenticated
  using (author_id = (select app.current_uid()));

grant select, insert, delete on public.video_comments to authenticated;
grant all on public.video_comments to service_role;

-- 5. Discord-style community channel support in chats table
-- -----------------------------------------------------------------------------
alter table public.chats
  add column if not exists channel_type text default 'direct' check (channel_type in ('direct', 'server_text', 'server_voice', 'announcement')),
  add column if not exists server_name text check (server_name is null or char_length(server_name) <= 64),
  add column if not exists category text check (category is null or char_length(category) <= 64);

commit;
