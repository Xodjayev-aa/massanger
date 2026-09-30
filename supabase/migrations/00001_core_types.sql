-- =============================================================================
-- 00001_core_types.sql
-- MessengerX — enums, extensions, shared helper functions (idempotent).
--
-- Design notes
--   * We deliberately avoid optional extensions (citext, pgcrypto, pg_trgm) so
--     that the schema is portable between Supabase hosted / self-hosted / local
--     Postgres. Case-insensitivity and text search are solved with generated
--     columns + a tsvector GIN index instead.
--   * All primary keys for mutable, high-churn rows (messages) use a monotonic
--     UUIDv7 so that `order by id desc` is both stable and index-friendly.
-- =============================================================================

create schema if not exists app;
comment on schema app is 'Internal MessengerX helpers (not exposed through PostgREST).';

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'access_state') then
    create type public.access_state as enum (
      'pending_verification', -- signed up, eligibility check not passed yet
      'active',               -- full access
      'restricted',           -- can read own history, cannot send
      'banned',               -- hard-blocked by policy
      'deactivated'           -- user opted out
    );
    comment on type public.access_state is 'Account lifecycle / eligibility state used by RLS.';
  end if;

  if not exists (select 1 from pg_type where typname = 'chat_kind') then
    create type public.chat_kind as enum ('direct', 'group');
  end if;

  if not exists (select 1 from pg_type where typname = 'message_kind') then
    create type public.message_kind as enum ('text', 'image', 'voice', 'system');
    comment on type public.message_kind is 'Supported message payloads: text, image, voice (+ system notices).';
  end if;

  if not exists (select 1 from pg_type where typname = 'message_source') then
    create type public.message_source as enum ('app', 'telegram');
  end if;

  if not exists (select 1 from pg_type where typname = 'delivery_state') then
    create type public.delivery_state as enum (
      'sending',    -- client-side optimistic row
      'pending',    -- persisted, not yet handed to the transport
      'sent',       -- single tick: accepted by server / acknowledged by Telegram
      'delivered',  -- double grey tick
      'read',       -- double blue tick
      'failed'      -- terminal error, retriable by the user
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'participant_role') then
    create type public.participant_role as enum ('owner', 'admin', 'member');
  end if;

  if not exists (select 1 from pg_type where typname = 'telegram_auth_state') then
    create type public.telegram_auth_state as enum (
      'unlinked', 'awaiting_phone', 'awaiting_code', 'awaiting_password',
      'awaiting_registration', 'syncing', 'linked', 'needs_reauth', 'revoked', 'failed'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'link_request_kind') then
    create type public.link_request_kind as enum ('link', 'reauth', 'unlink');
  end if;

  if not exists (select 1 from pg_type where typname = 'link_request_status') then
    create type public.link_request_status as enum (
      'queued', 'claimed', 'awaiting_user', 'succeeded', 'failed', 'expired'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'outbox_state') then
    create type public.outbox_state as enum ('queued', 'in_flight', 'sent', 'failed', 'skipped');
  end if;

  if not exists (select 1 from pg_type where typname = 'sync_direction') then
    create type public.sync_direction as enum ('both', 'to_telegram', 'from_telegram', 'off');
  end if;

  if not exists (select 1 from pg_type where typname = 'verdict') then
    create type public.verdict as enum ('passed', 'failed', 'error');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Optional extensions (best effort; nothing in the schema *requires* them)
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    create extension if not exists pgcrypto with schema extensions;
  exception when others then
    raise notice 'pgcrypto unavailable (%) — falling back to built-ins', sqlerrm;
  end;
  begin
    create extension if not exists pg_trgm with schema extensions;
  exception when others then
    raise notice 'pg_trgm unavailable (%) — ILIKE search uses btree/gin fallback', sqlerrm;
  end;
end
$$;

-- ---------------------------------------------------------------------------
-- app.uuid_v7(): time-ordered UUID without pgcrypto dependency.
-- Layout: 48 bit unix-ms | 4 bit version(7) | 12 bit rand | 2 bit variant | 62 bit rand
-- ---------------------------------------------------------------------------
create or replace function app.uuid_v7()
returns uuid
language sql
volatile
set search_path = pg_catalog
as $$
  select (
           lpad(to_hex(floor(extract(epoch from clock_timestamp()) * 1000)::bigint), 12, '0')
        || '7'
        || substr(md5(random()::text), 1, 3)
        || to_hex(8 + floor(random() * 4)::int)
        || substr(md5(random()::text) || md5(random()::text), 1, 15)
  )::uuid;
$$;

comment on function app.uuid_v7() is 'RFC 9562 UUIDv7 (monotonic) implemented without pgcrypto.';

create or replace function public.gen_uuid_v7()
returns uuid
language sql
volatile
set search_path = pg_catalog
as $$
  select app.uuid_v7();
$$;

comment on function public.gen_uuid_v7() is 'Public alias of app.uuid_v7(), usable as a column default.';

-- ---------------------------------------------------------------------------
-- app.set_updated_at() — generic BEFORE UPDATE trigger body.
-- ---------------------------------------------------------------------------
create or replace function app.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Delivery state ordering: ticks may only move forward (never regress), which
-- keeps Realtime replays / bridge retries idempotent.
-- ---------------------------------------------------------------------------
create or replace function app.delivery_state_rank(s public.delivery_state)
returns int
language sql
immutable
parallel safe
as $$
  select case s
    when 'sending'   then 0
    when 'pending'   then 1
    when 'sent'      then 2
    when 'delivered' then 3
    when 'read'      then 4
    when 'failed'    then -1
  end;
$$;

-- ---------------------------------------------------------------------------
-- Role / claim helpers — usable inside RLS policies and SECURITY DEFINER code.
--
-- Two independent identity signals are used on purpose:
--   * `current_user` — the real Postgres role. It is the *only* signal a
--     malicious client cannot forge, and it becomes the function owner inside
--     SECURITY DEFINER code (that is precisely the trust we want there).
--   * the verified JWT `role` claim, published by GoTrue/PostgREST through the
--     `request.jwt.claims` GUC, which is the signal that survives `set role`.
-- `auth.*` helpers may return NULL when the request did not come through
-- GoTrue (direct SQL, unit tests, worker over TCP), so everything degrades
-- safely instead of throwing.
-- ---------------------------------------------------------------------------
create or replace function app.jwt_claim(p_key text)
returns text
language sql
stable
set search_path = pg_catalog
as $$
  select nullif(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> p_key,
    ''
  );
$$;

create or replace function app.current_role()
returns text
language sql
stable
set search_path = pg_catalog
as $$
  -- Prefer the real session role; fall back to the JWT claim.
  select coalesce(
    nullif(current_user::text, ''),
    app.jwt_claim('role'),
    'anon'
  );
$$;

-- Is this write/statement running in *trusted server code*?
--
-- True when the session itself is a privileged role (a migration, a maintenance
-- script, the service key) **or** when the code executing right now is owned by
-- the migration role — i.e. inside one of this schema's SECURITY DEFINER
-- functions, whose current_user is `postgres` no matter who called it.
--
-- That second half is deliberate and load-bearing: the guards on
-- profiles/messages/telegram_accounts use it to let server-side bookkeeping
-- (counters, tombstones, delivery state) through while keeping a *client's own*
-- writes on the narrow path.
--
--   use app.is_service_role()        → "may this write bypass the client guard?"
--   use app.caller_is_service_role() → "is the person on the other end staff?"
--
-- Authorization decisions must use the second one: inside a definer function
-- current_user is the owner, so the first one answers yes for every caller.
create or replace function app.is_service_role()
returns boolean
language sql
stable
set search_path = pg_catalog
as $$
  select current_user::text in
           ('service_role', 'supabase_admin', 'postgres', 'supabase_auth_admin', 'supabase_storage_admin')
      or coalesce(app.jwt_claim('role'), '') in ('service_role', 'supabase_admin')
      or coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), '') = 'service_role';
$$;

comment on function app.is_service_role() is
  'Trusted-write context: true for privileged sessions and for any code running inside an owner-owned SECURITY DEFINER function. Never use for authorization — use app.caller_is_service_role().';

-- Is the *caller of the request* the service role? Reads the assumed role (the
-- `role` GUC, which survives SECURITY DEFINER) and the JWT claim, never
-- current_user. This is the honest check to gate staff-only actions on.
create or replace function app.caller_is_service_role()
returns boolean
language sql
stable
set search_path = pg_catalog
as $$
  select case
    when coalesce(nullif(current_setting('role', true), ''), 'none')
         in ('service_role', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin')
      then true
    when coalesce(app.jwt_claim('role'), '') in ('service_role', 'supabase_admin') then true
    when coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), '') = 'service_role' then true
    -- No role was assumed at all: a direct psql / dashboard / migration session
    -- as the database owner is the service role.
    when coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres')
         and current_user::text in ('postgres', 'supabase_admin', 'service_role')
      then true
    else false
  end;
$$;

comment on function app.caller_is_service_role() is
  'True only when the request itself runs as the service role. Safe inside SECURITY DEFINER functions; the caller cannot spoof it through the call stack.';

-- The role of the *request*, not of the current function. Needed inside
-- SECURITY DEFINER code (triggers), where current_user is the owner: a client
-- must not be able to fake a privileged write just because a definer function
-- is in the call stack.
create or replace function app.request_role()
returns text
language sql
stable
set search_path = pg_catalog
as $$
  select coalesce(
    app.jwt_claim('role'),
    nullif(current_setting('request.jwt.claim.role', true), ''),
    current_user::text
  );
$$;

create or replace function app.is_request_service()
returns boolean
language sql
stable
set search_path = pg_catalog
as $$
  select app.request_role() in ('service_role', 'supabase_admin', 'postgres', 'supabase_auth_admin')
      or current_user::text in ('postgres', 'supabase_admin');
$$;

create or replace function app.current_uid()
returns uuid
language sql
stable
set search_path = pg_catalog, public
as $$
  -- auth.uid() is provided by Supabase; the GUC fallback keeps direct-SQL tests
  -- and the bridge worker runnable without GoTrue in the loop.
  select coalesce(
    auth.uid(),
    nullif(current_setting('app.uid', true), '')::uuid,
    nullif(app.jwt_claim('sub'), '')::uuid
  );
$$;
