-- =============================================================================
-- 00004_functions_and_triggers.sql
-- MessengerX — invariants, projections and RLS helpers.
--
-- Everything the UI needs to stay consistent is derived in-database:
--   * sender snapshot stamped on write (no joins in the feed query)
--   * chat list preview + unread badge maintained by triggers
--   * delivery ticks can only move forward (Realtime replays stay correct)
--   * a Telegram outbox row is created in the *same* transaction as the message
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. RLS / authorisation helpers
-- ---------------------------------------------------------------------------

-- Membership check that never recurses into chat_participants' own policies.
create or replace function app.is_chat_member(p_chat_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.chat_participants cp
    where cp.chat_id = p_chat_id
      and cp.user_id = p_user_id
      and cp.left_at is null
  );
$$;

create or replace function app.is_chat_member_now(p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select app.is_chat_member(p_chat_id, app.current_uid());
$$;

-- The eligibility gate. `restricted` users may read but never write.
create or replace function app.access_ok(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.deleted_at is null
      and p.access_state = 'active'
  );
$$;

create or replace function app.sender_may_post(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select app.access_ok(p_user_id);
$$;

-- Is this a Telegram-linked account we may forward through?
create or replace function app.telegram_send_allowed(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.telegram_accounts ta
    where ta.user_id = p_user_id
      and ta.auth_state = 'linked'
      and ta.sync_direction in ('both', 'to_telegram')
  );
$$;

-- media jsonb contract validation (shared by app writes and the bridge).
create or replace function app.validate_message_media(p_kind public.message_kind, p_media jsonb)
returns void
language plpgsql
stable
set search_path = pg_catalog, public
as $$
begin
  if p_kind in ('text', 'system') then
    if p_media is not null then
      raise exception 'media must be null for % messages', p_kind
        using errcode = '22023';
    end if;
    return;
  end if;

  if p_media is null then
    raise exception 'media is required for % messages', p_kind
      using errcode = '22023';
  end if;

  if p_media ? 'bucket' and coalesce(p_media ->> 'bucket', '') not in ('images', 'voice-notes', 'avatars') then
    raise exception 'unsupported storage bucket "%" (expected images|voice-notes|avatars)', p_media ->> 'bucket'
      using errcode = '22023';
  end if;

  if p_kind = 'image' then
    if not (p_media ? 'path' or p_media ? 'url') then
      raise exception 'image media needs `path` (storage) or `url` (external)'
        using errcode = '22023';
    end if;
  elsif p_kind = 'voice' then
    if not (p_media ? 'path' or p_media ? 'url') then
      raise exception 'voice media needs `path` (storage) or `url` (external)'
        using errcode = '22023';
    end if;
    if coalesce((p_media ->> 'duration_ms')::int, 0) <= 0 then
      raise exception 'voice media requires a positive duration_ms'
        using errcode = '22023';
    end if;
    if p_media ? 'waveform' and jsonb_typeof(p_media -> 'waveform') <> 'array' then
      raise exception 'voice waveform must be a json array'
        using errcode = '22023';
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1b. Link-handshake envelopes
--
-- The Telegram login code / 2FA password must never sit in a table in
-- plaintext, so the client hands them to the `telegram-link` edge function,
-- that function seals them (AES-256-GCM) and only the sealed envelope is
-- stored. The bridge holds the same key and opens it right before feeding
-- TDLib. `alg: 'plain'` exists for `supabase start` local development only.
-- ---------------------------------------------------------------------------
create or replace function app.valid_link_envelope(p jsonb)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when p is null or jsonb_typeof(p) <> 'object' then false
    when p ->> 'alg' = 'plain' then jsonb_typeof(p -> 'data') = 'object'
    when p ->> 'alg' = 'A256GCM' then
         jsonb_typeof(p -> 'iv') = 'string'
     and jsonb_typeof(p -> 'ct') = 'string'
     and char_length(coalesce(p ->> 'iv', '')) between 8 and 128
     and char_length(coalesce(p ->> 'ct', '')) between 8 and 8192
    else false
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. profiles ← auth.users synchronisation
-- ---------------------------------------------------------------------------
create or replace function app.username_from_text(p_raw text)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  -- 'Aziz Carrier' -> 'aziz_carrier', '@Dilnoza.R' -> 'dilnoza.r'
  select coalesce(
    nullif(
      regexp_replace(
        regexp_replace(lower(coalesce(p_raw, '')), '[^a-z0-9_.]+', '_', 'g'),
        '^_+|_+$', '', 'g'
      ),
      ''
    ),
    'user'
  );
$$;

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_base      text;
  v_username  text;
  v_provider  text;
  v_state     public.access_state := 'active';
begin
  v_provider := lower(coalesce(
    new.raw_app_meta_data ->> 'provider',
    split_part(coalesce(new.email, new.phone, ''), '@', 2),
    'phone'
  ));

  -- Google identities stay gated until the age check passes (>= 366 days).
  if v_provider = 'google' then
    v_state := 'pending_verification';
  end if;

  v_base := left(
    app.username_from_text(coalesce(
      new.raw_user_meta_data ->> 'preferred_username',
      new.raw_user_meta_data ->> 'user_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      split_part(coalesce(new.email, ''), '@', 1),
      regexp_replace(coalesce(new.phone, ''), '[^0-9]', '', 'g')
    )),
    24
  );
  if char_length(v_base) < 3 then
    v_base := 'user' || substr(md5(new.id::text), 1, 6);
  end if;

  v_username := v_base;
  while exists (select 1 from public.profiles p where p.username_norm = lower(v_username)) loop
    v_username := left(v_base, 24) || '_' || substr(md5(clock_timestamp()::text || random()::text), 1, 5);
  end loop;

  insert into public.profiles (
    id, username, display_name, phone_e164, google_email, access_state, access_state_reason
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
    v_state,
    case when v_state = 'pending_verification'
         then 'Google accounts must be older than 1 year. Verify to unlock messaging.'
         else null end
  );

  -- A linked-account row always exists so the Profile toggle has something to flip.
  insert into public.telegram_accounts (user_id, auth_state)
  values (new.id, 'unlinked')
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

create or replace function app.handle_user_update()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.profiles p
     set phone_e164   = nullif(new.phone, ''),
         google_email = coalesce(nullif(new.email, ''), p.google_email),
         updated_at   = clock_timestamp()
   where p.id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update of email, phone on auth.users
  for each row execute function app.handle_user_update();

-- Clients must not be able to self-promote (access_state, google_* etc.).
-- NOTE: deliberately SECURITY INVOKER. The guard has to observe the *client*
-- role, so it must not switch to the function owner's identity. When a
-- SECURITY DEFINER RPC (update_profile, heartbeat…) rewrites the row, the
-- trigger runs as the owner and `app.is_service_role()` is true — which is the
-- intended "the RPC is the policy" behaviour.
create or replace function app.guard_profile_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if app.is_service_role() then
    return new;
  end if;

  if new.id is distinct from old.id
     or new.username is distinct from old.username
     or new.phone_e164 is distinct from old.phone_e164
     or new.google_email is distinct from old.google_email
     or new.access_state is distinct from old.access_state
     or new.access_state_reason is distinct from old.access_state_reason
     or new.eligibility_verified_at is distinct from old.eligibility_verified_at
     or new.eligibility_attempts is distinct from old.eligibility_attempts
     or new.eligibility_method is distinct from old.eligibility_method
     or new.google_account_created_at is distinct from old.google_account_created_at
     or new.google_account_age_days is distinct from old.google_account_age_days
     or new.deleted_at is distinct from old.deleted_at
  then
    raise exception 'these profile fields are server-managed'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_guard_update on public.profiles;
create trigger profiles_guard_update
  before update on public.profiles
  for each row execute function app.guard_profile_update();

-- ---------------------------------------------------------------------------
-- 3. Direct-chat integrity: one live 1:1 conversation per ordered pair
-- ---------------------------------------------------------------------------
create or replace function app.enforce_unique_direct_pair()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_other   uuid;
  v_exists  uuid;
begin
  if (select kind from public.chats c where c.id = new.chat_id) <> 'direct' then
    return new;
  end if;

  select cp.user_id into v_other
  from public.chat_participants cp
  where cp.chat_id = new.chat_id
    and cp.user_id <> new.user_id
    and cp.left_at is null
  limit 1;

  if v_other is null then
    return new;
  end if;

  select c.id into v_exists
  from public.chat_participants a
  join public.chat_participants b on b.chat_id = a.chat_id and b.user_id = v_other and b.left_at is null
  join public.chats c on c.id = a.chat_id
  where a.user_id = new.user_id
    and a.left_at is null
    and c.kind = 'direct'
    and c.id <> new.chat_id
  limit 1;

  if v_exists is not null then
    raise exception 'a direct chat with this peer already exists: %', v_exists
      using errcode = '23505';
  end if;

  return new;
end;
$$;

drop trigger if exists chat_participants_unique_direct on public.chat_participants;
create trigger chat_participants_unique_direct
  before insert on public.chat_participants
  for each row execute function app.enforce_unique_direct_pair();

-- ---------------------------------------------------------------------------
-- 4. Message lifecycle
-- ---------------------------------------------------------------------------
create or replace function app.before_message_insert()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_profile public.profiles%rowtype;
  v_peer    public.telegram_peers%rowtype;
begin
  perform app.validate_message_media(new.kind, new.media);

  if new.id is null then
    new.id := app.uuid_v7();
  end if;
  new.created_at := coalesce(new.created_at, clock_timestamp());
  new.search_tsv := to_tsvector('simple', coalesce(new.body, ''));

  if new.kind = 'system' then
    new.sender_name   := coalesce(nullif(btrim(new.sender_name), ''), 'MessengerX');
    new.state         := 'read';
    new.sent_at       := coalesce(new.sent_at, new.created_at);
    new.delivered_at  := new.sent_at;
    new.read_at       := new.sent_at;
    return new;
  end if;

  if new.sender_id is not null then
    select * into v_profile from public.profiles p where p.id = new.sender_id;
    if not found then
      raise exception 'sender profile % does not exist', new.sender_id
        using errcode = '23503';
    end if;
    new.sender_name        := coalesce(nullif(btrim(new.sender_name), ''),
                                       nullif(btrim(v_profile.display_name), ''),
                                       v_profile.username,
                                       'MessengerX');
    new.sender_avatar_path := coalesce(new.sender_avatar_path, v_profile.avatar_path);

    -- Eligibility is enforced here as well as in RLS: the bridge writes with
    -- service_role and must not smuggle a restricted user's message through.
    if new.source = 'app' and not app.access_ok(new.sender_id) then
      raise exception 'account is not eligible to send (state: %)', v_profile.access_state
        using errcode = '42501';
    end if;
  elsif new.sender_peer_id is not null then
    select * into v_peer from public.telegram_peers tp where tp.id = new.sender_peer_id;
    if found then
      new.sender_name        := coalesce(nullif(btrim(new.sender_name), ''),
                                         nullif(btrim(v_peer.display_name), ''),
                                         v_peer.username,
                                         'Telegram');
      new.sender_avatar_path := coalesce(new.sender_avatar_path, v_peer.avatar_external_url);
    end if;
  end if;

  if new.source = 'app' then
    -- Persisted by the API ⇒ the single tick is earned immediately. A client
    -- may submit 'sending' (optimistic bubble) or nothing at all; asking for a
    -- nicer tick is not a thing it gets to decide.
    if app.is_request_service() then
      new.state := case when new.state in ('sending', 'pending') or new.state is null
                        then 'sent'::public.delivery_state else new.state end;
    else
      new.state := 'sent'::public.delivery_state;
    end if;
    new.sent_at  := coalesce(new.sent_at, clock_timestamp());
  else
    -- Inbound from Telegram: it already reached the network, so it is
    -- "delivered"; anything we sent ourselves is "read" on the other side.
    if new.sender_id is not null then
      new.state       := 'read';
      new.delivered_at := coalesce(new.delivered_at, new.created_at);
      new.read_at      := coalesce(new.read_at, new.created_at);
    else
      new.state       := 'delivered';
      new.delivered_at := coalesce(new.delivered_at, new.created_at);
    end if;
    new.sent_at := coalesce(new.sent_at, new.created_at);
  end if;

  new.state_changed_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists messages_before_insert on public.messages;
create trigger messages_before_insert
  before insert on public.messages
  for each row execute function app.before_message_insert();

create or replace function app.before_message_update()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  -- Ticks move forward only (never downgrade delivered→sent on a replay), with
  -- one deliberate exception: 'failed' is an orthogonal terminal error, not a
  -- progress step. A bridge that gives up on forwarding must be able to mark
  -- the bubble red even though the server had already accepted the message,
  -- and `retry_message` must be able to move 'failed' back to 'pending'.
  if new.state is distinct from old.state then
    if new.state = 'failed' then
      new.state_changed_at := clock_timestamp();
    elsif app.delivery_state_rank(new.state) < app.delivery_state_rank(old.state) then
      new.state := old.state;
    else
      new.state_changed_at := clock_timestamp();
    end if;
  end if;

  if new.state in ('sent', 'delivered', 'read') and old.sent_at is null then
    new.sent_at := coalesce(new.sent_at, clock_timestamp());
  end if;
  if new.state in ('delivered', 'read') and old.delivered_at is null then
    new.delivered_at := coalesce(new.delivered_at, clock_timestamp());
  end if;
  if new.state = 'read' and old.read_at is null then
    new.read_at := coalesce(new.read_at, clock_timestamp());
  end if;
  if new.state = 'failed' then
    new.failure_code   := coalesce(new.failure_code, 'delivery_failed');
    new.failure_reason := coalesce(new.failure_reason, old.failure_reason);
  end if;

  -- Content edits are auditable and only allowed on our own app messages.
  if new.body is distinct from old.body or new.media is distinct from old.media then
    if new.kind = 'text' and btrim(coalesce(new.body, '')) = '' then
      raise exception 'text messages cannot be emptied; delete them instead'
        using errcode = '22023';
    end if;
    perform app.validate_message_media(new.kind, new.media);
    new.edited_at := clock_timestamp();
    new.search_tsv := to_tsvector('simple', coalesce(new.body, ''));
  end if;

  if new.deleted_at is not null and old.deleted_at is null then
    new.search_tsv := null;
  end if;

  return new;
end;
$$;

drop trigger if exists messages_before_update on public.messages;
create trigger messages_before_update
  before update on public.messages
  for each row execute function app.before_message_update();

-- Chat preview + unread badge + the Telegram outbox, all in one pass.
create or replace function app.after_message_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_account public.telegram_accounts%rowtype;
  v_map     public.telegram_chats%rowtype;
begin
  if tg_op = 'INSERT' then
    update public.chats c
       set last_message_id   = new.id,
           last_message_at   = new.created_at,
           updated_at        = clock_timestamp()
     where c.id = new.chat_id
       and (c.last_message_at is null or c.last_message_at < new.created_at);

    update public.chat_participants cp
       set unread_count = cp.unread_count + 1,
           updated_at = clock_timestamp()
     where cp.chat_id = new.chat_id
       and cp.user_id <> new.sender_id
       and cp.left_at is null
       and new.sender_id is not null
       and (cp.last_read_message_id is null
            or cp.last_read_message_id < new.id);

    -- Transactional outbox: only app-originated content is forwarded.
    if new.source = 'app'
       and new.kind <> 'system'
       and new.sender_id is not null
       and new.deleted_at is null
    then
      select * into v_account from public.telegram_accounts ta where ta.user_id = new.sender_id;
      if found and v_account.auth_state = 'linked'
                  and v_account.sync_direction in ('both', 'to_telegram')
      then
        select * into v_map
        from public.telegram_chats tc
        where tc.owner_user_id = new.sender_id
          and (tc.chat_id = new.chat_id or tc.tg_chat_id = (select tg_peer_id from public.chats where id = new.chat_id))
        limit 1;

        if v_map.tg_chat_id is not null
           and coalesce(v_map.sync_direction, 'both') in ('both', 'to_telegram')
        then
          insert into public.telegram_outbox (
            message_id, owner_user_id, chat_id, tg_chat_id, kind, payload, state
          ) values (
            new.id, new.sender_id, new.chat_id, v_map.tg_chat_id, new.kind,
            jsonb_strip_nulls(jsonb_build_object(
              'text',       new.body,
              'media',      new.media,
              'reply_to',   new.reply_to_id,
              'tg_reply_to', (select m.tg_message_id from public.messages m where m.id = new.reply_to_id),
              'chat_kind',  (select c.kind::text || '' from public.chats c where c.id = new.chat_id),
              'created_at', new.created_at
            )),
            'queued'
          )
          on conflict (message_id) do nothing;
        end if;
      end if;
    end if;

    return new;
  end if;

  if new.deleted_at is not null and old.deleted_at is null then
    update public.chats c
       set last_message_id = (
             select m.id from public.messages m
             where m.chat_id = new.chat_id and m.deleted_at is null
             order by m.id desc limit 1
           ),
           last_message_at = (
             select m.created_at from public.messages m
             where m.chat_id = new.chat_id and m.deleted_at is null
             order by m.id desc limit 1
           ),
           updated_at = clock_timestamp()
     where c.id = new.chat_id;
  end if;

  return new;
end;
$$;

drop trigger if exists messages_after_write on public.messages;
create trigger messages_after_write
  after insert or update of deleted_at on public.messages
  for each row execute function app.after_message_write();

-- ---------------------------------------------------------------------------
-- 5. Bridge wake-up signals.
-- Realtime (postgres_changes) is the primary delivery channel for the worker,
-- but a NOTIFY lets a same-region worker react in <1ms instead of waiting for
-- the next poll. Failures here must never break the business transaction, so
-- everything is swallowed.
-- ---------------------------------------------------------------------------
create or replace function app.notify_bridge()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_channel text := coalesce(nullif(btrim(array_to_string(TG_ARGV, ',')), ''), 'messengerx_bridge');
  v_id      text;
begin
  if tg_op = 'DELETE' then
    v_id := to_jsonb(old) ->> 'id';
  else
    v_id := to_jsonb(new) ->> 'id';
  end if;

  perform pg_notify(
    v_channel,
    json_build_object(
      'table', tg_table_name,
      'op',    tg_op,
      'id',    v_id
    )::text
  );
  return coalesce(new, old);
exception when others then
  return coalesce(new, old);
end;
$$;

drop trigger if exists telegram_outbox_notify on public.telegram_outbox;
create trigger telegram_outbox_notify
  after insert on public.telegram_outbox
  for each row execute function app.notify_bridge('messengerx_outbox');

drop trigger if exists telegram_link_requests_notify on public.telegram_link_requests;
create trigger telegram_link_requests_notify
  after insert or update of status, step on public.telegram_link_requests
  for each row execute function app.notify_bridge('messengerx_link');

drop trigger if exists telegram_outbox_touch on public.telegram_outbox;
create trigger telegram_outbox_touch
  before update on public.telegram_outbox
  for each row execute function app.set_updated_at();

drop trigger if exists telegram_link_requests_touch on public.telegram_link_requests;
create trigger telegram_link_requests_touch
  before update on public.telegram_link_requests
  for each row execute function app.set_updated_at();

drop trigger if exists telegram_accounts_touch on public.telegram_accounts;
create trigger telegram_accounts_touch
  before update on public.telegram_accounts
  for each row execute function app.set_updated_at();

drop trigger if exists telegram_chats_touch on public.telegram_chats;
create trigger telegram_chats_touch
  before update on public.telegram_chats
  for each row execute function app.set_updated_at();

drop trigger if exists telegram_peers_touch on public.telegram_peers;
create trigger telegram_peers_touch
  before update on public.telegram_peers
  for each row execute function app.set_updated_at();

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch
  before update on public.profiles
  for each row execute function app.set_updated_at();

drop trigger if exists chats_touch on public.chats;
create trigger chats_touch
  before update on public.chats
  for each row execute function app.set_updated_at();

drop trigger if exists chat_participants_touch on public.chat_participants;
create trigger chat_participants_touch
  before update on public.chat_participants
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. Small utilities used by RPCs
-- ---------------------------------------------------------------------------
create or replace function app.system_notice(p_chat_id uuid, p_body text)
returns uuid
language sql
security definer
set search_path = pg_catalog, public
as $$
  insert into public.messages (chat_id, kind, body, source, state)
  values (p_chat_id, 'system', left(p_body, 500), 'app', 'read')
  returning id;
$$;

create or replace function app.resolvable_media_payload(p_media jsonb)
returns jsonb
language sql
stable
set search_path = pg_catalog, public
as $$
  -- Adds the canonical storage path/derived metadata the bridge needs, without
  -- copying bytes into Postgres.
  select case
    when p_media is null then null
    else jsonb_set(
           p_media,
           '{storage_id}',
           to_jsonb(nullif(p_media ->> 'path', '')),
           true
         )
  end;
$$;
