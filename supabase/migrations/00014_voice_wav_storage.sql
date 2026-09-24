-- The Flutter recorder wraps 16-bit PCM in a WAV container and uploads it as
-- audio/wav. The original voice-notes bucket omitted that MIME type, so every
-- app-recorded voice note was rejected by hosted Storage despite passing the
-- media JSON/RLS checks. Leave the older, Telegram-imported audio types intact.
update storage.buckets
   set allowed_mime_types = array_append(coalesce(allowed_mime_types, '{}'::text[]), 'audio/wav')
 where id = 'voice-notes'
   and not ('audio/wav' = any(coalesce(allowed_mime_types, '{}'::text[])));

-- 00008 accidentally allowed *every* participant to DELETE *every* other
-- participant's media from a chat. Members may read; only the uploader may
-- remove their own object. The service role handles bridge-owned objects.
drop policy if exists "chat media delete own" on storage.objects;
create policy "chat media delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('images', 'voice-notes')
    and owner = (select app.current_uid())
    and app.is_chat_member(((storage.foldername(name))[1])::uuid, (select app.current_uid()))
  );
