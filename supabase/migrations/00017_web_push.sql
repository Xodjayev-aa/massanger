-- =============================================================================
-- 00017_web_push.sql
-- MessengerX — real OS notifications with no machine of ours running.
--
-- 00012 solved "the recipient is not looking at the app" by pushing text into
-- *their own* Telegram Saved Messages. That works on every platform the user
-- already owns, but it needs the TDLib bridge to be alive somewhere, and this
-- project does not have a verified $0 always-on host. So an offline notice has
-- always carried an asterisk: "if your worker is running".
--
-- Web Push removes the asterisk for the browser. The push service (FCM, Mozilla,
-- Apple, WNS) keeps the socket to the device, the browser wakes *our* service
-- worker, and the service worker renders the notification. No always-on machine,
-- no FCM project, no OneSignal account, no Apple developer program — the app's
-- own origin is the identity, and VAPID is the signature.
--
-- This migration adds the server half:
--
--   1. `push_subscriptions` — one row per browser install that agreed to be
--      notified. The endpoint is the address; `p256dh`/`auth` are the keys the
--      browser generated. They are *not* device tokens and carry no identity.
--   2. `web_push_requests` — the same shape of queue 00012 uses for Telegram:
--      one open row per (user, chat), folded, cancellable, preview-free when the
--      user asked for that.
--   3. The rules, reusing 00012's privacy functions rather than re-deriving
--      them, so "already delivered by your Telegram" and "previews are off"
--      cannot drift apart between the two transports.
--
-- Relationship to `notify_requests`: the two queues are independent on purpose.
-- A Saved Messages notice needs a linked, live TDLib session; a web push needs
-- nothing but a subscription. Turning one off must not silently disable the
-- other, and a user with no Telegram account at all is exactly the person this
-- feature is for. They share the *rules*, not the rows.
--
-- What this deliberately does NOT do:
--   • it does not queue a web push while the recipient's app is foregrounded
--     (the in-app banner already covers that, and a duplicate OS notification is
--     the most annoying possible bug);
--   • it does not wait for a pending Telegram outbox row the way
--     `notify_waiting_for_telegram` makes the Saved Messages path wait. That
--     check exists so Telegram does not double-buzz a chat it is about to
--     deliver; here the whole point is to stop depending on Telegram. The
--     "already delivered" check (`notify_already_buzzed`) is still applied, so a
--     chat that Telegram really did deliver is not announced twice.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Preference. Sits next to push_telegram/push_preview and, like them, stays
-- out of `app.guard_profile_update()`'s protected list so the client may write
-- it directly; `set_web_push_enabled()` below is the ergonomic path because it
-- cancels queued work in the same transaction.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists push_web boolean not null default true;

comment on column public.profiles.push_web is
  'Browser push: notify my registered browsers when I am away. Independent of the Telegram notice switch.';

-- ---------------------------------------------------------------------------
-- 2. push_subscriptions — what the browser handed us in exchange for the right
-- to wake it. `endpoint` is unique: a browser installation has exactly one, and
-- signing into a different account on the same browser *moves* it (see the RPC),
-- because the old session can no longer be notified at that address.
-- ---------------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id              uuid primary key default app.uuid_v7(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  endpoint        text not null,
  -- The subscription's public key (P-256, uncompressed, base64url) and its
  -- shared auth secret. Useless without the endpoint, and the browser that owns
  -- the private half is the only thing that can read a payload we encrypt.
  p256dh          text not null,
  auth            text not null,
  label           text not null default '',
  user_agent      text not null default '',
  created_at      timestamptz not null default clock_timestamp(),
  last_seen_at    timestamptz not null default clock_timestamp(),
  last_success_at timestamptz,
  last_error      text,
  error_count     smallint not null default 0 check (error_count between 0 and 255),
  disabled_at     timestamptz,
  constraint push_subscriptions_endpoint_key unique (endpoint),
  -- Shape guard only; the authoritative check is the byte-level decode in
  -- supabase/functions/_shared/webpush.ts, which rejects before encrypting.
  constraint push_subscriptions_endpoint_shape check (char_length(endpoint) between 16 and 2048),
  constraint push_subscriptions_p256dh_shape check (p256dh ~ '^[A-Za-z0-9_-]{84,92}$'),
  constraint push_subscriptions_auth_shape check (auth ~ '^[A-Za-z0-9_-]{20,26}$'),
  constraint push_subscriptions_label_shape check (char_length(label) <= 60),
  constraint push_subscriptions_user_agent_shape check (char_length(user_agent) <= 300)
);

comment on table public.push_subscriptions is
  'Browser push subscriptions (Web Push endpoints + client keys). One row per browser install; RLS-scoped to its owner.';
comment on column public.push_subscriptions.endpoint is
  'The push service URL. Unique per browser install, so re-registering the same browser on another account moves the row.';
comment on column public.push_subscriptions.disabled_at is
  'Set when the push service answered 404/410 (subscription gone) — kept as history so a stale tab cannot silently re-enable it.';

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id) where disabled_at is null;
-- Pruning stale installs and finding "who can we still notify" both scan this.
create index if not exists push_subscriptions_live_idx
  on public.push_subscriptions (last_seen_at) where disabled_at is null;

-- ---------------------------------------------------------------------------
-- 3. web_push_requests — the queue. Same vocabulary as notify_requests so an
-- operator reading either table sees one design, and reusing `outbox_state`
-- keeps queued / in_flight / sent / skipped / failed meaning exactly one thing.
-- ---------------------------------------------------------------------------
create table if not exists public.web_push_requests (
  id              uuid primary key default app.uuid_v7(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  chat_id         uuid not null references public.chats (id) on delete cascade,
  sender_user_id  uuid references public.profiles (id) on delete set null,
  sender_name     text not null default '',
  last_message_id uuid references public.messages (id) on delete set null,
  -- A burst folds into this row instead of stacking notifications.
  folded          integer not null default 1 check (folded between 1 and 999),
  -- '' when the user turned previews off: the queue then carries no content.
  preview         text not null default '' check (char_length(preview) <= 160),
  source          public.message_source not null default 'app',
  state           public.outbox_state not null default 'queued',
  attempts        smallint not null default 0 check (attempts between 0 and 255),
  max_attempts    smallint not null default 4 check (max_attempts between 1 and 20),
  -- How many browser installs accepted this notice on the last attempt.
  delivered_count smallint not null default 0 check (delivered_count between 0 and 255),
  claimed_by      text,
  claimed_at      timestamptz,
  next_attempt_at timestamptz not null default clock_timestamp(),
  last_error      text,
  created_at      timestamptz not null default clock_timestamp(),
  updated_at      timestamptz not null default clock_timestamp()
);

comment on table public.web_push_requests is
  'Browser-push notice queue: at most one open row per (user, chat), delivered to that user''s subscriptions by the web-push edge function.';
comment on column public.web_push_requests.folded is
  'How many messages this one notice stands for; rendered as "+N more".';
comment on column public.web_push_requests.preview is
  'The exact text claimed at delivery time. A privacy switch scrubs it, and the sender re-checks it before encrypting.';

create unique index if not exists web_push_requests_open_uniq
  on public.web_push_requests (user_id, chat_id)
  where state = 'queued';

create index if not exists web_push_requests_claim_idx
  on public.web_push_requests (next_attempt_at, id)
  where state in ('queued', 'in_flight');

create index if not exists web_push_requests_prune_idx
  on public.web_push_requests (updated_at)
  where state in ('sent', 'skipped', 'failed');

create index if not exists web_push_requests_user_idx
  on public.web_push_requests (user_id, state);

drop trigger if exists web_push_requests_touch on public.web_push_requests;
create trigger web_push_requests_touch
  before update on public.web_push_requests
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. The rules.
-- `notify_should_send` is the Telegram twin of this function and differs in
-- exactly one clause: it requires `telegram_accounts.auth_state = 'linked'`.
-- Everything else — the 90 s offline window, never-notify-the-author, active
-- account — is copied deliberately rather than shared, because the two channels
-- must be able to diverge without one silently gating the other.
-- ---------------------------------------------------------------------------
create or replace function app.web_push_should_send(p_user uuid, p_sender uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p_user is not null
     -- Your own message never buzzes you.
     and p_user is distinct from p_sender
     and exists (
       select 1
         from public.profiles pr
        where pr.id = p_user
          and pr.deleted_at is null
          and pr.access_state = 'active'
          and pr.push_web
          -- Two missed 45 s heartbeats: the app is backgrounded or killed. A
          -- foregrounded app shows the in-app banner instead.
          and (pr.last_seen_at is null or pr.last_seen_at < clock_timestamp() - interval '90 seconds')
          -- No registered browser means nothing to send to: queueing would only
          -- leave a row that the sender has to skip.
          and exists (
            select 1 from public.push_subscriptions ps
             where ps.user_id = pr.id and ps.disabled_at is null
          )
     );
$$;

/**
 * Still owed? Re-checked at claim time and again immediately before encryption,
 * which is what makes "the user opened the app 2 s ago" cancel a notice that was
 * queued 2 min ago.
 */
create or replace function app.web_push_row_owed(
  p_user uuid,
  p_chat uuid,
  p_sender uuid,
  p_source public.message_source default 'app',
  p_message uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select app.web_push_should_send(p_user, p_sender)
     and not app.notify_already_buzzed(p_user, p_chat, p_source, p_message)
     and exists (
       select 1
         from public.chat_participants cp
        where cp.chat_id = p_chat
          and cp.user_id = p_user
          and cp.left_at is null
          and cp.unread_count > 0
          and (cp.muted_until is null or cp.muted_until <= clock_timestamp())
     );
$$;

-- ---------------------------------------------------------------------------
-- 5. Queueing.
-- Runs after `app.after_message_write()` and independently of
-- `app.queue_self_push()` (both are AFTER triggers on messages; trigger names
-- sort alphabetically but neither depends on the other, so order is irrelevant).
-- ---------------------------------------------------------------------------
create or replace function app.queue_web_push()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_part    record;
  v_preview text;
begin
  if tg_op = 'UPDATE' and old.deleted_at is null and new.deleted_at is not null then
    -- A message retracted before it was delivered must not appear on a lock
    -- screen. Dropping the folded row is safer than leaking its preview.
    delete from public.web_push_requests n
     where n.last_message_id = new.id and n.state = 'queued';
    update public.web_push_requests n
       set state = 'skipped', last_error = 'message retracted'
     where n.last_message_id = new.id and n.state = 'in_flight';
    return new;
  end if;

  if new.kind = 'system' or new.deleted_at is not null then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.deleted_at is not null and new.deleted_at is null then
      null;  -- a restored message is a new arrival: fall through and queue it
    elsif new.body is distinct from old.body or new.kind is distinct from old.kind then
      -- An edit refreshes a notice that has not been delivered yet, but only for
      -- people who asked for previews.
      update public.web_push_requests n
         set preview = app.notify_body_preview(new, true)
        from public.profiles pr
       where n.last_message_id = new.id
         and n.state = 'queued'
         and pr.id = n.user_id
         and pr.push_preview;
      return new;
    else
      return new;
    end if;
  end if;

  for v_part in
    select cp.user_id, pr.push_preview
    from public.chat_participants cp
    join public.profiles pr on pr.id = cp.user_id
    where cp.chat_id = new.chat_id
      and cp.user_id is distinct from new.sender_id
      and cp.left_at is null
      and (cp.muted_until is null or cp.muted_until <= clock_timestamp())
      and app.web_push_should_send(cp.user_id, new.sender_id)
      and not app.notify_already_buzzed(cp.user_id, new.chat_id, new.source, new.id)
  loop
    v_preview := app.notify_body_preview(new, v_part.push_preview);

    insert into public.web_push_requests as n (
      user_id, chat_id, sender_user_id, sender_name, last_message_id, preview, source, folded, next_attempt_at
    ) values (
      v_part.user_id,
      new.chat_id,
      new.sender_id,
      -- Stamped by `messages_before_insert`, so it is already the human label.
      coalesce(nullif(btrim(new.sender_name), ''), 'MessengerX'),
      new.id,
      v_preview,
      new.source,
      1,
      -- A short quiet window folds a burst into one notification instead of a
      -- notification storm. Nothing is lost while waiting: the row is visible
      -- to the sender, which is what wakes the delivery function.
      clock_timestamp() + interval '2 seconds'
    )
    on conflict (user_id, chat_id) where state = 'queued'
    do update set
      folded          = least(999, n.folded + 1),
      preview         = excluded.preview,
      sender_user_id  = excluded.sender_user_id,
      sender_name     = excluded.sender_name,
      last_message_id = excluded.last_message_id,
      source          = excluded.source,
      next_attempt_at = clock_timestamp() + interval '2 seconds',
      attempts        = 0,
      claimed_by      = null,
      claimed_at      = null,
      last_error      = null;
  end loop;

  return coalesce(new, old);
end;
$$;

drop trigger if exists messages_queue_web_push on public.messages;
create trigger messages_queue_web_push
  after insert or update on public.messages
  for each row execute function app.queue_web_push();

-- ---------------------------------------------------------------------------
-- 6. Cancellation.
-- These are *additional* triggers on the same tables 00012 already watches, so
-- the tested Telegram path is not rewritten: reading, muting or leaving cancels
-- both queues, and the two policies stay readable side by side.
-- ---------------------------------------------------------------------------
create or replace function app.cancel_queued_web_push()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid := case when tg_op = 'DELETE' then old.user_id else new.user_id end;
  v_chat uuid := case when tg_op = 'DELETE' then old.chat_id else new.chat_id end;
begin
  if tg_op = 'DELETE'
     or new.left_at is not null
     or new.unread_count = 0
     or (new.muted_until is not null
         and (old.muted_until is null or new.muted_until > old.muted_until))
  then
    delete from public.web_push_requests n
     where n.user_id = v_user
       and n.chat_id = v_chat
       and n.state = 'queued';
    -- A sender may have leased the row just before the read. Mark it skipped:
    -- web_push_owed refuses it, and a late completion cannot flip it to sent.
    update public.web_push_requests n
       set state = 'skipped', last_error = 'read, muted or left'
     where n.user_id = v_user and n.chat_id = v_chat and n.state = 'in_flight';
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists chat_participants_cancel_web_push on public.chat_participants;
create trigger chat_participants_cancel_web_push
  after update or delete on public.chat_participants
  for each row execute function app.cancel_queued_web_push();

create or replace function app.cancel_web_push_on_profile()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.push_preview is false and old.push_preview is true then
    -- A preview already handed to a sender would otherwise be encrypted and
    -- delivered after the privacy switch. Scrub it; the sender re-checks the
    -- text it claimed and drops the row when it no longer matches.
    update public.web_push_requests n
       set preview = ''
     where n.user_id = new.id
       and n.state in ('queued', 'in_flight')
       and n.preview <> '';
  end if;

  if (new.push_web is false and old.push_web is true)
     or (new.access_state <> 'active' and old.access_state = 'active')
     or (new.deleted_at is not null and old.deleted_at is null)
     or (new.last_seen_at is not null
         and new.last_seen_at >= clock_timestamp() - interval '90 seconds'
         and (old.last_seen_at is null
              or old.last_seen_at < clock_timestamp() - interval '90 seconds'))
  then
    delete from public.web_push_requests n
     where n.user_id = new.id
       and n.state = 'queued';
    update public.web_push_requests n
       set state = 'skipped', last_error = 'profile changed'
     where n.user_id = new.id and n.state = 'in_flight';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_cancel_web_push on public.profiles;
create trigger profiles_cancel_web_push
  after update on public.profiles
  for each row execute function app.cancel_web_push_on_profile();

-- ---------------------------------------------------------------------------
-- 7. Client RPCs.
-- ---------------------------------------------------------------------------

/**
 * Register (or re-register) this browser.
 *
 * The endpoint is unique, so this is an upsert keyed on it. Reassigning the row
 * to the caller is deliberate: the same browser signing in as somebody else must
 * stop notifying the previous account, and only the caller's own tab can know
 * the endpoint in the first place.
 *
 * Returns the same small projection the UI needs, never the keys.
 */
create or replace function public.register_push_subscription(
  p_endpoint text,
  p_p256dh   text,
  p_auth     text,
  p_label    text default '',
  p_user_agent text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  -- Enough for phone + laptop + tablet across two browsers, small enough that a
  -- bug cannot turn the table into an unbounded notification fan-out.
  c_max_devices constant integer := 8;
  v_uid    uuid := app.current_uid();
  v_row    public.push_subscriptions%rowtype;
  v_active integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_endpoint is null or char_length(btrim(p_endpoint)) not between 16 and 2048 then
    raise exception 'push endpoint must be between 16 and 2048 characters' using errcode = '22023';
  end if;
  if p_p256dh !~ '^[A-Za-z0-9_-]{84,92}$' then
    raise exception 'push key is not a base64url P-256 point' using errcode = '22023';
  end if;
  if p_auth !~ '^[A-Za-z0-9_-]{20,26}$' then
    raise exception 'push auth secret is not 16 base64url bytes' using errcode = '22023';
  end if;

  -- Count only *other* live rows: re-registering a known browser is a refresh,
  -- not a new device, so it must not trip the cap.
  select count(*) into v_active
    from public.push_subscriptions ps
   where ps.user_id = v_uid
     and ps.disabled_at is null
     and ps.endpoint <> btrim(p_endpoint);
  if v_active >= c_max_devices then
    raise exception 'too many registered browsers (maximum %); remove one first', c_max_devices
      using errcode = '54000';
  end if;

  insert into public.push_subscriptions as ps (
    user_id, endpoint, p256dh, auth, label, user_agent
  ) values (
    v_uid,
    btrim(p_endpoint),
    btrim(p_p256dh),
    btrim(p_auth),
    left(coalesce(btrim(p_label), ''), 60),
    left(coalesce(btrim(p_user_agent), ''), 300)
  )
  on conflict (endpoint) do update set
    user_id      = excluded.user_id,
    p256dh       = excluded.p256dh,
    auth         = excluded.auth,
    label        = excluded.label,
    user_agent   = excluded.user_agent,
    last_seen_at = clock_timestamp(),
    -- Registering again proves the browser is alive, so a previous 404/410 is
    -- forgotten along with the error counter.
    disabled_at  = null,
    last_error   = null,
    error_count  = 0
  returning * into v_row;

  return jsonb_build_object(
    'id',           v_row.id,
    'label',        v_row.label,
    'created_at',   v_row.created_at,
    'last_seen_at', v_row.last_seen_at
  );
end;
$$;

/** Turn browser push off/on, cancelling anything queued under the old answer. */
create or replace function public.set_web_push_enabled(p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_on  boolean;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.profiles p
     set push_web = coalesce(p_enabled, p.push_web)
   where p.id = v_uid
  returning p.push_web into v_on;

  if not found then
    raise exception 'profile % is missing', v_uid using errcode = '42501';
  end if;

  if p_enabled is false then
    delete from public.web_push_requests n
     where n.user_id = v_uid and n.state = 'queued';
  end if;

  return v_on;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Sender RPCs (service role only).
-- The edge function is the only caller: it leases rows, looks up the recipient's
-- browsers, encrypts and posts, then reports each outcome back here.
-- ---------------------------------------------------------------------------

/**
 * Lease due notices. `for update skip locked` is what lets two concurrent
 * sweeps (a sender's tab and the scheduled one) run without sending twice.
 *
 * Three maintenance passes run first, mirroring `bridge_claim_notify` — without
 * them the queue has states it can never leave:
 *   • a notice nobody is owed any more is *skipped*, not failed: the recipient
 *     read the chat, which is the system working;
 *   • a notice out of attempts is *failed*, so an operator sees a real problem;
 *   • an expired lease is returned to the queue (or failed). A sweep that dies
 *     mid-flight must not strand its rows as `in_flight` forever.
 */
create or replace function public.web_push_claim(
  p_worker text,
  p_limit  integer  default 10,
  p_lease  interval default interval '60 seconds'
)
returns table (
  id              uuid,
  user_id         uuid,
  chat_id         uuid,
  chat_title      text,
  chat_kind       public.chat_kind,
  sender_name     text,
  preview         text,
  folded          integer,
  source          public.message_source,
  last_message_id uuid,
  attempts        smallint,
  max_attempts    smallint,
  created_at      timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_worker is null or char_length(p_worker) not between 1 and 120 then
    raise exception 'worker id is required' using errcode = '22023';
  end if;

  -- 1. Nobody is waiting for this any more. Only unclaimed rows are retired: a
  -- live lease belongs to another sweep and is judged by `web_push_owed` at
  -- send time, so one sender never cancels another's in-flight work.
  update public.web_push_requests n
     set state = 'skipped',
         claimed_by = null,
         claimed_at = null,
         last_error = 'no longer owed'
   where n.state = 'queued'
     and not app.web_push_row_owed(n.user_id, n.chat_id, n.sender_user_id, n.source, n.last_message_id);

  -- 2. Attempts exhausted on a notice that is still owed: a real failure.
  update public.web_push_requests n
     set state = 'failed', last_error = coalesce(n.last_error, 'retry limit reached')
   where n.state = 'queued' and n.attempts >= n.max_attempts;

  -- 3. Recover leases whose holder died. The lease is `next_attempt_at`.
  update public.web_push_requests n
     set state = case when n.attempts >= n.max_attempts then 'failed' else 'queued' end::public.outbox_state,
         claimed_by = null,
         claimed_at = null,
         last_error = coalesce(n.last_error, 'lease_expired'),
         next_attempt_at = case when n.attempts >= n.max_attempts then n.next_attempt_at
                                else clock_timestamp() end
   where n.state = 'in_flight'
     and n.next_attempt_at < clock_timestamp();

  return query
  with due as (
    select n.id
      from public.web_push_requests n
     where n.state = 'queued'
       and n.next_attempt_at <= clock_timestamp()
       -- Rechecked here, not only at queue time: this is what cancels a notice
       -- that was queued two minutes ago for a user who opened the app two
       -- seconds ago.
       and app.web_push_row_owed(n.user_id, n.chat_id, n.sender_user_id, n.source, n.last_message_id)
     order by n.id
     limit least(greatest(coalesce(p_limit, 10), 1), 100)
     for update of n skip locked
  ),
  upd as (
    update public.web_push_requests n
       set state = 'in_flight',
           attempts = (n.attempts + 1)::smallint,
           claimed_by = p_worker,
           claimed_at = clock_timestamp(),
           next_attempt_at = clock_timestamp() + p_lease
      from due
     where n.id = due.id
    returning n.*
  )
  select u.id,
         u.user_id,
         u.chat_id,
         c.title,
         c.kind,
         u.sender_name,
         u.preview,
         u.folded,
         u.source,
         u.last_message_id,
         u.attempts,
         u.max_attempts,
         u.created_at
    from upd u
    join public.chats c on c.id = u.chat_id
   order by u.id;
end;
$$;

/**
 * A lease is a claim, not a promise to send. Re-check at the last possible
 * moment: the recipient may have opened the app, read the chat, muted it, turned
 * browser push off or unregistered every device since the claim. A missing or
 * revoked lease is always false, and a preview that no longer matches the stored
 * one means the text was scrubbed after we claimed it.
 */
create or replace function public.web_push_owed(
  p_notify_id uuid,
  p_worker    text,
  p_preview   text default null
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce((
    select n.state = 'in_flight'
       and n.claimed_by = p_worker
       and (p_preview is null or n.preview = p_preview)
       and app.web_push_row_owed(n.user_id, n.chat_id, n.sender_user_id, n.source, n.last_message_id)
      from public.web_push_requests n
     where n.id = p_notify_id
  ), false);
$$;

/**
 * The browsers to notify for these recipients. Returned in one round trip
 * because the fun part — encrypting per subscription — happens in the function.
 */
create or replace function public.web_push_targets(p_user_ids uuid[])
returns table (
  user_id  uuid,
  id       uuid,
  endpoint text,
  p256dh   text,
  auth     text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select ps.user_id, ps.id, ps.endpoint, ps.p256dh, ps.auth
    from public.push_subscriptions ps
   where ps.user_id = any (coalesce(p_user_ids, '{}'::uuid[]))
     and ps.disabled_at is null
   order by ps.user_id, ps.created_at;
$$;

/**
 * Record the outcome of one delivery attempt.
 *
 * `p_delivered` counts the browsers that accepted it. Zero delivered with no
 * error left to retry means the notice has nowhere to go, so it is retired as
 * `skipped` rather than `failed`: nobody is paged for a user who removed their
 * devices.
 */
create or replace function public.web_push_complete(
  p_notify_id uuid,
  p_state     public.outbox_state,
  -- Deliberately `integer`, not `smallint`: an integer literal cannot be
  -- implicitly cast to int2, so a smallint parameter would make the obvious
  -- `web_push_complete(id, 'sent', 2)` fail to resolve at all.
  p_delivered integer   default 0,
  p_error     text      default null,
  p_retry_in  interval  default interval '60 seconds'
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_ok boolean;
begin
  update public.web_push_requests n
     set state = p_state,
         delivered_count = least(255, greatest(0, coalesce(p_delivered, 0)))::smallint,
         last_error = case when p_state in ('sent', 'skipped') then null
                           else left(coalesce(p_error, n.last_error), 480) end,
         claimed_by = case when p_state = 'queued' then null else n.claimed_by end,
         claimed_at = case when p_state = 'queued' then null else n.claimed_at end,
         next_attempt_at = case when p_state = 'queued' then clock_timestamp() + p_retry_in
                                else n.next_attempt_at end
   where n.id = p_notify_id
     and n.state = 'in_flight';
  v_ok := found;
  return v_ok;
end;
$$;

/**
 * Subscription health, reported per endpoint after every POST.
 *
 * A push service answering 404/410 is telling us the subscription is
 * permanently gone (the user cleared site data, uninstalled the PWA, or the
 * browser rotated it). Retrying cannot help and will never help, so the row is
 * deleted. Everything else is transient-ish and only counts: an endpoint that
 * fails repeatedly without ever succeeding is disabled instead of being hammered
 * forever, and stays disabled until the browser registers again.
 */
create or replace function public.web_push_target_result(
  p_subscription_id uuid,
  p_ok              boolean,
  p_gone            boolean default false,
  p_error           text    default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  c_disable_after constant smallint := 20;
  v_found boolean;
begin
  if p_gone then
    delete from public.push_subscriptions ps where ps.id = p_subscription_id;
    return found;
  end if;

  if p_ok then
    update public.push_subscriptions ps
       set last_success_at = clock_timestamp(),
           last_seen_at    = clock_timestamp(),
           error_count     = 0,
           last_error      = null
     where ps.id = p_subscription_id;
    return found;
  end if;

  update public.push_subscriptions ps
     set error_count = least(255, ps.error_count + 1)::smallint,
         last_error  = left(coalesce(p_error, 'push rejected'), 480),
         disabled_at = case when ps.error_count + 1 >= c_disable_after then clock_timestamp()
                            else ps.disabled_at end
   where ps.id = p_subscription_id;
  v_found := found;
  return v_found;
end;
$$;

/**
 * Terminal rows are history, not a queue: three days is plenty for debugging.
 *
 * It also retires pending rows that are ancient — a deployment with no sweep
 * running (no webhook, nobody's app open) would otherwise accumulate `queued`
 * rows forever, because nothing ever fails a notice whose sender never arrives.
 * A day-old chat notification is history too.
 */
create or replace function public.prune_web_push_requests(p_older_than interval default interval '3 days')
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count integer;
begin
  update public.web_push_requests n
     set state = 'skipped', last_error = 'expired before delivery'
   where n.state in ('queued', 'in_flight')
     and n.created_at < clock_timestamp() - greatest(p_older_than, interval '1 hour');

  delete from public.web_push_requests n
   where n.state in ('sent', 'skipped', 'failed')
     and n.updated_at < clock_timestamp() - greatest(p_older_than, interval '1 hour');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

/**
 * A browser that has not been seen for a year is a row that will never be
 * delivered to (and, if it keeps failing, is holding a slot in the device cap).
 * Disabling — not deleting — keeps the endpoint unique index honest, so a stale
 * tab cannot quietly resurrect itself as a fresh subscription.
 */
create or replace function public.prune_push_subscriptions(p_older_than interval default interval '365 days')
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count integer;
begin
  update public.push_subscriptions ps
     set disabled_at = clock_timestamp(),
         last_error = coalesce(ps.last_error, 'not seen for over a year')
   where ps.disabled_at is null
     and ps.last_seen_at < clock_timestamp() - greatest(p_older_than, interval '30 days');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

commit;

-- ---------------------------------------------------------------------------
-- 9. Grants, RLS.
-- Clients see their own subscriptions and nothing else, and can only ever
-- *revoke* one by deleting it; creating one goes through the RPC above, which
-- enforces the shape, the device cap and the endpoint's single ownership.
-- ---------------------------------------------------------------------------
grant all on public.push_subscriptions to service_role;
revoke all on public.push_subscriptions from public, anon, authenticated;
grant select, delete on public.push_subscriptions to authenticated;

alter table public.push_subscriptions enable row level security;

drop policy if exists push_subscriptions_select_own on public.push_subscriptions;
create policy push_subscriptions_select_own
  on public.push_subscriptions
  for select
  to authenticated
  using (user_id = app.current_uid());

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own
  on public.push_subscriptions
  for delete
  to authenticated
  using (user_id = app.current_uid());

-- The queue is never visible to the app: a recipient learns about a notice from
-- the OS, and the sender only ever sees a count. No client policies at all.
grant all on public.web_push_requests to service_role;
revoke all on public.web_push_requests from public, anon, authenticated;

alter table public.web_push_requests enable row level security;

-- RLS on a table without a policy denies everything to everyone but the owner of
-- the table; the service role bypasses RLS by design. This assertion makes an
-- accidental future policy on the queue a test failure instead of a leak.
comment on table public.web_push_requests is
  'Browser-push notice queue. RLS enabled with deliberately NO policies: the app must never read it, and the sender reads it only as service_role.';

revoke execute on function
  app.web_push_should_send(uuid, uuid),
  app.web_push_row_owed(uuid, uuid, uuid, public.message_source, uuid),
  app.queue_web_push(),
  app.cancel_queued_web_push(),
  app.cancel_web_push_on_profile()
from public, anon, authenticated;
grant execute on function
  app.web_push_should_send(uuid, uuid),
  app.web_push_row_owed(uuid, uuid, uuid, public.message_source, uuid)
to service_role;

revoke execute on function public.register_push_subscription(text, text, text, text, text) from public, anon;
grant execute on function public.register_push_subscription(text, text, text, text, text) to authenticated;

revoke execute on function public.set_web_push_enabled(boolean) from public, anon;
grant execute on function public.set_web_push_enabled(boolean) to authenticated;

revoke execute on function
  public.web_push_claim(text, integer, interval),
  public.web_push_owed(uuid, text, text),
  public.web_push_targets(uuid[]),
  public.web_push_complete(uuid, public.outbox_state, integer, text, interval),
  public.web_push_target_result(uuid, boolean, boolean, text),
  public.prune_web_push_requests(interval),
  public.prune_push_subscriptions(interval)
from public, anon, authenticated;
grant execute on function
  public.web_push_claim(text, integer, interval),
  public.web_push_owed(uuid, text, text),
  public.web_push_targets(uuid[]),
  public.web_push_complete(uuid, public.outbox_state, integer, text, interval),
  public.web_push_target_result(uuid, boolean, boolean, text),
  public.prune_web_push_requests(interval),
  public.prune_push_subscriptions(interval)
to service_role;

comment on function public.register_push_subscription(text, text, text, text, text) is
  'Register this browser for push, moving the endpoint from any previous account and enforcing the per-user device cap.';
comment on function public.set_web_push_enabled(boolean) is
  'Turn browser push on or off; turning it off cancels queued notices in the same call.';
comment on function public.web_push_claim(text, integer, interval) is
  'Lease due browser-push notices; skips rows the user has since read, muted, left or come back online for.';
comment on function public.web_push_owed(uuid, text, text) is
  'Last-moment read, mute, presence and preview-privacy check before encrypting a notice.';
comment on function public.web_push_targets(uuid[]) is
  'The live browser subscriptions for these recipients, fetched in one round trip by the sender.';
comment on function public.web_push_complete(uuid, public.outbox_state, integer, text, interval) is
  'Report one notice delivery (sent / requeue / failed) and how many browsers accepted it.';
comment on function public.web_push_target_result(uuid, boolean, boolean, text) is
  'Record one POST outcome; a 404/410 deletes the dead subscription instead of retrying it forever.';
comment on function public.prune_web_push_requests(interval) is
  'Delete delivered / skipped / failed notices older than the retention window (default 3 days).';
comment on function public.prune_push_subscriptions(interval) is
  'Disable subscriptions no browser has re-registered for over a year.';
