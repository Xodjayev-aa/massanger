-- =============================================================================
-- Minimal Supabase surface: just enough for the MessengerX migrations to run on
-- a vanilla Postgres (used by `tools/sql-test` in CI). Never ship this to a
-- real project — the hosted platform already provides all of it.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role, postgres;

-- ---------------------------------------------------------------------------
-- auth
-- ---------------------------------------------------------------------------
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role, postgres;

create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  phone              text,
  raw_app_meta_data  jsonb not null default '{}'::jsonb,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default clock_timestamp()
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claims', true), ''),
      '{}'
    )::jsonb ->> 'sub',
    ''
  )::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    current_user::text
  );
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;

-- ---------------------------------------------------------------------------
-- storage
-- ---------------------------------------------------------------------------
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role, postgres;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default clock_timestamp(),
  updated_at         timestamptz not null default clock_timestamp()
);

create table if not exists storage.objects (
  id            uuid primary key default gen_random_uuid(),
  bucket_id     text references storage.buckets (id),
  name          text,
  owner         uuid,
  metadata      jsonb,
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp(),
  last_accessed_at timestamptz,
  path_tokens   text[] generated always as (string_to_array(name, '/')) stored
);

create or replace function storage.foldername(name text)
returns text[]
language sql
immutable
as $$
  select (string_to_array(name, '/'))[1 : greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)]
$$;

create or replace function storage.filename(name text)
returns text
language sql
immutable
as $$
  select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'), 1)]
$$;

create or replace function storage.extension(name text)
returns text
language sql
immutable
as $$
  select (string_to_array(regexp_replace(name, '.*[./]', '', 'g'), '.'))[1]
$$;

grant all on all tables in schema storage to postgres, service_role;
grant select on storage.buckets to anon, authenticated;
grant select, insert, update, delete on storage.objects to anon, authenticated;

-- The hosted platform runs with RLS enabled on storage.objects; mirror that so
-- the bucket policies in 00008 are actually exercised.
alter table storage.objects enable row level security;

grant all on all tables in schema auth to service_role, postgres;
grant usage on all sequences in schema auth to service_role;
