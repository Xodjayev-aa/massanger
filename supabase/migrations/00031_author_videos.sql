-- 00031: a creator's long-form catalogue.
--
-- The home feed can page tabs but cannot answer "everything this channel
-- published", which is what a channel page, the Profile tab's own grid and a
-- "more from this creator" row all need. The row shape mirrors `video_feed`
-- exactly — same columns, same order of meaning — so `VideoCard.fromMap` parses
-- both and the grid, the tile and the watch page keep working unchanged.
--
-- Visibility is the same predicate `video_feed` uses (public, or a followers-only
-- video the caller actually follows), so a private channel shows nothing to a
-- stranger and a subscriber sees everything they are entitled to.
create or replace function public.author_videos(
  p_author_id uuid,
  p_before_at timestamptz default null,
  p_before_id uuid default null,
  p_limit     integer default 24,
  p_include_private boolean default false
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
  with me as (select app.current_uid() as uid)
  select v.id,
         v.title,
         v.description,
         v.thumbnail_key,
         v.duration_ms,
         v.view_count,
         v.like_count,
         v.comment_count,
         v.published_at,
         v.visibility,
         v.is_mature,
         c.slug,
         c.label,
         v.sound_id,
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
           where vl.video_id = v.id and vl.user_id = (select uid from me)),
         (select wp.position_ms from public.watch_progress wp
           where wp.video_id = v.id and wp.user_id = (select uid from me) and not wp.completed)
    from public.videos v
    join public.profiles p on p.id = v.author_id and p.deleted_at is null
    left join public.video_categories c on c.id = v.category_id
   where v.author_id = p_author_id
     and v.deleted_at is null
     and v.is_removed = false
     and app.can_view_user((select uid from me), v.author_id)
     and (
       -- A channel page asks for the public catalogue; the owner's own Profile
       -- tab asks for everything, including the drafts only they can see.
       (v.visibility = 'public')
       or (p_include_private and v.author_id = (select uid from me))
       or (v.visibility = 'followers' and app.is_following((select uid from me), v.author_id))
     )
     and (
       p_before_at is null
       or (v.published_at, v.id) < (p_before_at, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
     )
   order by v.published_at desc, v.id desc
   limit least(greatest(coalesce(p_limit, 24), 1), 60);
$$;

comment on function public.author_videos(uuid, timestamptz, uuid, integer, boolean) is
  'One creator''s long-form catalogue in the video_feed row shape, keyset-paginated; p_include_private adds the caller''s own drafts.';

grant execute on function public.author_videos(uuid, timestamptz, uuid, integer, boolean) to authenticated, anon;
