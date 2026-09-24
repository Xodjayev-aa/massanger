-- =============================================================================
-- 00012_self_push.sql
-- MessengerX — offline notices: the queue behind "Telegram-style" delivery.
--
-- The product has no FCM/APNs budget (APNs alone needs Apple's USD 99/yr
-- program), so a message that arrives while the recipient is away is pushed into
-- *their own* Telegram Saved Messages by the bridge — a channel the user already
-- paid for, that already works on iOS, Android and desktop, and that this worker
-- already owns. The app complements it with local banners while it is alive
-- (lib/app/incoming_notices.dart), which is why nothing here talks to a device
-- token.
--
-- The rules the queue encodes (see docs/runbook.md §10):
--   • offline only — `profiles.last_seen_at` older than 90 s. The app heartbeats
--     every 45 s while foregrounded, so two missed beats means "away".
--   • never twice — traffic that came *from* Telegram into a chat the recipient
--     already mirrors is not re-announced: their own Telegram just buzzed.
--   • folded — one open row per (user, chat); a burst becomes "+N more" instead
--     of N notifications, exactly like a chat stack.
--   • cancelled — reading, muting, leaving, coming back online or switching the
--     preference off all drop a queued row before it can be delivered.
--   • preview-free — `push_preview = false` never stores message text at all, so
--     the notice survives even on a shared/locked screen.
--
-- Delivery is the bridge's job: `bridge_claim_notify()` leases rows, the session
-- sends one text into Saved Messages, and `bridge_complete_notify()` records the
-- outcome plus the discovered chat id (Saved Messages == the user's own id on
-- Telegram, but the value Telegram reports is cached rather than assumed).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Preferences.
-- Both live on `profiles` (not `telegram_accounts`) because they describe how the
-- *person* wants to be reached; the Telegram session is only the transport. They
-- are deliberately absent from `app.guard_profile_update()`'s protected list, so
-- the client may also write them directly — `set_push_preferences()` below is the
-- ergonomic path (it cancels queued work in the same transaction).
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists push_telegram boolean not null default true,
  add column if not exists push_preview  boolean not null default true;

comment on column public.profiles.push_telegram is
  'Offline notices: push into my own Telegram Saved Messages when I am away.';
comment on column public.profiles.push_preview is
  'Offline notices: include the sender + a short preview. Off means "MessengerX · new message".';

-- ---------------------------------------------------------------------------
-- 2. The Saved Messages chat id, learned once per account.
-- Bridge-managed, so it joins the columns a client may not write: the guard
-- function is replaced with the same list plus this one (00005 owns the trigger).
-- ---------------------------------------------------------------------------
alter table public.telegram_accounts
  add column if not exists self_chat_id bigint;

comment on column public.telegram_accounts.self_chat_id is
  'Cached Telegram chat id of this account''s Saved Messages, learned from the first notice send.';

create or replace function app.guard_telegram_account_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if app.is_service_role() then
    return new;
  end if;

  if new.user_id is distinct from old.user_id
     or new.tg_user_id is distinct from old.tg_user_id
     or new.tg_username is distinct from old.tg_username
     or new.display_name is distinct from old.display_name
     or new.phone_country_code is distinct from old.phone_country_code
     or new.auth_state is distinct from old.auth_state
     or new.auth_step_note is distinct from old.auth_step_note
     or new.api_id is distinct from old.api_id
     or new.session_ref is distinct from old.session_ref
     or new.login_token_enc is distinct from old.login_token_enc
     or new.worker_id is distinct from old.worker_id
     or new.self_chat_id is distinct from old.self_chat_id
     or new.last_sync_at is distinct from old.last_sync_at
     or new.last_error is distinct from old.last_error
     or new.last_error_at is distinct from old.last_error_at
     or new.linked_at is distinct from old.linked_at
     or new.unlinked_at is distinct from old.unlinked_at
  then
    raise exception 'the Telegram session is managed by the bridge, not by the client'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. notify_requests — one *open* row per (user, chat), plus a short terminal
-- history for the bridge's own debugging. Reuses `outbox_state` so the queue
-- vocabulary (queued / in_flight / sent / failed / skipped) stays one language
-- across both worker queues.
-- ---------------------------------------------------------------------------
create table if not exists public.notify_requests (
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
  tg_self_chat_id bigint,
  tg_message_id   bigint,
  claimed_by      text,
  claimed_at      timestamptz,
  next_attempt_at timestamptz not null default clock_timestamp(),
  last_error      text,
  created_at      timestamptz not null default clock_timestamp(),
  updated_at      timestamptz not null default clock_timestamp()
);

comment on table public.notify_requests is
  'Offline-notice queue: at most one open row per (user, chat), delivered into that user''s own Telegram Saved Messages.';
comment on column public.notify_requests.folded is
  'How many messages this one notice stands for; rendered as "+N more".';

-- Folding: the upsert below targets exactly this index.
create unique index if not exists notify_requests_open_uniq
  on public.notify_requests (user_id, chat_id)
  where state = 'queued';

create index if not exists notify_requests_claim_idx
  on public.notify_requests (next_attempt_at, id)
  where state in ('queued', 'in_flight');

create index if not exists notify_requests_prune_idx
  on public.notify_requests (updated_at)
  where state in ('sent', 'skipped', 'failed');

create index if not exists notify_requests_user_idx
  on public.notify_requests (user_id, state);

drop trigger if exists notify_requests_touch on public.notify_requests;
create trigger notify_requests_touch
  before update on public.notify_requests
  for each row execute function app.set_updated_at();

-- A new notice should wake a worker the same way a new outbox row does, so it
-- rides the existing channel rather than teaching the bridge a third one.
drop trigger if exists notify_requests_notify on public.notify_requests;
create trigger notify_requests_notify
  after insert on public.notify_requests
  for each row execute function app.notify_bridge('messengerx_outbox');

-- ---------------------------------------------------------------------------
-- 4. The rules, as functions (SECURITY DEFINER: they read other people's
-- presence and mappings, and are called from triggers that run as the writer).
-- ---------------------------------------------------------------------------

/** Is this user away, reachable and willing? */
create or replace function app.notify_should_send(p_user uuid, p_sender uuid)
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
         join public.telegram_accounts ta on ta.user_id = pr.id
        where pr.id = p_user
          and pr.deleted_at is null
          and pr.access_state = 'active'
          and pr.push_telegram
          -- Two missed 45 s heartbeats: the app is backgrounded or killed.
          and (pr.last_seen_at is null or pr.last_seen_at < clock_timestamp() - interval '90 seconds')
          -- The notice travels out through this account's own session.
          and ta.auth_state = 'linked'
          and ta.sync_direction <> 'off'
     );
$$;

/**
 * Did the user's own Telegram already deliver this? Traffic mirrored *from*
 * Telegram into a chat the recipient mirrors back is already buzzing on their
 * phone — announcing it again is the one duplicate users notice instantly.
 */
create or replace function app.notify_already_buzzed(
  p_user   uuid,
  p_chat   uuid,
  p_source public.message_source
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p_source = 'telegram'::public.message_source
     and exists (
       select 1
         from public.telegram_chats tc
        where tc.owner_user_id = p_user
          and tc.chat_id = p_chat
          and tc.sync_direction in ('both', 'from_telegram')
     );
$$;

/** One line of context, or nothing at all when previews are off. */
create or replace function app.notify_body_preview(
  p_message      public.messages,
  p_with_preview boolean default true
)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when not coalesce(p_with_preview, true) then ''
    else left(
      btrim(
        regexp_replace(
          coalesce(
            nullif(btrim(p_message.body), ''),
            nullif(btrim(coalesce(p_message.media ->> 'caption', '')), ''),
            -- Same wording as the chat-list preview (00006), so a notice reads
            -- like the app it came from.
            case p_message.kind::text
              when 'image' then 'Photo'
              when 'voice' then 'Voice message'
              else null
            end,
            ''
          ),
          E'[\n\r]+', ' ', 'g'
        )
      ),
      140
    )
  end;
$$;

/**
 * Still owed? Re-checked at claim time, which is what makes "the user opened the
 * app 2 s ago" cancel a notice that was queued 2 min ago.
 */
create or replace function app.notify_row_owed(
  p_user uuid,
  p_chat uuid,
  p_sender uuid,
  p_source public.message_source default 'app'
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select app.notify_should_send(p_user, p_sender)
     and not app.notify_already_buzzed(p_user, p_chat, p_source)
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
-- Runs after `app.after_message_write()` (trigger names sort that way), so
-- unread_count is already correct when a row is created.
-- ---------------------------------------------------------------------------
create or replace function app.queue_self_push()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_part    record;
  v_preview text;
begin
  if new.kind = 'system' or new.deleted_at is not null then
    return coalesce(new, old);
  end if;

  if tg_op = 'UPDATE' then
    if old.deleted_at is not null and new.deleted_at is null then
      null;  -- a restored message is a new arrival: fall through and queue it
    elsif new.body is distinct from old.body or new.kind is distinct from old.kind then
      -- An edit refreshes a notice that has not been delivered yet, but only for
      -- people who asked for previews.
      update public.notify_requests n
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
      and app.notify_should_send(cp.user_id, new.sender_id)
      and not app.notify_already_buzzed(cp.user_id, new.chat_id, new.source)
  loop
    v_preview := app.notify_body_preview(new, v_part.push_preview);

    insert into public.notify_requests as n (
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
      clock_timestamp() + interval '3 seconds'
    )
    on conflict (user_id, chat_id) where state = 'queued'
    do update set
      folded          = least(999, n.folded + 1),
      preview         = excluded.preview,
      sender_user_id  = excluded.sender_user_id,
      sender_name     = excluded.sender_name,
      last_message_id = excluded.last_message_id,
      source          = excluded.source,
      -- Debounce for a short quiet window; without it a 3-second poll could
      -- send one Saved Messages bubble per message in a rapid conversation.
      next_attempt_at = clock_timestamp() + interval '3 seconds',
      attempts        = 0,
      claimed_by      = null,
      claimed_at      = null,
      last_error      = null;
  end loop;

  return coalesce(new, old);
end;
$$;

drop trigger if exists messages_queue_notice on public.messages;
create trigger messages_queue_notice
  after insert or update on public.messages
  for each row execute function app.queue_self_push();

-- ---------------------------------------------------------------------------
-- 6. Cancellation.
-- Reading (app or Telegram), muting and leaving all funnel through
-- chat_participants, so one trigger covers every "never mind" the user can
-- express. In-flight rows are not deleted: the claim sweep marks them skipped.
-- ---------------------------------------------------------------------------
create or replace function app.cancel_queued_notices()
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
    delete from public.notify_requests n
     where n.user_id = v_user
       and n.chat_id = v_chat
       and n.state = 'queued';
    -- A worker may have leased the row just before the read/mute. Mark it
    -- skipped: bridge_notice_owed will refuse it, and a late completion cannot
    -- turn it back into sent.
    update public.notify_requests n
       set state = 'skipped', last_error = 'read, muted or left'
     where n.user_id = v_user and n.chat_id = v_chat and n.state = 'in_flight';
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists chat_participants_cancel_notice on public.chat_participants;
create trigger chat_participants_cancel_notice
  after update or delete on public.chat_participants
  for each row execute function app.cancel_queued_notices();

create or replace function app.cancel_notices_on_profile()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if (new.push_telegram is false and old.push_telegram is true)
     or (new.access_state <> 'active' and old.access_state = 'active')
     or (new.deleted_at is not null and old.deleted_at is null)
     or (new.last_seen_at is not null
         and new.last_seen_at >= clock_timestamp() - interval '90 seconds'
         and (old.last_seen_at is null
              or old.last_seen_at < clock_timestamp() - interval '90 seconds'))
  then
    delete from public.notify_requests n
     where n.user_id = new.id
       and n.state = 'queued';
    update public.notify_requests n
       set state = 'skipped', last_error = 'profile changed'
     where n.user_id = new.id and n.state = 'in_flight';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_cancel_notices on public.profiles;
create trigger profiles_cancel_notices
  after update on public.profiles
  for each row execute function app.cancel_notices_on_profile();

-- ---------------------------------------------------------------------------
-- 7. Client RPC: the two switches on the Telegram screen.
-- ---------------------------------------------------------------------------
create or replace function public.set_push_preferences(
  p_push_telegram boolean default null,
  p_push_preview  boolean default null
)
returns jsonb
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

  update public.profiles p
     set push_telegram = coalesce(p_push_telegram, p.push_telegram),
         push_preview  = coalesce(p_push_preview, p.push_preview)
   where p.id = v_uid
  returning * into v_row;

  if not found then
    raise exception 'profile % is missing', v_uid using errcode = '42501';
  end if;

  -- A notice queued under the old preference is not owed under the new one.
  if p_push_preview is false then
    update public.notify_requests n
       set preview = ''
     where n.user_id = v_uid and n.state = 'queued' and n.preview <> '';
  end if;

  if p_push_telegram is false then
    delete from public.notify_requests n
     where n.user_id = v_uid and n.state = 'queued';
  end if;

  return jsonb_build_object(
    'push_telegram', v_row.push_telegram,
    'push_preview',  v_row.push_preview
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Bridge RPCs.
-- ---------------------------------------------------------------------------

/**
 * Lease a batch of notices for one worker. Rows the user has since read, muted or
 * come back online for are marked `skipped` first — in a separate statement,
 * because data-modifying CTEs share one snapshot and would otherwise hand out a
 * row they just cancelled.
 */
create or replace function public.bridge_claim_notify(
  p_worker text,
  p_owner  uuid     default null,
  p_limit  integer  default 10,
  p_lease  interval default interval '120 seconds'
)
returns table (
  notify_id       uuid,
  user_id         uuid,
  chat_id         uuid,
  sender_name     text,
  preview         text,
  folded          integer,
  tg_self_chat_id bigint,
  tg_user_id      bigint,
  session_ref     text,
  attempts        smallint,
  max_attempts    smallint,
  queued_at       timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.notify_requests n
     set state         = 'skipped',
         claimed_by    = null,
         claimed_at    = null,
         last_error    = 'no longer owed'
   where n.state = 'queued'
     and (p_owner is null or n.user_id = p_owner)
     and not app.notify_row_owed(n.user_id, n.chat_id, n.sender_user_id, n.source);

  update public.notify_requests n
     set state = case when n.attempts >= n.max_attempts then 'failed' else 'queued'
                 end::public.outbox_state,
         claimed_by = null,
         claimed_at = null,
         last_error = coalesce(n.last_error, 'lease_expired'),
         next_attempt_at = case when n.attempts >= n.max_attempts then n.next_attempt_at
                                else clock_timestamp() end
   where n.state = 'in_flight'
     and n.next_attempt_at < clock_timestamp();

  return query
  with picked as (
    select n.id
    from public.notify_requests n
    join public.telegram_accounts ta on ta.user_id = n.user_id
    join public.profiles pr          on pr.id = n.user_id
    where n.state = 'queued'
      and n.next_attempt_at <= clock_timestamp()
      and (p_owner is null or n.user_id = p_owner)
      and ta.auth_state = 'linked'
      and ta.sync_direction <> 'off'
      and ta.tg_user_id is not null
      and pr.access_state = 'active'
      and pr.deleted_at is null
      and pr.push_telegram
    order by n.id
    limit least(greatest(coalesce(p_limit, 10), 1), 100)
    for update of n skip locked
  ),
  upd as (
    update public.notify_requests n
       set state = 'in_flight',
           attempts = (n.attempts + 1)::smallint,
           claimed_by = p_worker,
           claimed_at = clock_timestamp(),
           next_attempt_at = clock_timestamp() + p_lease,
           tg_self_chat_id = coalesce(
             n.tg_self_chat_id,
             (select ta.self_chat_id from public.telegram_accounts ta where ta.user_id = n.user_id)
           )
      from picked
     where n.id = picked.id
    returning n.*
  )
  select u.id,
         u.user_id,
         u.chat_id,
         u.sender_name,
         u.preview,
         u.folded,
         -- Saved Messages is a private chat with yourself; the cached id wins,
         -- the own user id is the documented fallback.
         coalesce(u.tg_self_chat_id, ta.self_chat_id, ta.tg_user_id),
         ta.tg_user_id,
         ta.session_ref,
         u.attempts,
         u.max_attempts,
         u.created_at
  from upd u
  join public.telegram_accounts ta on ta.user_id = u.user_id
  order by u.id;
end;
$$;

/**
 * A lease is a claim, not a promise to send. Check at the last possible moment
 * before TDLib: a recipient may have opened, read, muted, unlinked, or disabled
 * push after the claim. A missing/revoked lease is always false.
 */
create or replace function public.bridge_notice_owed(p_notify_id uuid, p_worker text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce((
    select n.state = 'in_flight'
       and n.claimed_by = p_worker
       and app.notify_row_owed(n.user_id, n.chat_id, n.sender_user_id, n.source)
      from public.notify_requests n
     where n.id = p_notify_id
  ), false);
$$;

/**
 * Record the outcome of one delivery. `p_self_chat_id` caches the chat id
 * Telegram actually reported; `p_reset_self_chat` throws a bad cache away (the
 * next attempt falls back to the own user id).
 */
create or replace function public.bridge_complete_notify(
  p_notify_id         uuid,
  p_state             public.outbox_state,
  p_tg_message_id     bigint   default null,
  p_self_chat_id      bigint   default null,
  p_reset_self_chat   boolean  default false,
  p_error             text     default null,
  p_retry_in          interval default interval '30 seconds'
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_ok    boolean;
  v_owner uuid;
begin
  update public.notify_requests n
     set state = p_state,
         tg_message_id = coalesce(p_tg_message_id, n.tg_message_id),
         tg_self_chat_id = case
                             when p_reset_self_chat then null
                             else coalesce(p_self_chat_id, n.tg_self_chat_id)
                           end,
         last_error = case when p_state in ('sent', 'skipped') then null
                           else left(coalesce(p_error, n.last_error), 480) end,
         claimed_by = case when p_state = 'queued' then null else n.claimed_by end,
         claimed_at = case when p_state = 'queued' then null else n.claimed_at end,
         next_attempt_at = case when p_state = 'queued' then clock_timestamp() + p_retry_in
                                else n.next_attempt_at end
   where n.id = p_notify_id
     and n.state = 'in_flight'
  returning n.user_id into v_owner;
  v_ok := found;

  if v_ok and p_self_chat_id is not null and not p_reset_self_chat then
    update public.telegram_accounts ta
       set self_chat_id = p_self_chat_id
     where ta.user_id = v_owner
       and ta.self_chat_id is distinct from p_self_chat_id;
  end if;

  if v_ok and p_reset_self_chat then
    update public.telegram_accounts ta
       set self_chat_id = null
     where ta.user_id = v_owner
       and ta.self_chat_id is not null;
  end if;

  return v_ok;
end;
$$;

/** A revoked session cannot deliver anything: stop the whole owner's queue. */
create or replace function public.bridge_fail_notify(p_owner uuid, p_error text)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count integer;
begin
  update public.notify_requests n
     set state = 'failed',
         claimed_by = null,
         claimed_at = null,
         last_error = left(coalesce(p_error, 'delivery failed'), 480)
   where n.user_id = p_owner
     and n.state in ('queued', 'in_flight');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

/** Terminal rows are history, not a queue: three days is plenty for debugging. */
create or replace function public.prune_notify_requests(p_older_than interval default interval '3 days')
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count integer;
begin
  delete from public.notify_requests n
   where n.state in ('sent', 'skipped', 'failed')
     and n.updated_at < clock_timestamp() - greatest(p_older_than, interval '1 hour');
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

commit;

-- ---------------------------------------------------------------------------
-- 9. Grants, RLS, Realtime, OpenAPI comments.
-- Clients never see the queue: they learn about a notice from the unread badge
-- (and, while the app is alive, from the local banner), so RLS is on with *no*
-- policies and the table grants stay with the service role.
-- ---------------------------------------------------------------------------
grant all on public.notify_requests to service_role;
revoke all on public.notify_requests from public, anon, authenticated;

grant execute on function public.set_push_preferences(boolean, boolean) to authenticated;

grant execute on function
  public.bridge_claim_notify(text, uuid, integer, interval),
  public.bridge_notice_owed(uuid, text)
to service_role;
grant execute on function
  public.bridge_complete_notify(uuid, public.outbox_state, bigint, bigint, boolean, text, interval),
  public.bridge_fail_notify(uuid, text),
  public.prune_notify_requests(interval)
to service_role;

revoke execute on function
  public.bridge_claim_notify(text, uuid, integer, interval),
  public.bridge_notice_owed(uuid, text),
  public.bridge_complete_notify(uuid, public.outbox_state, bigint, bigint, boolean, text, interval),
  public.bridge_fail_notify(uuid, text),
  public.prune_notify_requests(interval)
from public, anon, authenticated;

alter table public.notify_requests enable row level security;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notify_requests'
     ) then
    begin
      execute 'alter publication supabase_realtime add table public.notify_requests';
    exception when others then
      raise notice 'could not add public.notify_requests to supabase_realtime: %', sqlerrm;
    end;
  end if;
end
$$;

comment on function public.set_push_preferences(boolean, boolean) is
  'Offline notices: turn the Telegram push and/or the message preview on or off. Cancels queued work in the same call.';
comment on function public.bridge_claim_notify(text, uuid, integer, interval) is
  'Lease offline notices for delivery; skips rows the user has since read, muted or come back online for.';
comment on function public.bridge_notice_owed(uuid, text) is
  'Last-moment read, mute and presence check on a worker-leased notice before sending to Telegram.';
comment on function public.bridge_complete_notify(uuid, public.outbox_state, bigint, bigint, boolean, text, interval) is
  'Report one notice delivery (sent / requeue / failed) and cache the Saved Messages chat id Telegram reported.';
comment on function public.bridge_fail_notify(uuid, text) is
  'Fail every queued notice for an account whose Telegram session was revoked.';
comment on function public.prune_notify_requests(interval) is
  'Delete delivered / skipped / failed notices older than the retention window (default 3 days).';
