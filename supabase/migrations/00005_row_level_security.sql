-- =============================================================================
-- 00005_row_level_security.sql
-- Massanger — RLS + column-level guards.
--
-- Two ideas carry this file:
--
-- 1. Row security answers "may this user see/touch this row".
-- 2. Column security answers "which fields may they touch". Postgres has no
--    per-column RLS, so updates are narrowed by BEFORE UPDATE guard triggers
--    that compare OLD vs NEW and raise 42501 for anything server-managed.
--    Both the client role and the bridge (service_role) go through these
--    triggers; service_role is short-circuited inside them.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Guard triggers (column whitelists)
-- ---------------------------------------------------------------------------
create or replace function app.guard_message_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if app.is_service_role() then
    return new;
  end if;

  -- A client may only: advance its own delivery state, or soft-delete its own
  -- message. Everything else belongs to the bridge / edge functions.
  if new.kind is distinct from old.kind
     or new.body is distinct from old.body
     or new.media is distinct from old.media
     or new.reply_to_id is distinct from old.reply_to_id
     or new.chat_id is distinct from old.chat_id
     or new.sender_id is distinct from old.sender_id
     or new.source is distinct from old.source
     or new.tg_message_id is distinct from old.tg_message_id
     or new.tg_send_id is distinct from old.tg_send_id
  then
    raise exception 'messages are append-only for clients (edits go through delete + resend)'
      using errcode = '42501';
  end if;

  if (new.state is distinct from old.state or new.failure_code is distinct from old.failure_code)
     and old.sender_id is distinct from app.current_uid()
  then
    raise exception 'only the sender may change delivery state'
      using errcode = '42501';
  end if;

  if new.deleted_at is distinct from old.deleted_at and old.sender_id is distinct from app.current_uid() then
    raise exception 'only the sender may delete a message'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists messages_guard_update on public.messages;
create trigger messages_guard_update
  before update on public.messages
  for each row execute function app.guard_message_update();

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

drop trigger if exists telegram_accounts_guard_update on public.telegram_accounts;
create trigger telegram_accounts_guard_update
  before update on public.telegram_accounts
  for each row execute function app.guard_telegram_account_update();

create or replace function app.guard_link_request_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if app.is_service_role() then
    return new;
  end if;

  -- The client may only feed the handshake (code / password) into an open
  -- request, and only its own.
  if new.user_id <> old.user_id
     or new.status is distinct from old.status
     or new.step is distinct from old.step
     or new.kind is distinct from old.kind
     or new.qr_code is distinct from old.qr_code
     or new.error is distinct from old.error
     or new.claimed_by is distinct from old.claimed_by
     or new.claimed_at is distinct from old.claimed_at
  then
    raise exception 'only the bridge may advance a link request'
      using errcode = '42501';
  end if;

  if old.status not in ('claimed', 'awaiting_user') then
    raise exception 'link request is not waiting for user input'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists telegram_link_requests_guard_update on public.telegram_link_requests;
create trigger telegram_link_requests_guard_update
  before update on public.telegram_link_requests
  for each row execute function app.guard_link_request_update();

-- Inserts from a client are normalized, never trusted: the row cannot arrive
-- already claimed, already succeeded, or carrying an unsealed credential.
create or replace function app.guard_link_request_insert()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if app.is_service_role() then
    return new;
  end if;

  if new.payload is not null and not app.valid_link_envelope(new.payload) then
    raise exception 'link payload must be a sealed credential envelope'
      using errcode = '42501';
  end if;

  new.user_id     := app.current_uid();
  new.status      := 'queued';
  new.step        := 'queued';
  new.kind        := coalesce(new.kind, 'link'::public.link_request_kind);
  new.claimed_by  := null;
  new.claimed_at  := null;
  new.completed_at := null;
  new.qr_code     := null;
  new.error       := null;
  new.session_ref := null;
  if new.kind = 'unlink' then
    new.payload := null;              -- nothing secret is needed to log out
  end if;
  if new.expires_at is null
     or new.expires_at > clock_timestamp() + interval '15 minutes' then
    new.expires_at := clock_timestamp() + interval '10 minutes';
  end if;

  return new;
end;
$$;

drop trigger if exists telegram_link_requests_guard_insert on public.telegram_link_requests;
create trigger telegram_link_requests_guard_insert
  before insert on public.telegram_link_requests
  for each row execute function app.guard_link_request_insert();

-- ---------------------------------------------------------------------------
-- Directory view: this is the ONLY way other people's identity data is read.
-- It exposes a safe column subset, so it is intentionally owned by the table
-- owner (views evaluate base-table RLS as the view owner — see Postgres docs),
-- while `public.profiles` itself stays own-row-only.
-- ---------------------------------------------------------------------------
create or replace view public.directory
with (security_barrier = false)
as
select p.id,
       p.username,
       p.username_norm,
       p.display_name,
       p.avatar_path,
       p.avatar_external_url,
       p.bio,
       p.telegram_username,
       (p.last_seen_at > clock_timestamp() - interval '5 minutes') as is_online,
       p.last_seen_at
from public.profiles p
where p.deleted_at is null;

comment on view public.directory is
  'Safe public projection of profiles (no email/phone/eligibility data).';

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere the client can reach.
--
-- Deliberately *not* `force row level security`: the tables are owned by the
-- migration role (`postgres`), which the SECURITY DEFINER helpers above run as.
-- Owner bypass is what makes `app.is_chat_member()` able to read
-- `chat_participants` without recursing into that table's own policy.
-- Client roles (anon/authenticated) never own the tables, so they are always
-- filtered; `service_role` carries BYPASSRLS in the Supabase default setup.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'public.profiles','public.chats','public.chat_participants','public.messages',
    'public.message_reads','public.telegram_accounts','public.telegram_link_requests',
    'public.telegram_chats','public.telegram_peers','public.telegram_outbox',
    'public.telegram_inbox_events','public.google_credentials','public.eligibility_checks'
  ]
  loop
    execute format('alter table %s enable row level security', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = (select app.current_uid()));

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select app.current_uid()))
  with check (id = (select app.current_uid()));

drop policy if exists profiles_delete_self on public.profiles;
create policy profiles_delete_self on public.profiles
  for delete to authenticated
  using (id = (select app.current_uid()));

-- ---------------------------------------------------------------------------
-- chats
-- ---------------------------------------------------------------------------
drop policy if exists chats_select_member on public.chats;
create policy chats_select_member on public.chats
  for select to authenticated
  using (app.is_chat_member(id, (select app.current_uid())));

drop policy if exists chats_insert_creator on public.chats;
create policy chats_insert_creator on public.chats
  for insert to authenticated
  with check (
    created_by = (select app.current_uid())
    and app.access_ok((select app.current_uid()))
    and (kind <> 'direct' or not is_telegram_mirror)
  );

drop policy if exists chats_update_member on public.chats;
create policy chats_update_member on public.chats
  for update to authenticated
  using (app.is_chat_member(id, (select app.current_uid())) and not is_telegram_mirror)
  with check (app.is_chat_member(id, (select app.current_uid())));

-- ---------------------------------------------------------------------------
-- chat_participants
-- ---------------------------------------------------------------------------
drop policy if exists participants_select_peer_of_my_chats on public.chat_participants;
create policy participants_select_peer_of_my_chats on public.chat_participants
  for select to authenticated
  using (
    app.is_chat_member(chat_id, (select app.current_uid()))
    or user_id = (select app.current_uid())
  );

-- Users may adjust their own notification/read state, nothing else.
drop policy if exists participants_update_self on public.chat_participants;
create policy participants_update_self on public.chat_participants
  for update to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
drop policy if exists messages_select_member on public.messages;
create policy messages_select_member on public.messages
  for select to authenticated
  using (
    app.is_chat_member(chat_id, (select app.current_uid()))
    and deleted_at is null
  );

-- Inserts are constrained hard: own messages, app source only, non-system, and
-- the account must be eligible. Note the absence of a `state` predicate: the
-- BEFORE INSERT trigger is what turns 'sending' into 'sent', and a WITH CHECK
-- policy is evaluated on the *final* row.
drop policy if exists messages_insert_own on public.messages;
create policy messages_insert_own on public.messages
  for insert to authenticated
  with check (
    sender_id = (select app.current_uid())
    and source = 'app'
    and kind <> 'system'
    and app.is_chat_member(chat_id, (select app.current_uid()))
    and app.sender_may_post((select app.current_uid()))
  );

drop policy if exists messages_update_own_state on public.messages;
create policy messages_update_own_state on public.messages
  for update to authenticated
  using (sender_id = (select app.current_uid()) and deleted_at is null)
  with check (sender_id = (select app.current_uid()));

-- ---------------------------------------------------------------------------
-- message_reads
-- ---------------------------------------------------------------------------
drop policy if exists message_reads_select_member on public.message_reads;
create policy message_reads_select_member on public.message_reads
  for select to authenticated
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_id
        and app.is_chat_member(m.chat_id, (select app.current_uid()))
    )
  );

drop policy if exists message_reads_insert_self on public.message_reads;
create policy message_reads_insert_self on public.message_reads
  for insert to authenticated
  with check (user_id = (select app.current_uid()));

-- ---------------------------------------------------------------------------
-- Telegram bridge: strictly owner-scoped
-- ---------------------------------------------------------------------------
drop policy if exists telegram_accounts_select_self on public.telegram_accounts;
create policy telegram_accounts_select_self on public.telegram_accounts
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists telegram_accounts_update_self on public.telegram_accounts;
create policy telegram_accounts_update_self on public.telegram_accounts
  for update to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

drop policy if exists telegram_accounts_insert_self on public.telegram_accounts;
create policy telegram_accounts_insert_self on public.telegram_accounts
  for insert to authenticated
  with check (user_id = (select app.current_uid()));

drop policy if exists link_requests_select_self on public.telegram_link_requests;
create policy link_requests_select_self on public.telegram_link_requests
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists link_requests_insert_self on public.telegram_link_requests;
create policy link_requests_insert_self on public.telegram_link_requests
  for insert to authenticated
  with check (
    user_id = (select app.current_uid())
    and app.access_ok(user_id)
  );

drop policy if exists link_requests_update_self on public.telegram_link_requests;
create policy link_requests_update_self on public.telegram_link_requests
  for update to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

drop policy if exists link_requests_delete_self on public.telegram_link_requests;
create policy link_requests_delete_self on public.telegram_link_requests
  for delete to authenticated
  using (user_id = (select app.current_uid()) and status in ('queued', 'awaiting_user'));

drop policy if exists telegram_chats_select_self on public.telegram_chats;
create policy telegram_chats_select_self on public.telegram_chats
  for select to authenticated
  using (owner_user_id = (select app.current_uid()));

drop policy if exists telegram_chats_update_sync_self on public.telegram_chats;
create policy telegram_chats_update_sync_self on public.telegram_chats
  for update to authenticated
  using (owner_user_id = (select app.current_uid()))
  with check (owner_user_id = (select app.current_uid()));

drop policy if exists telegram_peers_select_self on public.telegram_peers;
create policy telegram_peers_select_self on public.telegram_peers
  for select to authenticated
  using (owner_user_id = (select app.current_uid()));

drop policy if exists telegram_outbox_select_self on public.telegram_outbox;
create policy telegram_outbox_select_self on public.telegram_outbox
  for select to authenticated
  using (owner_user_id = (select app.current_uid()));

-- telegram_inbox_events / google_credentials / eligibility_checks: no client
-- policies at all ⇒ deny-by-default, service_role only. They stay readable for
-- the bridge because RLS is bypassed by the service role.
