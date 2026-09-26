-- =============================================================================
-- 00018_web_push_dispatch.sql
-- MessengerX — dispatch a browser-push sweep the moment a notice is queued.
--
-- `00017` made browser notifications work with no always-on worker of ours: any
-- open app drains the queue on its presence heartbeat. That is a true $0 default
-- (nothing to configure, nothing running), but it is a *pull* with a heartbeat's
-- worth of latency. This migration adds the push half:
--
--   message insert → web_push_requests row → pg_net → web-push-send edge function
--
-- and with it delivery within a few seconds of the message, at the database
-- level, with no laptop of ours involved.
--
-- Three things this deliberately does NOT do:
--
--   • It is not a requirement. Every piece below is created only if `pg_net` is
--     actually installed, so a database without it applies this migration
--     cleanly and keeps working exactly as `00017` left it. Migration 00001
--     treats pgcrypto and pg_trgm the same way; this follows that convention
--     rather than inventing a second one.
--   • It never fails a message. The dispatch runs inside a nested BEGIN/EXCEPTION
--     and reports trouble as a *warning*. A webhook outage must never be able to
--     stop somebody sending a message — the notice simply stays queued and the
--     heartbeat sweep picks it up, which is the behaviour `00017` already
--     guarantees.
--   • It does not put the sweep token in the trigger. The URL and the token are
--     read from Vault (`vault.decrypted_secrets`) at call time, or from a
--     database-local override for development. `pg_proc.prosrc` is readable by
--     more roles than a secret should be, and this repository's rule is that
--     secrets live in exactly one place.
--
-- Configuration is in docs/runbook.md §5b. Nothing here is required for browser
-- notifications to work; it only makes them fast.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The dispatcher.
-- Reads its configuration per call (never captured at creation time) so an
-- operator can rotate the token or move the function without a migration.
-- ---------------------------------------------------------------------------
create or replace function app.web_push_dispatch_config()
returns table (url text, token text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_url   text := nullif(current_setting('messengerx.push_dispatch_url', true), '');
  v_token text := nullif(current_setting('messengerx.push_dispatch_token', true), '');
begin
  -- A database-local override wins: `alter database ... set` (or a session GUC)
  -- is how a local stack points at `http://host.docker.internal:54321`. It is
  -- also the only mechanism available on a vanilla Postgres, where the `vault`
  -- schema does not exist at all.
  if v_url is null or v_token is null then
    -- Guarded and dynamic on purpose: a static reference to vault.decrypted_secrets
    -- would be resolved when this function is first planned, and would then fail
    -- on any database that has pg_net but not Vault.
    if to_regclass('vault.decrypted_secrets') is not null then
      execute $q$
        select max(case when name = 'messengerx_push_dispatch_url' then decrypted_secret end),
               max(case when name = 'messengerx_push_dispatch_token' then decrypted_secret end)
          from vault.decrypted_secrets
         where name in ('messengerx_push_dispatch_url', 'messengerx_push_dispatch_token')
      $q$ into v_url, v_token;
    end if;
  end if;

  -- The token is not optional: the function rejects a sweep without one, so a
  -- URL on its own is an incomplete configuration, not a partial delivery path.
  -- Reporting nothing here is the honest answer.
  if v_url is null or v_token is null then
    return;
  end if;

  return query select v_url, v_token;
end;
$$;

comment on function app.web_push_dispatch_config() is
  'Where to POST a browser-push sweep: Vault first, then a database-local GUC. Returns no rows when incomplete.';

/**
 * AFTER INSERT on the queue → one asynchronous HTTP request to web-push-send.
 *
 * `pg_net` is asynchronous by design: `net.http_post` enqueues the request and
 * returns an id immediately, so this adds no measurable latency to the insert
 * and the message transaction never waits on the network.
 *
 * `wait_ms` is the important detail. A notice is deliberately held for a 2 s
 * quiet window (see `app.queue_web_push`) so a burst folds into one
 * notification. A request fired at insert time therefore arrives *before* the
 * row is due — so the function is told to hold for a moment and claim again,
 * instead of this trigger trying to sleep inside the sender's transaction.
 */
create or replace function app.dispatch_web_push()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_url   text;
  v_token text;
begin
  select c.url, c.token into v_url, v_token from app.web_push_dispatch_config() c;

  if v_url is null then
    -- Not configured: the heartbeat sweep is the only delivery path, exactly as
    -- in 00017. Not an error, and specifically not a reason to fail the insert.
    return null;
  end if;

  begin
    perform net.http_post(
      url := v_url,
      body := jsonb_build_object('limit', 10, 'wait_ms', 3000),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || v_token
      ),
      timeout_milliseconds := 10000
    );
  exception when others then
    -- pg_net missing after the fact, an unknown signature, a bad URL: none of
    -- these may break the message that triggered the alert. The row is already
    -- committed by the time this runs, so the notice is safe.
    raise warning 'web push dispatch failed (%): %', SQLSTATE, SQLERRM;
  end;

  return null;
end;
$$;

comment on function app.dispatch_web_push() is
  'Queue one asynchronous web-push-send sweep through pg_net. Warns and continues if the webhook cannot be sent.';

-- ---------------------------------------------------------------------------
-- 2. The trigger, only where pg_net exists.
-- `to_regnamespace('net')` is true for every pg_net release, unlike a check on
-- one exact function signature, which would silently skip the trigger on a
-- version that renamed a parameter type.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regnamespace('net') is null then
    raise notice 'pg_net is not installed: browser-push notices fall back to the heartbeat sweep (00017)';
    return;
  end if;

  drop trigger if exists web_push_requests_dispatch on public.web_push_requests;
  create trigger web_push_requests_dispatch
    after insert on public.web_push_requests
    for each row execute function app.dispatch_web_push();
end
$$;

commit;

-- ---------------------------------------------------------------------------
-- 3. Grants.
-- The dispatcher is trigger-only: it reads a secret and makes an outbound
-- request, so it is not something any client role may call directly.
-- ---------------------------------------------------------------------------
revoke execute on function
  app.web_push_dispatch_config(),
  app.dispatch_web_push()
from public, anon, authenticated;
grant execute on function
  app.web_push_dispatch_config(),
  app.dispatch_web_push()
to service_role;
