-- Consumer Google account creation time is not exposed by Google's documented
-- OAuth/Gmail profile APIs. Old Gmail/Drive content can be imported and is not
-- proof of account age. Retire the gate rather than silently admitting users on
-- an unverifiable security claim or asking for Gmail/Drive scopes.
--
-- Do not edit earlier, already-applied migrations. Preserve bans and unrelated
-- restrictions when migrating any existing project; only the old age-gate states
-- are reactivated. Existing Google credentials are no longer needed and must be
-- erased from the database before this project is opened to the public.

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_base text;
  v_username text;
begin
  v_base := left(
    app.username_from_text(coalesce(
      new.raw_user_meta_data ->> 'preferred_username',
      new.raw_user_meta_data ->> 'user_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      split_part(coalesce(new.email, ''), '@', 1),
      regexp_replace(coalesce(new.phone, ''), '[^0-9]', '', 'g')
    )), 24
  );
  if char_length(v_base) < 3 then
    v_base := 'user' || substr(md5(new.id::text), 1, 6);
  end if;

  v_username := v_base;
  while exists (select 1 from public.profiles p where p.username_norm = lower(v_username)) loop
    v_username := left(v_base, 24) || '_' || substr(md5(clock_timestamp()::text || random()::text), 1, 5);
  end loop;

  insert into public.profiles (
    id, username, display_name, phone_e164, google_email, access_state
  ) values (
    new.id,
    v_username,
    left(coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'preferred_username',
      v_base
    ), 64),
    nullif(new.phone, ''),
    nullif(new.email, ''),
    'active'
  );

  insert into public.telegram_accounts (user_id, auth_state)
  values (new.id, 'unlinked') on conflict (user_id) do nothing;
  return new;
end;
$$;

-- Only the gate's own recorded restrictions are rolled back. A manually
-- restricted/banned/deactivated account must never be upgraded by this migration.
update public.profiles p
   set access_state = 'active', access_state_reason = null
 where (p.access_state = 'pending_verification'
        and p.access_state_reason = 'Google accounts must be older than 1 year. Verify to unlock messaging.')
    or (p.access_state = 'restricted'
        and p.eligibility_method in ('gmail_profile', 'gmail_oldest_message', 'drive_oldest_file')
        and exists (select 1 from public.eligibility_checks ec
                    where ec.user_id = p.id and ec.verdict = 'failed'));

-- Clear untrustworthy account-age estimates regardless of whether the account
-- remains restricted. Do not retain OAuth material no longer needed for sign-in.
update public.profiles
   set google_account_created_at = null, google_account_age_days = null,
       eligibility_verified_at = null, eligibility_attempts = 0,
       eligibility_method = null
 where google_account_created_at is not null or google_account_age_days is not null
    or eligibility_verified_at is not null or eligibility_attempts <> 0
    or eligibility_method is not null;
truncate table public.google_credentials;

-- An old function or stale client must not re-activate a banned account by
-- replaying a fraudulent Gmail/Drive verdict. The compatibility HTTP function
-- now reads access_state without ever writing it.
drop function if exists public.record_eligibility_check(jsonb);

create or replace function public.eligibility_status()
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'access_state', p.access_state::text,
    'passed', p.access_state = 'active',
    'reason', p.access_state_reason,
    'username', p.username
  ))
  from public.profiles p where p.id = app.current_uid();
$$;
comment on function public.eligibility_status() is
  'Legacy name: reports account access state without claiming to verify Google account age.';
comment on column public.profiles.google_account_created_at is
  'Retired: not an authoritative Google-account creation time. Do not populate or display.';
comment on column public.profiles.google_account_age_days is
  'Retired: Gmail/Drive content is not proof of account age. Do not populate or display.';

-- Replacing a function can reset privileges on some deployments; explicitly
-- preserve authenticated-only read access to the compatibility status RPC.
revoke all on function public.eligibility_status() from public, anon;
grant execute on function public.eligibility_status() to authenticated, service_role;
