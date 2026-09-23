-- =============================================================================
-- 00009_grants_and_introspection.sql
-- Massanger — least-privilege grants + PostgREST/OpenAPI descriptions.
--
-- Supabase's hosted projects ship default privileges for `public`; they are
-- restated here explicitly so a self-hosted project (or a bare Postgres used
-- by CI) ends up with *exactly* these rights and nothing more.
-- =============================================================================

create schema if not exists extensions;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema app  to anon, authenticated, service_role;

-- The bridge / edge functions authenticate as service_role. Supabase grants
-- `all` on public to it through default privileges; self-hosted projects do
-- not always, so restate it — least privilege still holds because the client
-- roles below only get the narrow list further down.
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant usage on schema storage to service_role;
grant all on all tables in schema storage to service_role;

-- Clients never see the bridge internals or the credential tables.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon, authenticated;

grant select on public.directory to anon, authenticated;

grant select, update on public.profiles              to authenticated;
grant select, insert, update      on public.chats               to authenticated;
grant select, update              on public.chat_participants   to authenticated;
grant select, insert, update      on public.messages            to authenticated;
grant select, insert              on public.message_reads       to authenticated;
grant select, insert, update      on public.telegram_accounts   to authenticated;
grant select, insert, update, delete on public.telegram_link_requests to authenticated;
grant select, update              on public.telegram_chats      to authenticated;
grant select                      on public.telegram_peers      to authenticated;
grant select                      on public.telegram_outbox     to authenticated;

-- Nothing is ever granted to `anon` except the public directory view.
grant select on public.directory to anon;

-- Defence in depth: these three are revoked even from `authenticated`, on top
-- of having no RLS policy. Supabase grants `public` tables to the client roles
-- by default, so say it out loud in the other direction too.
revoke all on public.google_credentials   from public, anon, authenticated;
revoke all on public.eligibility_checks   from public, anon, authenticated;
revoke all on public.telegram_inbox_events from public, anon, authenticated;
revoke all on public.telegram_link_requests from anon;

-- ---------------------------------------------------------------------------
-- Functions: RLS helpers must be executable by every role (they are called
-- while policies are evaluated); app RPCs only by the client roles; bridge
-- RPCs and credential bookkeeping only by the service role.
-- ---------------------------------------------------------------------------
grant execute on all functions in schema app to anon, authenticated, service_role;

grant execute on function
  public.chat_feed(uuid, uuid, integer),
  public.chat_summaries(text, integer),
  public.search_messages(text, uuid, integer),
  public.send_message(uuid, public.message_kind, text, jsonb, uuid, uuid),
  public.create_direct_chat(uuid, text),
  public.mark_chat_read(uuid),
  public.mark_messages_delivered(uuid[]),
  public.delete_message(uuid),
  public.retry_message(uuid),
  public.enqueue_telegram_outbox(uuid[]),
  public.heartbeat(),
  public.unread_total(),
  public.update_profile(text, text, text, text),
  public.eligibility_status(),
  public.telegram_link_state(),
  public.telegram_link_start(jsonb, boolean),
  public.telegram_link_submit(uuid, jsonb),
  public.telegram_link_cancel(uuid),
  public.telegram_unlink(),
  public.telegram_set_preferences(public.sync_direction, boolean, boolean, boolean),
  public.telegram_set_chat_sync(uuid, public.sync_direction)
to authenticated;

revoke execute on function
  public.bridge_claim_link_request(text, interval),
  public.bridge_link_progress(uuid, public.link_request_status, text, text, text, text, public.telegram_auth_state, text),
  public.bridge_link_complete(uuid, bigint, text, text, text, text, text, integer),
  public.bridge_account_context(uuid),
  public.bridge_set_account_state(uuid, public.telegram_auth_state, text, text, text, text, boolean),
  public.bridge_upsert_peer(uuid, bigint, text, text, text, text, boolean),
  public.bridge_resolve_chat(uuid, bigint, text, text, bigint, text, text, text, text, boolean),
  public.bridge_ingest_message(jsonb),
  public.bridge_update_delivery(jsonb),
  public.bridge_claim_outbox(text, uuid, integer, interval),
  public.bridge_complete_outbox(bigint, public.outbox_state, bigint, text, interval),
  public.bridge_fail_pending_sends(uuid, text),
  public.bridge_record_event(jsonb),
  public.record_eligibility_check(jsonb)
from public, anon, authenticated;

grant execute on function
  public.bridge_claim_link_request(text, interval),
  public.bridge_link_progress(uuid, public.link_request_status, text, text, text, text, public.telegram_auth_state, text),
  public.bridge_link_complete(uuid, bigint, text, text, text, text, text, integer),
  public.bridge_account_context(uuid),
  public.bridge_set_account_state(uuid, public.telegram_auth_state, text, text, text, text, boolean),
  public.bridge_upsert_peer(uuid, bigint, text, text, text, text, boolean),
  public.bridge_resolve_chat(uuid, bigint, text, text, bigint, text, text, text, text, boolean),
  public.bridge_ingest_message(jsonb),
  public.bridge_update_delivery(jsonb),
  public.bridge_claim_outbox(text, uuid, integer, interval),
  public.bridge_complete_outbox(bigint, public.outbox_state, bigint, text, interval),
  public.bridge_fail_pending_sends(uuid, text),
  public.bridge_record_event(jsonb),
  public.record_eligibility_check(jsonb)
to service_role;

-- ---------------------------------------------------------------------------
-- Comments surfaced in the PostgREST OpenAPI spec (nice DX for the Dart codegen
-- and for anyone reading the API in the dashboard).
-- ---------------------------------------------------------------------------
comment on function public.chat_feed(uuid, uuid, integer) is
  'Paged message window for one chat (newest first, pass `p_before_id` to page back).';
comment on function public.chat_summaries(text, integer) is
  'Home screen: chat list with preview, unread badge, peer presence and Telegram mirror state. p_query drives the search bar.';
comment on function public.send_message(uuid, public.message_kind, text, jsonb, uuid, uuid) is
  'Send text/image/voice. Idempotent on p_client_message_id. Enqueues Telegram forwarding in the same transaction.';
comment on function public.eligibility_status() is
  'Google-account-age gate state: pending_verification | active | restricted | banned | deactivated.';
comment on function public.telegram_link_start(jsonb, boolean) is
  'Start the TDLib authorization handshake (sealed phone number, or QR).';
comment on function public.telegram_link_submit(uuid, jsonb) is
  'Feed the handshake with the sealed code / password envelope produced by the telegram-link edge function.';
comment on function public.mark_messages_delivered(uuid[]) is
  'Client ack that turns a single tick into a double grey tick.';
