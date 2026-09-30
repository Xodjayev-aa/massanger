-- 00029 — who may read a stored object.
--
-- `video-ticket` mints the presigned URLs, but until now its rule for the
-- `shorts/` key space was "the caller's own prefix only". That is right for
-- uploading and deleting, and wrong for the thing the whole product is: watching
-- somebody else's video. A feed that can only play your own clips is not a feed.
--
-- The authorization has to be a database question, not an edge-function guess,
-- because only the database knows whether an object is referenced by a row the
-- caller is allowed to see. `media_visible` is that question, in one function,
-- and the edge function defers to it.

create or replace function public.media_visible(p_key text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with me as (select app.current_uid() as uid)
  select
    -- A published video the caller can see (its bytes or its poster frame).
    exists (
      select 1 from public.videos v
       where (v.object_key = p_key or v.thumbnail_key = p_key)
         and v.deleted_at is null
         and v.is_removed = false
         and (v.visibility = 'public' or app.is_following((select uid from me), v.author_id))
         and app.can_view_user((select uid from me), v.author_id)
    )
    -- A published short the caller can see.
    or exists (
      select 1 from public.shorts s
       where (s.object_key = p_key or s.thumbnail_key = p_key)
         and s.is_removed = false
         and (s.visibility = 'public' or app.is_following((select uid from me), s.author_id))
         and app.can_view_user((select uid from me), s.author_id)
    )
    -- A sound that a visible short uses: the rights holder published it.
    or exists (
      select 1 from public.sounds so
       where so.object_key = p_key
         and exists (
           select 1 from public.shorts s
            where s.sound_id = so.id
              and s.is_removed = false
              and (s.visibility = 'public' or app.is_following((select uid from me), s.author_id))
              and app.can_view_user((select uid from me), s.author_id)
         )
    )
    -- A channel post's media, in a chat the caller is a member of.
    or exists (
      select 1 from public.messages m
       where m.deleted_at is null
         and (m.media ->> 'key' = p_key or m.media ->> 'thumbnailKey' = p_key)
         and app.is_chat_member(m.chat_id, (select uid from me))
    )
    -- Anything in the caller's own key space: their drafts, their uploads that
    -- have not been published yet, their avatars.
    or (app.current_uid() is not null
        and p_key like 'shorts/' || app.current_uid()::text || '/%');
$$;

comment on function public.media_visible(text) is
  'True when the storage key is referenced by a row the caller may see (or lives in their own key space). The edge function asks this before presigning a GET for somebody else''s object.';

grant execute on function public.media_visible(text) to authenticated, anon;

-- The object-key lookup the function does per GET deserves an index: the feed
-- issues one per visible tile.
create index if not exists videos_object_key_idx on public.videos (object_key);
create index if not exists videos_thumbnail_key_idx on public.videos (thumbnail_key) where thumbnail_key is not null;
create index if not exists shorts_object_key_idx on public.shorts (object_key);
create index if not exists shorts_thumbnail_key_idx on public.shorts (thumbnail_key) where thumbnail_key is not null;

commit;
