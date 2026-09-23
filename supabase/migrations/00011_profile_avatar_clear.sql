-- 00011 — let a user remove their own avatar.
--
-- `update_profile` (00006) treats every parameter as "null means keep", which is
-- right for text but left no way to remove an avatar: an empty string is rejected by
-- the storage-prefix guard, and null means "keep". The client needs an explicit verb,
-- so the RPC gains a flag instead of a magic string a client could send by accident.
-- Everything else about the function is unchanged — including the prefix check that
-- stops one account from pointing itself at another account's storage folder.
--
-- The function is replaced rather than overloaded: PostgREST resolves RPCs by name,
-- and two same-named signatures make a *named-parameter* call ambiguous, which
-- would show up as a 406 from the auto-generated client. Every parameter keeps a
-- default, so callers that pass four arguments (or fewer) are unaffected.

begin;

-- The 4-argument form from 00006 is gone by design; drop it first so the new
-- signature is the only one Postgres and PostgREST can find.
drop function if exists public.update_profile(text, text, text, text);

create or replace function public.update_profile(
  p_display_name      text    default null,
  p_bio               text    default null,
  p_avatar_path       text    default null,
  p_telegram_username text    default null,
  p_clear_avatar      boolean default false
)
returns public.profiles
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_row public.profiles%rowtype;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_avatar_path is not null
     and p_avatar_path not like (v_uid::text || '/%')
     and p_avatar_path not like 'avatars/' || (v_uid::text || '/%')
  then
    raise exception 'avatar path must live under your own storage prefix'
      using errcode = '42501';
  end if;

  -- Clearing wins over setting: a client that sends both meant to drop the avatar,
  -- and silently keeping the old path is the worse failure.
  update public.profiles p
     set display_name      = coalesce(left(nullif(btrim(p_display_name), ''), 64), p.display_name),
         bio               = coalesce(left(nullif(btrim(p_bio), ''), 280), p.bio),
         avatar_path       = case
                               when coalesce(p_clear_avatar, false) then null
                               else coalesce(nullif(btrim(p_avatar_path), ''), p.avatar_path)
                             end,
         telegram_username = coalesce(
           lower(nullif(btrim(regexp_replace(coalesce(p_telegram_username, ''), '^@', '')), '')),
           p.telegram_username
         )
   where p.id = v_uid
  returning * into v_row;

  return v_row;
end;
$$;

comment on function public.update_profile(text, text, text, text, boolean) is
  'Caller-scoped profile write (display name, bio, avatar, Telegram handle). '
  'p_clear_avatar is the only way to remove an avatar (00011).';

-- 00009 owns the baseline grants; a re-created function loses them, so they are
-- restated here or every client call starts failing with 42501.
grant execute on function public.update_profile(text, text, text, text, boolean) to authenticated;
grant execute on function public.update_profile(text, text, text, text, boolean) to service_role;
revoke all on function public.update_profile(text, text, text, text, boolean) from public;
revoke execute on function public.update_profile(text, text, text, text, boolean) from anon;

commit;
