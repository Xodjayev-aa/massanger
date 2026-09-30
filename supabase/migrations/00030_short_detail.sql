-- 00030: read one short by id.
--
-- `shorts_feed` can page a tab but cannot answer "give me exactly this reel",
-- which is what a share link, a notification tap and the single-reel watch page
-- all need. The row shape deliberately mirrors `shorts_feed` so the client's one
-- `ShortCard.fromMap` parses both, and the visibility rule is the same
-- `app.short_visible` the feed and the like path already use.
create or replace function public.short_detail(p_short_id uuid)
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
  with me as (select app.current_uid() as uid)
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
    from public.shorts s
    join public.profiles p on p.id = s.author_id and p.deleted_at is null
    left join public.sounds so on so.id = s.sound_id
   where s.id = p_short_id
     -- The one gate: owner, public, followers-of, or an unlisted link the owner
     -- chose to publish. Everything else is an empty result, never a leak.
     and app.short_visible(p_short_id, (select uid from me))
   limit 1;
$$;

comment on function public.short_detail(uuid) is
  'One short in the shorts_feed row shape, gated by app.short_visible. Empty when the caller may not see it.';

grant execute on function public.short_detail(uuid) to authenticated, anon;
