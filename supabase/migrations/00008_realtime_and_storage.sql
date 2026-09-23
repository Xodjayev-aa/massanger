-- =============================================================================
-- 00008_realtime_and_storage.sql
-- Massanger — Realtime replication + Storage buckets & policies.
--
-- Realtime is the *only* transport the Flutter UI needs for "instant": every
-- device subscribed to a chat receives INSERT/UPDATE events for `messages`
-- (new bubbles, typing state is broadcast-only) and UPDATE events for delivery
-- ticks. `REPLICA IDENTITY FULL` makes UPDATE payloads usable, which is what
-- lets a tick (✓ → ✓✓ → blue) patch a bubble without a refetch.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Row identity: clients need OLD+NEW for state-only updates.
-- ---------------------------------------------------------------------------
alter table public.messages           replica identity full;
alter table public.chats              replica identity full;
alter table public.chat_participants  replica identity full;
alter table public.telegram_accounts  replica identity full;
alter table public.telegram_outbox    replica identity full;
alter table public.telegram_link_requests replica identity full;

-- ---------------------------------------------------------------------------
-- 2. Publication (idempotent, and tolerant of a local dev DB without it).
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  v_tables text[] := array[
    'public.messages', 'public.chats', 'public.chat_participants',
    'public.telegram_accounts', 'public.telegram_outbox',
    'public.telegram_link_requests'
  ];
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      execute 'create publication supabase_realtime';
    exception when others then
      raise notice 'could not create supabase_realtime publication: %', sqlerrm;
      return;
    end;
  end if;

  foreach t in array v_tables loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = split_part(t, '.', 1)
        and tablename  = split_part(t, '.', 2)
    ) then
      begin
        execute format('alter publication supabase_realtime add table %s', t);
      exception when others then
        raise notice 'could not add % to supabase_realtime: %', t, sqlerrm;
      end;
    end if;
  end loop;
end
$$;

comment on table public.messages is
  'Published to supabase_realtime: chat screens subscribe with filter=chat_id.eq.<uuid>.';

-- ---------------------------------------------------------------------------
-- 3. Storage buckets.
--
--    avatars     public   <user_id>/…              (rendered everywhere)
--    images      private  <chat_id>/…              (signed URL, chat membership)
--    voice-notes private  <chat_id>/…              (signed URL, chat membership)
--
--    Paths are prefixed with the *chat* id on purpose: one RLS predicate
--    (`is_chat_member(folder)`) then governs every object of a conversation,
--    including mirrored Telegram media which the bridge uploads for us.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage.buckets not present — skipping bucket provisioning (bare Postgres)';
    return;
  end if;

  insert into storage.buckets as b (id, name, public, file_size_limit, allowed_mime_types)
  values
    ('avatars', 'avatars', true, 5242880,
      array['image/png', 'image/jpeg', 'image/webp', 'image/avif']),
    ('images', 'images', false, 20971520,
      array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/avif', 'application/pdf']),
    ('voice-notes', 'voice-notes', false, 10485760,
      array['audio/ogg', 'audio/opus', 'audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/webm', 'audio/x-m4a'])
  on conflict (id) do update
     set public             = excluded.public,
         file_size_limit    = excluded.file_size_limit,
         allowed_mime_types = excluded.allowed_mime_types,
         updated_at         = clock_timestamp();

  -- ---- avatars ------------------------------------------------------------
  drop policy if exists "avatars read" on storage.objects;
  create policy "avatars read" on storage.objects
    for select to public
    using (bucket_id = 'avatars');

  drop policy if exists "avatars upload own folder" on storage.objects;
  create policy "avatars upload own folder" on storage.objects
    for insert to authenticated
    with check (
      bucket_id = 'avatars'
      and (storage.foldername(name))[1] = (select app.current_uid())::text
      and app.access_ok((select app.current_uid()))
    );

  drop policy if exists "avatars update own folder" on storage.objects;
  create policy "avatars update own folder" on storage.objects
    for update to authenticated
    using ((storage.foldername(name))[1] = (select app.current_uid())::text)
    with check ((storage.foldername(name))[1] = (select app.current_uid())::text);

  drop policy if exists "avatars delete own folder" on storage.objects;
  create policy "avatars delete own folder" on storage.objects
    for delete to authenticated
    using (
      (storage.foldername(name))[1] = (select app.current_uid())::text
      or owner = (select app.current_uid())
    );

  -- ---- chat media (images + voice notes) ----------------------------------
  drop policy if exists "chat media read members" on storage.objects;
  create policy "chat media read members" on storage.objects
    for select to authenticated
    using (
      bucket_id in ('images', 'voice-notes')
      and app.is_chat_member(((storage.foldername(name))[1])::uuid, (select app.current_uid()))
    );

  drop policy if exists "chat media upload members" on storage.objects;
  create policy "chat media upload members" on storage.objects
    for insert to authenticated
    with check (
      bucket_id in ('images', 'voice-notes')
      and app.is_chat_member(((storage.foldername(name))[1])::uuid, (select app.current_uid()))
      and app.access_ok((select app.current_uid()))
    );

  drop policy if exists "chat media delete own" on storage.objects;
  create policy "chat media delete own" on storage.objects
    for delete to authenticated
    using (
      bucket_id in ('images', 'voice-notes')
      and (
        owner = (select app.current_uid())
        or app.is_chat_member(((storage.foldername(name))[1])::uuid, (select app.current_uid()))
      )
    );

exception when insufficient_privilege then
  raise notice 'not allowed to manage storage policies from this role — run `supabase storage apply` or apply as superuser';
end
$$;

-- NOTE: the TDLib bridge uploads mirrored Telegram media with the service key.
-- `service_role` bypasses RLS by design (Supabase default), so no policy is
-- needed there; the `storage.objects.owner` of such rows is the linked user,
-- which keeps the delete policy above meaningful.
