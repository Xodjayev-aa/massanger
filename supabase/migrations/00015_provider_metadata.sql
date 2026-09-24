-- OIDC sign-in can be email-less (Telegram). Do not describe an address from
-- any other Supabase provider as a verified Google address. User-editable OAuth
-- profile claims are only display hints; account access remains server-managed.
-- Both trigger replacements are idempotent, so a fresh project and an upgraded
-- project behave the same way.

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
    case when new.raw_app_meta_data ->> 'provider' = 'google' then nullif(new.email, '') else null end,
    'active'
  );

  insert into public.telegram_accounts (user_id, auth_state)
  values (new.id, 'unlinked') on conflict (user_id) do nothing;
  return new;
end;
$$;

create or replace function app.handle_user_update()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.profiles p
     set phone_e164   = nullif(new.phone, ''),
         google_email = case when new.raw_app_meta_data ->> 'provider' = 'google'
                             then nullif(new.email, '') else null end,
         updated_at   = clock_timestamp()
   where p.id = new.id;
  return new;
end;
$$;

-- Auth may set provider metadata after the initial insert (identity linking).
drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update of email, phone, raw_app_meta_data on auth.users
  for each row execute function app.handle_user_update();

update public.profiles p
   set google_email = null
 where p.google_email is not null
   and not exists (
     select 1 from auth.users u
      where u.id = p.id and u.raw_app_meta_data ->> 'provider' = 'google'
   );

comment on column public.profiles.google_email is
  'Only a Supabase Google-provider address (not proof of account age). Null for Telegram/custom OAuth identities.';
