-- 00028 — the client surface.
--
-- Everything here exists because the Flutter app needs it and nothing else
-- provided it: batched identity for a page of feed rows, one search box across
-- every surface, the playlist editor, creator analytics, and the "my stuff"
-- lists the screens open with.
--
-- The rule the rest of the schema follows applies here too: a client never
-- assembles a projection out of several round trips. One screen, one function,
-- and the authorization lives inside it.

-- ---------------------------------------------------------------------------
-- 1. Identity, batched.
--
-- A feed page shows 24 authors. Asking `profile_identity` 24 times is 24 round
-- trips to render one screen, so tags come back for the whole page at once.
-- ---------------------------------------------------------------------------
create or replace function public.profile_tags_batch(p_user_ids uuid[])
returns table (
  user_id     uuid,
  username    text,
  discriminator smallint,
  verified    boolean,
  account_kind text,
  tags        jsonb
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.id, p.username, p.discriminator, p.verified, p.account_kind,
         coalesce((
           select jsonb_agg(jsonb_build_object('id', t.id, 'text', t.text, 'emoji', t.emoji,
                                               'style', t.style, 'slot', t.slot,
                                               'active', t.is_active) order by t.slot)
             from public.profile_tags t
            where t.user_id = p.id and t.is_active
              and (t.expires_at is null or t.expires_at > clock_timestamp())
         ), '[]'::jsonb)
    from public.profiles p
   where p.id = any (coalesce(p_user_ids, '{}'::uuid[]))
     and p.deleted_at is null
   limit 200;
$$;

comment on function public.profile_tags_batch(uuid[]) is
  'Tags + handle for a whole page of authors in one call; the UI renders the same decoration everywhere from this.';

-- ---------------------------------------------------------------------------
-- 2. Discovery: people, and who is worth following.
-- ---------------------------------------------------------------------------
create or replace function public.people_directory(p_query text default null, p_limit integer default 40)
returns table (
  id             uuid,
  username       text,
  discriminator  smallint,
  display_name   text,
  avatar_path    text,
  bio            text,
  verified       boolean,
  is_private     boolean,
  account_kind   text,
  follower_count bigint,
  following_count integer,
  post_count     integer,
  is_following   boolean,
  follows_me     boolean,
  follow_state   text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as uid), needle as (
    select nullif(btrim(coalesce(p_query, '')), '') as q
  )
  select p.id, p.username, p.discriminator, p.display_name, p.avatar_path, p.bio,
         p.verified, p.is_private, p.account_kind, p.follower_count::bigint,
         p.following_count, p.post_count,
         app.is_following((select uid from me), p.id),
         exists (select 1 from public.follows f
                  where f.follower_id = p.id and f.followee_id = (select uid from me)
                    and f.state = 'accepted'),
         (select f.state::text from public.follows f
           where f.follower_id = (select uid from me) and f.followee_id = p.id)
    from public.profiles p
   where p.deleted_at is null
     and p.access_state = 'active'
     and app.can_view_user((select uid from me), p.id)
     and (
       (select q from needle) is null
       or p.username ilike '%' || (select q from needle) || '%'
       or coalesce(p.display_name, '') ilike '%' || (select q from needle) || '%'
     )
   order by p.follower_count desc, p.created_at desc
   limit least(greatest(coalesce(p_limit, 40), 1), 100);
$$;

create or replace function public.follow_suggestions(p_limit integer default 20)
returns table (
  id             uuid,
  username       text,
  discriminator  smallint,
  display_name   text,
  avatar_path    text,
  bio            text,
  verified       boolean,
  is_private     boolean,
  account_kind   text,
  follower_count bigint,
  following_count integer,
  post_count     integer,
  is_following   boolean,
  follows_me     boolean,
  follow_state   text,
  mutual_count   integer
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as uid),
  friends as (
    select f.followee_id as id from public.follows f
     where f.follower_id = (select uid from me) and f.state = 'accepted'
  )
  select p.id, p.username, p.discriminator, p.display_name, p.avatar_path, p.bio,
         p.verified, p.is_private, p.account_kind, p.follower_count::bigint,
         p.following_count, p.post_count,
         app.is_following((select uid from me), p.id),
         exists (select 1 from public.follows f2
                  where f2.follower_id = p.id and f2.followee_id = (select uid from me)
                    and f2.state = 'accepted'),
         (select f3.state::text from public.follows f3
           where f3.follower_id = (select uid from me) and f3.followee_id = p.id),
         (select count(*)::int from public.follows f4
           where f4.follower_id = p.id and f4.state = 'accepted'
             and f4.followee_id in (select id from friends))
    from public.profiles p
   where p.deleted_at is null
     and p.access_state = 'active'
     and p.id <> (select uid from me)
     and not app.is_following((select uid from me), p.id)
     and not app.blocked_pair((select uid from me), p.id)
     and app.can_view_user((select uid from me), p.id)
   order by 16 desc, p.follower_count desc
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

create or replace function public.blocked_users()
returns table (
  id            uuid,
  username      text,
  discriminator smallint,
  display_name  text,
  avatar_path   text,
  blocked_at    timestamptz,
  reason        text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.id, p.username, p.discriminator, p.display_name, p.avatar_path,
         b.created_at, b.reason
    from public.blocks b
    join public.profiles p on p.id = b.blocked_id
   where b.blocker_id = app.current_uid()
   order by b.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- 3. One search box, every surface.
--
-- Each branch calls the function that already owns that surface, so a search
-- result is authorized exactly like the feed it came from — no second
-- implementation to keep in sync.
-- ---------------------------------------------------------------------------
create or replace function public.search_all(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_uid uuid := app.current_uid();
begin
  if v_q is null or char_length(v_q) < 2 then
    return jsonb_build_object('people', '[]'::jsonb, 'videos', '[]'::jsonb, 'shorts', '[]'::jsonb,
                              'channels', '[]'::jsonb, 'communities', '[]'::jsonb, 'sounds', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'people', coalesce((select jsonb_agg(to_jsonb(x)) from public.people_directory(v_q, 12) x), '[]'::jsonb),
    'videos', coalesce((select jsonb_agg(to_jsonb(x)) from public.video_feed('for_you', null, null, null, 12, v_q) x), '[]'::jsonb),
    'shorts', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select s.id, s.author_id, s.object_key, s.thumbnail_key, s.duration_ms, s.caption,
               s.kind, s.like_count, s.comment_count, s.view_count, s.created_at, s.sound_id,
               s.reply_to_short,
               false as liked_by_me, false as saved_by_me,
               coalesce(nullif(btrim(p.display_name), ''), p.username) as author_name,
               p.username as author_username, p.discriminator as author_discriminator,
               p.avatar_path as author_avatar, p.verified as author_verified,
               app.is_following(v_uid, s.author_id) as followed_by_me,
               so.title as sound_title, so.artist as sound_artist, so.origin as sound_origin
          from public.shorts s
          join public.profiles p on p.id = s.author_id
          left join public.sounds so on so.id = s.sound_id
         where s.is_removed = false
           and s.visibility = 'public'
           and app.can_view_user(v_uid, s.author_id)
           and coalesce(s.caption, '') ilike '%' || v_q || '%'
         order by s.created_at desc
         limit 12
      ) x
    ), '[]'::jsonb),
    'channels', coalesce((select jsonb_agg(to_jsonb(x)) from public.channel_directory(v_q, 8) x), '[]'::jsonb),
    'communities', coalesce((select jsonb_agg(to_jsonb(x)) from public.community_directory(v_q, 8) x), '[]'::jsonb),
    'sounds', coalesce((select jsonb_agg(to_jsonb(x)) from public.sounds_feed(v_q, 8) x), '[]'::jsonb)
  );
end;
$$;

comment on function public.search_all(text) is
  'Global search: people, long-form, shorts, channels, communities and sounds, each branch delegated to the function that owns that surface.';

-- ---------------------------------------------------------------------------
-- 4. Playlists: the editor the library screen needs.
-- ---------------------------------------------------------------------------
create or replace function public.playlist_create(
  p_title       text,
  p_description text default null,
  p_visibility  text default 'private'
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
  if p_visibility not in ('public', 'unlisted', 'private') then
    raise exception 'visibility must be public, unlisted or private' using errcode = '22023';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'a playlist needs a title' using errcode = '22023';
  end if;
  insert into public.playlists (owner_id, title, description, visibility)
  values (v_uid, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''), p_visibility)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.playlist_delete(p_playlist_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_system boolean;
begin
  select pl.is_system into v_system from public.playlists pl
   where pl.id = p_playlist_id and pl.owner_id = v_uid;
  if not found then
    raise exception 'that playlist does not exist' using errcode = '42501';
  end if;
  if v_system then
    raise exception 'that list is part of the account and cannot be deleted' using errcode = '42501';
  end if;
  delete from public.playlists pl where pl.id = p_playlist_id and pl.owner_id = v_uid;
end;
$$;

create or replace function public.playlist_add(p_playlist_id uuid, p_video_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_next integer;
begin
  if not exists (select 1 from public.playlists pl
                  where pl.id = p_playlist_id and pl.owner_id = v_uid) then
    raise exception 'that playlist does not exist' using errcode = '42501';
  end if;
  if not app.video_visible(p_video_id, v_uid) then
    raise exception 'that video is not available' using errcode = '42501';
  end if;
  select coalesce(max(pi.position), 0) + 1 into v_next
    from public.playlist_items pi where pi.playlist_id = p_playlist_id;
  insert into public.playlist_items (playlist_id, video_id, position)
  values (p_playlist_id, p_video_id, v_next)
  on conflict (playlist_id, video_id) do nothing;
end;
$$;

create or replace function public.playlist_remove(p_playlist_id uuid, p_video_id uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  delete from public.playlist_items pi
   where pi.playlist_id = p_playlist_id
     and pi.video_id = p_video_id
     and exists (select 1 from public.playlists pl
                  where pl.id = p_playlist_id and pl.owner_id = app.current_uid());
$$;

create or replace function public.playlist_reorder(p_playlist_id uuid, p_video_id uuid, p_position integer)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.playlist_items pi
     set position = greatest(coalesce(p_position, 0), 0)
   where pi.playlist_id = p_playlist_id
     and pi.video_id = p_video_id
     and exists (select 1 from public.playlists pl
                  where pl.id = p_playlist_id and pl.owner_id = app.current_uid());
$$;

create or replace function public.playlist_items(p_playlist_id uuid)
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
  progress_ms    integer,
  sort_order     integer
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select v.id, v.title, v.description, v.thumbnail_key, v.duration_ms, v.view_count,
         v.like_count, v.comment_count, v.published_at, v.visibility, v.is_mature,
         c.slug, c.label, v.sound_id,
         p.id, coalesce(nullif(btrim(p.display_name), ''), p.username), p.username,
         p.discriminator, p.avatar_path, p.verified, p.follower_count::bigint,
         app.is_following(app.current_uid(), p.id),
         (select vl.verdict from public.video_likes vl
           where vl.video_id = v.id and vl.user_id = app.current_uid()),
         (select wp.position_ms from public.watch_progress wp
           where wp.video_id = v.id and wp.user_id = app.current_uid() and not wp.completed),
         pi.position
    from public.playlist_items pi
    join public.playlists pl on pl.id = pi.playlist_id
    join public.videos v on v.id = pi.video_id
    join public.profiles p on p.id = v.author_id
    left join public.video_categories c on c.id = v.category_id
   where pi.playlist_id = p_playlist_id
     and (
       pl.owner_id = app.current_uid()
       or (pl.visibility in ('public', 'unlisted') and v.deleted_at is null and v.is_removed = false)
     )
   order by pi.position, pi.added_at;
$$;

grant execute on function
  public.playlist_create(text, text, text),
  public.playlist_delete(uuid),
  public.playlist_add(uuid, uuid),
  public.playlist_remove(uuid, uuid),
  public.playlist_reorder(uuid, uuid, integer),
  public.playlist_items(uuid)
to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Categories, trends and the creator's own numbers.
-- ---------------------------------------------------------------------------
create or replace function public.video_categories_list()
returns table (slug text, label text, emoji text, video_count bigint)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select c.slug, c.label, c.emoji,
         (select count(*) from public.videos v
           where v.category_id = c.id and v.deleted_at is null and v.is_removed = false
             and v.visibility = 'public')
    from public.video_categories c
   order by c.position, c.slug;
$$;

create or replace function public.hashtag_trending(p_limit integer default 24)
returns table (tag text, use_count integer, recent_count integer)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select h.tag, h.use_count,
         (select count(*)::int from public.video_hashtags vh
            join public.videos v on v.id = vh.video_id
           where vh.tag = h.tag and v.published_at > clock_timestamp() - interval '7 days') as recent_count
    from public.hashtags h
   order by 3 desc, h.use_count desc
   limit least(greatest(coalesce(p_limit, 24), 1), 100);
$$;

-- The creator dashboard: one call, the numbers that matter, and the top five
-- videos so the screen has something to render below them.
create or replace function public.creator_stats()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as uid)
  select jsonb_build_object(
    'videos', (select count(*)::int from public.videos v where v.author_id = (select uid from me) and v.deleted_at is null),
    'shorts', (select count(*)::int from public.shorts s where s.author_id = (select uid from me) and s.is_removed = false),
    'views', (select coalesce(sum(v.view_count), 0)::bigint from public.videos v where v.author_id = (select uid from me))
              + (select coalesce(sum(s.view_count), 0)::bigint from public.shorts s where s.author_id = (select uid from me)),
    'likes', (select coalesce(sum(v.like_count), 0)::bigint from public.videos v where v.author_id = (select uid from me))
              + (select coalesce(sum(s.like_count), 0)::bigint from public.shorts s where s.author_id = (select uid from me)),
    'comments', (select count(*)::int from public.comments c
                  join public.videos v on v.id = c.video_id
                 where v.author_id = (select uid from me) and c.deleted_at is null),
    'followers', (select p.follower_count from public.profiles p where p.id = (select uid from me)),
    'following', (select p.following_count from public.profiles p where p.id = (select uid from me)),
    'stars_earned', (select coalesce(sum(g.stars), 0)::bigint from public.gifts g
                      where g.recipient_id = (select uid from me)),
    'top_videos', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select v.id, v.title, v.thumbnail_key, v.view_count, v.like_count, v.comment_count, v.published_at
          from public.videos v
         where v.author_id = (select uid from me) and v.deleted_at is null
         order by v.view_count desc
         limit 5
      ) x
    ), '[]'::jsonb),
    'recent_shorts', coalesce((
      select jsonb_agg(to_jsonb(x)) from (
        select s.id, s.object_key, s.thumbnail_key, s.caption, s.like_count, s.view_count, s.created_at
          from public.shorts s
         where s.author_id = (select uid from me) and s.is_removed = false
         order by s.created_at desc
         limit 5
      ) x
    ), '[]'::jsonb)
  );
$$;

comment on function public.creator_stats() is
  'Creator dashboard: lifetime totals over both engines plus the top five videos and the five newest shorts.';

-- ---------------------------------------------------------------------------
-- 6. Communities and channels the caller already belongs to.
-- ---------------------------------------------------------------------------
create or replace function public.community_my()
returns table (
  id            uuid,
  name          text,
  slug          text,
  description   text,
  icon_key      text,
  banner_key    text,
  member_count  integer,
  online_count  integer,
  is_public     boolean,
  joined        boolean,
  my_permissions bigint,
  is_owner      boolean,
  last_message_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select c.id, c.name, c.slug, c.description, c.icon_key, c.banner_key,
         c.member_count,
         (select count(*)::int from public.community_members m2
           join public.profiles p2 on p2.id = m2.user_id
          where m2.community_id = c.id
            and p2.last_seen_at > clock_timestamp() - interval '5 minutes'),
         c.is_public,
         true,
         app.community_permissions(c.id, app.current_uid()),
         c.owner_id = app.current_uid(),
         (select max(chats.last_message_at)
            from public.community_channels ch
            join public.chats on chats.id = ch.chat_id
           where ch.community_id = c.id and ch.deleted_at is null)
    from public.communities c
    join public.community_members m on m.community_id = c.id and m.user_id = app.current_uid()
   where c.deleted_at is null
   order by 13 desc nulls last, c.name;
$$;

create or replace function public.channel_mine()
returns table (
  chat_id          uuid,
  title            text,
  handle           text,
  description      text,
  avatar_path      text,
  subscriber_count integer,
  post_policy      text,
  is_public        boolean,
  my_role          text,
  joined           boolean,
  unread_count     integer,
  last_message_at  timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select c.id, c.title, c.handle, c.description, c.avatar_path,
         coalesce(c.subscriber_count, 0), coalesce(c.post_policy, 'admins'),
         coalesce(c.is_public, false),
         coalesce(cp.role, 'member'),
         true,
         (select count(*)::int from public.messages m
           where m.chat_id = c.id and m.deleted_at is null
             and (cp.last_read_at is null or m.created_at > cp.last_read_at)),
         c.last_message_at
    from public.chats c
    join public.chat_participants cp on cp.chat_id = c.id and cp.user_id = app.current_uid()
   where c.kind::text = 'channel' and cp.left_at is null
   order by c.last_message_at desc nulls last;
$$;

-- The owner's command list for one bot (the settings screen).
create or replace function public.bot_commands_list(p_bot_id uuid)
returns table (
  command      text,
  description  text,
  usage        text,
  options      jsonb,
  handler      text,
  builtin      text,
  permission   text,
  is_hidden    boolean,
  sort_order   integer
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select bc.name, bc.description, bc.usage, bc.options, bc.handler, bc.builtin_action,
         bc.default_permission, bc.is_hidden, bc.position::integer
    from public.bot_commands bc
   where bc.bot_id = p_bot_id
     and (exists (select 1 from public.bots b
                   where b.id = p_bot_id and (b.owner_id = app.current_uid() or b.is_public))
          or app.bot_can(p_bot_id, null, app.perm_send_messages()))
   order by bc.position, bc.name;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants.
-- ---------------------------------------------------------------------------
grant execute on function
  public.profile_tags_batch(uuid[]),
  public.people_directory(text, integer),
  public.follow_suggestions(integer),
  public.blocked_users(),
  public.search_all(text),
  public.video_categories_list(),
  public.hashtag_trending(integer),
  public.creator_stats(),
  public.community_my(),
  public.channel_mine(),
  public.bot_commands_list(uuid)
to authenticated;

comment on function public.community_my() is
  'Communities the caller is a member of, with the permission mask the UI hides controls with.';
comment on function public.channel_mine() is
  'Broadcast channels the caller follows, with the unread count the list badge needs.';
