-- =============================================================================
-- 00007_bridge_rpc.sql
-- Massanger — the contract the TDLib worker uses. Granted to service_role only.
--
-- Why RPCs instead of letting the worker write tables directly:
--   * one place owns the idempotency rules (tg_message_id / tg_send_id /
--     dedupe_key), so a worker restart mid-flight cannot duplicate a bubble;
--   * the echo of a message we forwarded is *reconciled* with the original, not
--     inserted twice;
--   * leases (`claimed_by` + `next_attempt_at`) give at-most-one-consumer
--     semantics with automatic reclaim of crashed workers;
--   * all of it runs inside one transaction, so the mirror chat, its
--     participant row and the message appear atomically for Realtime.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Link handshake
-- ---------------------------------------------------------------------------
create or replace function public.bridge_claim_link_request(
  p_worker text,
  p_lease  interval default interval '120 seconds'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_req   public.telegram_link_requests%rowtype;
  v_prof  public.profiles%rowtype;
  v_acc   public.telegram_accounts%rowtype;
begin
  -- Reclaim abandoned handshakes (crashed / restarted worker).
  update public.telegram_link_requests lr
     set status = 'queued', claimed_by = null, claimed_at = null,
         error = 'lease_expired'
   where lr.status = 'claimed'
     and lr.claimed_at < clock_timestamp() - p_lease;

  select * into v_req
  from public.telegram_link_requests lr
  where lr.expires_at > clock_timestamp()
    and (
      lr.status = 'queued'
      or (lr.status = 'awaiting_user' and lr.payload is not null)
    )
  order by lr.created_at
  limit 1
  for update of lr skip locked;

  if not found then
    return null;
  end if;

  update public.telegram_link_requests lr
     set status = 'claimed', claimed_by = p_worker, claimed_at = clock_timestamp()
   where lr.id = v_req.id;

  select * into v_prof from public.profiles p where p.id = v_req.user_id;
  select * into v_acc  from public.telegram_accounts a where a.user_id = v_req.user_id;

  return jsonb_build_object(
    'request_id', v_req.id,
    'kind',       v_req.kind::text,
    'step',       v_req.step,
    'user_id',    v_req.user_id,
    'payload',    v_req.payload,
    'session_ref', coalesce(v_req.session_ref, v_acc.session_ref, v_req.user_id::text),
    'profile',    jsonb_build_object(
                    'username',   v_prof.username,
                    'phone_e164', v_prof.phone_e164,
                    'email',      v_prof.google_email
                  ),
    'account',    jsonb_build_object(
                    'auth_state',  v_acc.auth_state::text,
                    'tg_user_id',  v_acc.tg_user_id,
                    'session_ref', v_acc.session_ref,
                    'login_token_enc', v_acc.login_token_enc,
                    'api_id',      v_acc.api_id
                  )
  );
end;
$$;

-- Progress report; always wipes the user's one-time input.
create or replace function public.bridge_link_progress(
  p_request_id uuid,
  p_status     public.link_request_status,
  p_step       text default null,
  p_qr_code    text default null,
  p_note       text default null,
  p_error      text default null,
  p_auth_state public.telegram_auth_state default null,
  p_session_ref text default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid;
begin
  update public.telegram_link_requests lr
     set status       = p_status,
         step         = coalesce(p_step, lr.step),
         qr_code      = coalesce(p_qr_code, lr.qr_code),
         error        = p_error,
         payload      = null,                      -- consume the OTP material
         session_ref  = coalesce(p_session_ref, lr.session_ref),
         completed_at = case when p_status in ('succeeded', 'failed', 'expired')
                             then clock_timestamp() else lr.completed_at end
   where lr.id = p_request_id
  returning lr.user_id into v_user;

  if v_user is null then
    return false;
  end if;

  update public.telegram_accounts ta
     set auth_state   = coalesce(p_auth_state, ta.auth_state),
         auth_step_note = coalesce(p_note, ta.auth_step_note),
         session_ref  = coalesce(p_session_ref, ta.session_ref),
         last_error   = p_error,
         last_error_at = case when p_error is not null then clock_timestamp() else ta.last_error_at end
   where ta.user_id = v_user;

  if p_status = 'expired' then
    update public.telegram_accounts ta
       set auth_state = 'unlinked', auth_step_note = null
     where ta.user_id = v_user
       and ta.linked_at is null;
  end if;

  return true;
end;
$$;

create or replace function public.bridge_link_complete(
  p_request_id    uuid,
  p_tg_user_id    bigint,
  p_tg_username   text default null,
  p_display_name  text default null,
  p_phone_cc      text default null,
  p_session_ref   text default null,
  p_login_token_enc text default null,
  p_api_id        integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid;
begin
  select lr.user_id into v_user from public.telegram_link_requests lr where lr.id = p_request_id;
  if v_user is null then
    raise exception 'unknown link request %', p_request_id using errcode = 'P0002';
  end if;

  insert into public.telegram_accounts as ta (
    user_id, tg_user_id, tg_username, display_name, phone_country_code,
    auth_state, auth_step_note, api_id, session_ref, login_token_enc,
    linked_at, unlinked_at, last_error, last_error_at
  ) values (
    v_user, p_tg_user_id, nullif(btrim(coalesce(p_tg_username, '')), ''),
    nullif(btrim(coalesce(p_display_name, '')), ''), p_phone_cc,
    'linked', 'Telegram account connected', p_api_id, p_session_ref, p_login_token_enc,
    clock_timestamp(), null, null, null
  )
  on conflict (user_id) do update
     set tg_user_id      = excluded.tg_user_id,
         tg_username     = excluded.tg_username,
         display_name    = excluded.display_name,
         phone_country_code = coalesce(excluded.phone_country_code, ta.phone_country_code),
         auth_state      = 'linked',
         auth_step_note  = 'Telegram account connected',
         api_id          = coalesce(excluded.api_id, ta.api_id),
         session_ref     = coalesce(excluded.session_ref, ta.session_ref),
         login_token_enc = coalesce(excluded.login_token_enc, ta.login_token_enc),
         linked_at       = clock_timestamp(),
         unlinked_at     = null,
         last_error      = null,
         last_error_at   = null
  where ta.tg_user_id is null or ta.tg_user_id = excluded.tg_user_id;

  update public.telegram_link_requests lr
     set status = 'succeeded', step = 'done', payload = null,
         completed_at = clock_timestamp(), error = null
   where lr.id = p_request_id;

  return jsonb_build_object('user_id', v_user, 'auth_state', 'linked');
exception when unique_violation then
  update public.telegram_link_requests lr
     set status = 'failed', error = 'telegram_account_linked_to_another_user',
         payload = null, completed_at = clock_timestamp()
   where lr.id = p_request_id;
  raise exception 'this Telegram account is already linked to another Massanger user'
    using errcode = '23505';
end;
$$;

create or replace function public.bridge_account_context(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'user_id', ta.user_id,
    'username', pr.username,
    'tg_user_id', ta.tg_user_id,
    'auth_state', ta.auth_state::text,
    'session_ref', ta.session_ref,
    'login_token_enc', ta.login_token_enc,
    'api_id', ta.api_id,
    'worker_id', ta.worker_id,
    'sync_direction', ta.sync_direction::text,
    'auto_download_voice', ta.auto_download_voice,
    'auto_download_media', ta.auto_download_media,
    'mirror_to_app', ta.mirror_to_app,
    'last_sync_at', ta.last_sync_at,
    'access_state', pr.access_state::text
  )
  from public.telegram_accounts ta
  join public.profiles pr on pr.id = ta.user_id
  where ta.user_id = p_user_id;
$$;

create or replace function public.bridge_set_account_state(
  p_user_id     uuid,
  p_auth_state  public.telegram_auth_state,
  p_note        text default null,
  p_error       text default null,
  p_worker_id   text default null,
  p_session_ref text default null,
  p_last_sync   boolean default false
)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.telegram_accounts ta
     set auth_state    = coalesce(p_auth_state, ta.auth_state),
         auth_step_note = p_note,
         last_error    = p_error,
         last_error_at = case when p_error is not null then clock_timestamp() else ta.last_error_at end,
         worker_id     = coalesce(p_worker_id, ta.worker_id),
         session_ref   = coalesce(p_session_ref, ta.session_ref),
         last_sync_at  = case when p_last_sync then clock_timestamp() else ta.last_sync_at end
   where ta.user_id = p_user_id
  returning true;
$$;

-- ---------------------------------------------------------------------------
-- Peer / chat resolution
-- ---------------------------------------------------------------------------
create or replace function public.bridge_upsert_peer(
  p_owner_user_id uuid,
  p_tg_user_id    bigint,
  p_username      text default null,
  p_first_name    text default null,
  p_last_name     text default null,
  p_avatar_url    text default null,
  p_is_contact    boolean default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
begin
  insert into public.telegram_peers as tp (
    owner_user_id, tg_user_id, username, first_name, last_name, avatar_external_url, is_contact
  ) values (
    p_owner_user_id, p_tg_user_id,
    nullif(btrim(regexp_replace(coalesce(p_username, ''), '^@', '')), ''),
    coalesce(left(nullif(p_first_name, ''), 64), ''),
    coalesce(left(nullif(p_last_name, ''), 64), ''),
    nullif(p_avatar_url, ''),
    coalesce(p_is_contact, false)
  )
  on conflict (owner_user_id, tg_user_id) do update
     set username = coalesce(excluded.username, tp.username),
         first_name = case when excluded.first_name <> '' then excluded.first_name else tp.first_name end,
         last_name  = case when excluded.last_name  <> '' then excluded.last_name  else tp.last_name end,
         avatar_external_url = coalesce(excluded.avatar_external_url, tp.avatar_external_url),
         is_contact = coalesce(excluded.is_contact, tp.is_contact)
  returning tp.id into v_id;

  return v_id;
end;
$$;

create or replace function public.bridge_resolve_chat(
  p_owner_user_id  uuid,
  p_tg_chat_id     bigint,
  p_tg_chat_type   text    default 'private',
  p_title          text    default null,
  p_peer_user_id   bigint  default null,
  p_peer_username  text    default null,
  p_peer_first_name text   default null,
  p_peer_last_name text    default null,
  p_peer_avatar_url text   default null,
  p_create         boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_map     public.telegram_chats%rowtype;
  v_chat_id uuid;
  v_peer_id uuid;
  v_created boolean := false;
  v_title   text;
begin
  select * into v_map from public.telegram_chats tc
  where tc.owner_user_id = p_owner_user_id and tc.tg_chat_id = p_tg_chat_id;

  if found and v_map.chat_id is not null then
    update public.chats c
       set title = coalesce(nullif(btrim(coalesce(p_title, '')), ''), c.title)
     where c.id = v_map.chat_id
       and c.is_telegram_mirror
       and p_tg_chat_type <> 'private';

    update public.telegram_chats tc
       set title = coalesce(nullif(btrim(coalesce(p_title, '')), ''), tc.title),
           updated_at = clock_timestamp()
     where tc.id = v_map.id;

    return jsonb_build_object('chat_id', v_map.chat_id, 'created', false, 'mapping_id', v_map.id);
  end if;

  if not p_create then
    return jsonb_build_object('chat_id', null, 'created', false, 'mapping_id', v_map.id);
  end if;

  if p_tg_chat_type = 'private' and p_peer_user_id is not null then
    v_peer_id := public.bridge_upsert_peer(
      p_owner_user_id, p_peer_user_id, p_peer_username,
      p_peer_first_name, p_peer_last_name, p_peer_avatar_url, null
    );
  end if;

  v_title := case
    when p_tg_chat_type = 'private' then
      coalesce(nullif(btrim(coalesce(p_peer_first_name, '') || ' ' || coalesce(p_peer_last_name, '')), ''),
               nullif(p_peer_username, ''), 'Telegram contact')
    else coalesce(nullif(btrim(coalesce(p_title, '')), ''), 'Telegram group')
  end;

  insert into public.chats (
    kind, title, created_by, is_telegram_mirror, tg_peer_id, tg_chat_type
  ) values (
    case when p_tg_chat_type = 'private' then 'direct'::public.chat_kind else 'group'::public.chat_kind end,
    left(v_title, 120),
    p_owner_user_id, true, p_tg_chat_id, p_tg_chat_type
  )
  returning id into v_chat_id;

  insert into public.chat_participants (chat_id, user_id, role)
  values (v_chat_id, p_owner_user_id, 'owner')
  on conflict (chat_id, user_id) do update set left_at = null;

  insert into public.telegram_chats as tc (
    owner_user_id, tg_chat_id, tg_chat_type, chat_id, peer_user_id, title
  ) values (
    p_owner_user_id, p_tg_chat_id, p_tg_chat_type, v_chat_id, p_peer_user_id,
    nullif(btrim(coalesce(p_title, '')), '')
  )
  on conflict (owner_user_id, tg_chat_id) do update
     set chat_id      = coalesce(tc.chat_id, excluded.chat_id),
         peer_user_id = coalesce(excluded.peer_user_id, tc.peer_user_id),
         title        = coalesce(excluded.title, tc.title)
  returning tc.id into v_map.id;

  return jsonb_build_object('chat_id', v_chat_id, 'created', true, 'mapping_id', v_map.id,
                            'peer_id', v_peer_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Inbound ingest (called by the `telegram-ingest` edge function)
-- ---------------------------------------------------------------------------
create or replace function public.bridge_ingest_message(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_owner      uuid   := (p_event ->> 'owner_user_id')::uuid;
  v_tg_chat    bigint := (p_event ->> 'tg_chat_id')::bigint;
  v_tg_msg     bigint := nullif(p_event ->> 'tg_message_id', '')::bigint;
  v_tg_send    bigint := nullif(p_event ->> 'tg_send_id', '')::bigint;
  v_type       text   := coalesce(p_event ->> 'type', 'message');
  v_kind       text   := coalesce(p_event ->> 'kind', 'text');
  v_body       text   := nullif(p_event ->> 'body', '');
  v_media      jsonb  := nullif(coalesce(p_event -> 'media', 'null'::jsonb), 'null'::jsonb);
  v_sent_at    timestamptz := coalesce(nullif(p_event ->> 'sent_at', '')::timestamptz, clock_timestamp());
  v_dedupe     text   := coalesce(nullif(p_event ->> 'dedupe_key', ''),
                                  v_owner::text || ':' || v_tg_chat::text || ':' || coalesce(v_tg_msg::text, 'x'));
  v_reply_tg   bigint := nullif(p_event ->> 'reply_to_tg_message_id', '')::bigint;
  v_peer_id    uuid;
  v_sender_name   text := nullif(p_event ->> 'sender_name', '');
  v_sender_avatar text := nullif(p_event ->> 'sender_avatar_url', '');
  v_res        jsonb;
  v_chat_id    uuid;
  v_map_id     uuid;
  v_msg        public.messages%rowtype;
  v_outbox     public.telegram_outbox%rowtype;
  v_status     text := 'processed';
  v_is_new     boolean;
begin
  if v_owner is null or v_tg_chat is null then
    raise exception 'ingest event needs owner_user_id and tg_chat_id' using errcode = '22023';
  end if;

  -- 1) ledger: duplicate ⇒ nothing to do
  insert into public.telegram_inbox_events as tie (
    dedupe_key, owner_user_id, event_type, payload, status, worker_id
  ) values (
    v_dedupe, v_owner,
    case when v_type in ('message','message_edit','message_delete','read','chat','peer','unlink','state')
         then v_type else 'message' end,
    p_event, 'received', nullif(p_event ->> 'worker_id', '')
  )
  on conflict (dedupe_key) do update
     set status = tie.status
  -- `xmax = 0` is the canonical "row was inserted by this statement" test.
  returning (xmax = 0) into v_is_new;

  if not v_is_new then
    return jsonb_build_object('status', 'duplicate', 'dedupe_key', v_dedupe);
  end if;

  -- 2) mirror chat resolution
  v_res := public.bridge_resolve_chat(
    p_owner_user_id  => v_owner,
    p_tg_chat_id     => v_tg_chat,
    p_tg_chat_type   => coalesce(p_event ->> 'tg_chat_type', 'private'),
    p_title          => p_event ->> 'title',
    p_peer_user_id   => nullif(p_event ->> 'peer_user_id', '')::bigint,
    p_peer_username  => p_event ->> 'peer_username',
    p_peer_first_name=> p_event ->> 'peer_first_name',
    p_peer_last_name => p_event ->> 'peer_last_name',
    p_peer_avatar_url=> p_event ->> 'peer_avatar_url',
    p_create         => v_type <> 'message_delete'
  );
  v_chat_id := nullif(v_res ->> 'chat_id', '')::uuid;
  v_map_id  := nullif(v_res ->> 'mapping_id', '')::uuid;

  if v_chat_id is null then
    update public.telegram_inbox_events set status = 'skipped', error = 'unresolved chat',
           processed_at = clock_timestamp() where dedupe_key = v_dedupe;
    return jsonb_build_object('status', 'skipped', 'reason', 'unresolved_chat', 'dedupe_key', v_dedupe);
  end if;

  -- 3) echoes of our own forwarded messages are reconciled, never duplicated
  if v_tg_send is not null then
    update public.messages m
       set tg_message_id = coalesce(v_tg_msg, m.tg_message_id),
           state         = coalesce(nullif(p_event ->> 'state', '')::text, 'sent')::public.delivery_state,
           synced_to_telegram_at = clock_timestamp()
     where m.chat_id = v_chat_id
       and m.tg_send_id = v_tg_send
     returning * into v_msg;

    if v_msg.id is not null then
      update public.telegram_outbox o
         set state = 'sent', tg_message_id = v_tg_msg, tg_send_id = v_tg_send,
             sent_at = coalesce(o.sent_at, clock_timestamp()), last_error = null
       where o.message_id = v_msg.id and o.state <> 'sent';

      update public.telegram_inbox_events
         set status = 'processed', message_id = v_msg.id, processed_at = clock_timestamp()
       where dedupe_key = v_dedupe;

      return jsonb_build_object('status', 'echo', 'message_id', v_msg.id, 'chat_id', v_chat_id);
    end if;
  end if;

  -- 4) peer sender. An event with neither an outgoing flag nor a peer id is
  --    unusable (there would be no sender identity to render) ⇒ park it as
  --    skipped instead of letting it hit the message shape constraint.
  if coalesce((p_event ->> 'is_outgoing')::boolean, false) = false
     and nullif(p_event ->> 'sender_peer_user_id', '') is null then
    update public.telegram_inbox_events
       set status = 'skipped', error = 'sender missing: is_outgoing=false and no sender_peer_user_id',
           processed_at = clock_timestamp()
     where dedupe_key = v_dedupe;
    return jsonb_build_object('status', 'skipped', 'reason', 'no_sender', 'dedupe_key', v_dedupe);
  end if;

  if nullif(p_event ->> 'sender_peer_user_id', '') is not null then
    v_peer_id := public.bridge_upsert_peer(
      v_owner,
      (p_event ->> 'sender_peer_user_id')::bigint,
      p_event ->> 'sender_username',
      p_event ->> 'sender_first_name',
      p_event ->> 'sender_last_name',
      p_event ->> 'sender_avatar_url',
      (p_event ->> 'sender_is_contact')::boolean
    );

    -- Resolve the snapshot here: the row must render even if the profile of a
    -- mirrored sender never existed in Massanger.
    select coalesce(nullif(btrim(tp.display_name), ''), tp.username, v_sender_name),
           coalesce(tp.avatar_external_url, v_sender_avatar)
      into v_sender_name, v_sender_avatar
    from public.telegram_peers tp
    where tp.id = v_peer_id;
  end if;

  -- 5) the message itself (idempotent on the telegram key)
  if v_type = 'message_edit' then
    update public.messages m
       set body = v_body, media = coalesce(v_media, m.media),
           search_tsv = to_tsvector('simple', coalesce(v_body, '')),
           edited_at = clock_timestamp()
     where m.chat_id = v_chat_id and m.source = 'telegram' and m.tg_message_id = v_tg_msg
     returning * into v_msg;
    v_status := 'edited';
  elsif v_type = 'message_delete' then
    update public.messages m
       set deleted_at = clock_timestamp()
     where m.chat_id = v_chat_id and m.source = 'telegram' and m.tg_message_id = v_tg_msg
     returning * into v_msg;
    v_status := 'deleted';
  else
    insert into public.messages as m (
      chat_id, sender_id, sender_peer_id, sender_name, kind, body, media,
      reply_to_id, source, tg_message_id, tg_peer_sender_id, created_at, state
    ) values (
      v_chat_id,
      -- Outgoing messages on Telegram belong to the owner's app identity;
      -- inbound ones only have a peer row (no auth user exists for them).
      case when coalesce((p_event ->> 'is_outgoing')::boolean, false) then v_owner else null end,

      v_peer_id,
      left(coalesce(v_sender_name, 'Telegram'), 64),
      (case when v_kind in ('text','image','voice') then v_kind else 'text' end)::public.message_kind,
      left(coalesce(v_body, ' '), 8000),
      v_media,
      (select r.id from public.messages r
        where r.chat_id = v_chat_id and r.tg_message_id = v_reply_tg limit 1),
      'telegram',
      v_tg_msg,
      nullif(p_event ->> 'sender_peer_user_id', '')::bigint,
      v_sent_at,
      'delivered'
    )
    on conflict (chat_id, source, tg_message_id) where tg_message_id is not null do nothing
    returning * into v_msg;

    if v_msg.id is null then
      return jsonb_build_object('status', 'duplicate', 'dedupe_key', v_dedupe, 'chat_id', v_chat_id);
    end if;
  end if;

  -- 6) bookkeeping for the mapping row
  update public.telegram_chats tc
     set last_tg_message_id = greatest(coalesce(tc.last_tg_message_id, 0), coalesce(v_tg_msg, 0)),
         last_inbound_at    = clock_timestamp(),
         updated_at         = clock_timestamp()
   where tc.id = v_map_id;

  update public.telegram_accounts ta
     set last_sync_at = clock_timestamp()
   where ta.user_id = v_owner;

  update public.telegram_inbox_events
     set status = 'processed', message_id = v_msg.id, processed_at = clock_timestamp()
   where dedupe_key = v_dedupe;

  return jsonb_build_object(
    'status', coalesce(nullif(v_status, 'processed'), 'processed'),
    'message_id', v_msg.id,
    'chat_id', v_chat_id,
    'dedupe_key', v_dedupe,
    'created', (v_res ->> 'created')::boolean
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Receipts coming from Telegram (double grey / blue ticks on app messages)
-- ---------------------------------------------------------------------------
create or replace function public.bridge_update_delivery(p_event jsonb)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_owner    uuid   := (p_event ->> 'owner_user_id')::uuid;
  v_chat     uuid   := nullif(p_event ->> 'chat_id', '')::uuid;
  v_tg_chat  bigint := nullif(p_event ->> 'tg_chat_id', '')::bigint;
  v_max      bigint := nullif(p_event ->> 'up_to_tg_message_id', '')::bigint;
  v_state    public.delivery_state := coalesce(nullif(p_event ->> 'state', '')::public.delivery_state, 'delivered');
  v_ids      uuid[];
  v_rows     integer := 0;
begin
  if v_chat is null and v_owner is not null and v_tg_chat is not null then
    select tc.chat_id into v_chat
    from public.telegram_chats tc
    where tc.owner_user_id = v_owner and tc.tg_chat_id = v_tg_chat;
  end if;
  if v_chat is null then
    return 0;
  end if;

  select array_agg(m.id) into v_ids
  from public.messages m
  where m.chat_id = v_chat
    and m.source = 'app'
    and m.deleted_at is null
    and (v_max is null or m.tg_message_id is null or m.tg_message_id <= v_max)
    and app.delivery_state_rank(m.state) < app.delivery_state_rank(v_state);

  if v_ids is null then
    return 0;
  end if;

  update public.messages m
     set state = v_state
   where m.id = any (v_ids);

  get diagnostics v_rows = row_count;
  return coalesce(v_rows, 0);
exception when others then
  raise notice 'bridge_update_delivery failed: %', sqlerrm;
  return 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- Outbox lease + completion
-- ---------------------------------------------------------------------------
create or replace function public.bridge_claim_outbox(
  p_worker    text,
  p_owner     uuid    default null,
  p_limit     integer default 25,
  p_lease     interval default interval '180 seconds'
)
returns table (
  outbox_id     bigint,
  message_id    uuid,
  owner_user_id uuid,
  chat_id       uuid,
  tg_chat_id    bigint,
  kind          text,
  payload       jsonb,
  attempts      smallint,
  session_ref   text,
  tg_user_id    bigint
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  -- 1) release leases of workers that died mid-flight
  update public.telegram_outbox o
     set state = case when o.attempts >= o.max_attempts then 'failed' else 'queued'
                 end::public.outbox_state,
         claimed_by = null,
         claimed_at = null,
         last_error = coalesce(o.last_error, 'lease_expired'),
         next_attempt_at = case when o.attempts >= o.max_attempts then o.next_attempt_at
                                else clock_timestamp() end
   where o.state = 'in_flight'
     and o.next_attempt_at < clock_timestamp();

  -- 2) claim a batch. Rows whose owner is not linked / not eligible are
  --    skipped *and* parked so they do not hot-loop the claim query.
  return query
  with picked as (
    select o.id
    from public.telegram_outbox o
    join public.telegram_accounts ta on ta.user_id = o.owner_user_id
    join public.profiles pr           on pr.id = o.owner_user_id
    where o.state in ('queued', 'failed')
      and o.next_attempt_at <= clock_timestamp()
      and (p_owner is null or o.owner_user_id = p_owner)
      and ta.auth_state = 'linked'
      and ta.sync_direction in ('both', 'to_telegram')
      and pr.access_state = 'active'
      and pr.deleted_at is null
      and coalesce(o.tg_chat_id, (select c.tg_peer_id from public.chats c where c.id = o.chat_id)) is not null
    order by o.id
    limit least(greatest(coalesce(p_limit, 25), 1), 200)
    for update of o skip locked
  ),
  upd as (
    update public.telegram_outbox o
       set state = 'in_flight',
           attempts = (o.attempts + 1)::smallint,
           claimed_by = p_worker,
           claimed_at = clock_timestamp(),
           next_attempt_at = clock_timestamp() + p_lease,
           tg_chat_id = coalesce(o.tg_chat_id, (select c.tg_peer_id from public.chats c where c.id = o.chat_id))
      from picked
     where o.id = picked.id
    returning o.*
  ),
  stamped as (
    -- The outbox id doubles as TDLib's `sending_id`; that is exactly what lets
    -- the echo of our own send be reconciled in bridge_ingest_message().
    update public.messages m
       set tg_send_id = u.id
      from upd u
     where m.id = u.message_id
       and m.tg_send_id is null
    returning m.id
  )
  select u.id, u.message_id, u.owner_user_id, u.chat_id, u.tg_chat_id,
         u.kind::text, u.payload, u.attempts, ta.session_ref, ta.tg_user_id
  from upd u
  join public.telegram_accounts ta on ta.user_id = u.owner_user_id
  order by u.id;
end;
$$;

create or replace function public.bridge_complete_outbox(
  p_outbox_id     bigint,
  p_state         public.outbox_state,
  p_tg_message_id bigint default null,
  p_error         text default null,
  p_retry_in      interval default interval '30 seconds'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v public.telegram_outbox%rowtype;
  v_final boolean;
begin
  update public.telegram_outbox o
     set state = p_state,
         tg_message_id  = coalesce(p_tg_message_id, o.tg_message_id),
         last_error     = p_error,
         sent_at        = case when p_state = 'sent' then clock_timestamp() else o.sent_at end,
         next_attempt_at = case when p_state = 'failed' and o.attempts < o.max_attempts
                                 then clock_timestamp() + p_retry_in else o.next_attempt_at end,
         claimed_by = null,
         claimed_at = null
   where o.id = p_outbox_id
   returning * into v;

  if v.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_outbox_id');
  end if;

  v_final := (p_state = 'failed' and v.attempts >= v.max_attempts);

  if v.tg_chat_id is not null then
    update public.telegram_chats tc
       set last_outbound_at = clock_timestamp()
     where tc.owner_user_id = v.owner_user_id and tc.tg_chat_id = v.tg_chat_id;
  end if;

  update public.messages m
     set state = case when v_final then 'failed'::public.delivery_state else m.state end,
         failure_code   = case when v_final then 'telegram_bridge_failed' else m.failure_code end,
         failure_reason = case when v_final then left(coalesce(p_error, 'delivery failed'), 500) else m.failure_reason end,
         synced_to_telegram_at = case when p_state = 'sent' then clock_timestamp() else m.synced_to_telegram_at end,
         tg_message_id  = case when p_state = 'sent' then coalesce(v.tg_message_id, m.tg_message_id) else m.tg_message_id end
   where m.id = v.message_id;

  return jsonb_build_object(
    'ok', true, 'outbox_id', v.id, 'state', v.state::text,
    'attempts', v.attempts, 'retry_at', v.next_attempt_at, 'terminal', v_final
  );
end;
$$;

create or replace function public.bridge_fail_pending_sends(p_owner uuid, p_error text)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_rows integer := 0;
begin
  update public.telegram_outbox o
     set state = 'failed', last_error = p_error, claimed_by = null, claimed_at = null
   where o.owner_user_id = p_owner and o.state in ('queued', 'in_flight', 'failed')
     and o.attempts >= o.max_attempts;

  update public.messages m
     set state = 'failed', failure_code = 'telegram_disconnected', failure_reason = p_error
   where m.id in (select o.message_id from public.telegram_outbox o
                  where o.owner_user_id = p_owner and o.state = 'failed')
     and m.state <> 'failed';

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

create or replace function public.bridge_record_event(p_event jsonb)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  insert into public.telegram_inbox_events as tie (
    dedupe_key, owner_user_id, event_type, payload, status, message_id, error, worker_id, processed_at
  ) values (
    p_event ->> 'dedupe_key',
    nullif(p_event ->> 'owner_user_id', '')::uuid,
    coalesce(p_event ->> 'type', 'state'),
    coalesce(p_event -> 'payload', '{}'::jsonb),
    coalesce(p_event ->> 'status', 'processed'),
    nullif(p_event ->> 'message_id', '')::uuid,
    p_event ->> 'error',
    p_event ->> 'worker_id',
    clock_timestamp()
  )
  on conflict (dedupe_key) do update
     set status = excluded.status,
         message_id = coalesce(tie.message_id, excluded.message_id),
         error = excluded.error,
         processed_at = clock_timestamp()
  returning jsonb_build_object('dedupe_key', tie.dedupe_key, 'status', tie.status);
$$;

-- ---------------------------------------------------------------------------
-- Eligibility gate bookkeeping (called by the account-age edge function)
-- ---------------------------------------------------------------------------
create or replace function public.record_eligibility_check(p_check jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user    uuid := (p_check ->> 'user_id')::uuid;
  v_min     integer := coalesce((p_check ->> 'min_age_days')::int, 366);
  v_verdict text := coalesce(p_check ->> 'verdict', 'error');
  v_age     integer := nullif(p_check ->> 'account_age_days', '')::integer;
  v_created timestamptz := nullif(p_check ->> 'account_created_at', '')::timestamptz;
  v_target  public.access_state;
begin
  if v_user is null then
    raise exception 'user_id required' using errcode = '22023';
  end if;

  v_target := case
    when v_verdict = 'passed' then 'active'::public.access_state
    when v_verdict = 'failed' then 'restricted'::public.access_state
    else (select p.access_state from public.profiles p where p.id = v_user)
  end;

  insert into public.eligibility_checks (
    user_id, request_id, provider, method, verdict, account_created_at,
    account_age_days, min_age_days, signals, reason, source_ip
  ) values (
    v_user,
    nullif(p_check ->> 'request_id', ''),
    coalesce(p_check ->> 'provider', 'google'),
    coalesce(p_check ->> 'method', 'gmail_profile'),
    v_verdict::public.verdict,
    v_created,
    v_age,
    v_min,
    coalesce(p_check -> 'signals', '{}'::jsonb),
    left(coalesce(p_check ->> 'reason', ''), 500),
    p_check ->> 'source_ip'
  )
  on conflict (request_id) do nothing;

  update public.profiles p
     set access_state = coalesce(v_target, p.access_state),
         access_state_reason = case
           when v_verdict = 'passed' then null
           when v_verdict = 'failed' then coalesce(nullif(p_check ->> 'reason', ''),
                                        'Google accounts must be older than 1 year')
           else p.access_state_reason end,
         eligibility_verified_at = clock_timestamp(),
         eligibility_attempts = least(255, p.eligibility_attempts + 1),
         eligibility_method = coalesce(nullif(p_check ->> 'method', ''), p.eligibility_method),
         google_account_created_at = coalesce(v_created, p.google_account_created_at),
         google_account_age_days = coalesce(v_age, p.google_account_age_days),
         google_email = coalesce(nullif(p_check ->> 'email', ''), p.google_email)
   where p.id = v_user;

  return jsonb_build_object(
    'user_id', v_user, 'access_state', v_target::text, 'verdict', v_verdict, 'age_days', v_age
  );
end;
$$;
