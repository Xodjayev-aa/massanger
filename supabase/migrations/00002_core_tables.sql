-- =============================================================================
-- 00002_core_tables.sql
-- Massanger — profiles / chats / chat_participants / messages (+ receipts).
--
-- This is the whole messaging core. It is deliberately transport-agnostic:
-- rows may originate from the Flutter app (`source = 'app'`) or be mirrored
-- in from a personal Telegram account by the TDLib bridge (`source =
-- 'telegram'`), and both share one timeline, one unread counter and one set of
-- delivery ticks.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- profiles — 1:1 with auth.users, created by a trigger (see 00004).
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id                    uuid primary key references auth.users (id) on delete cascade,
  username              text not null check (char_length(username) between 3 and 32
                                              and username ~ '^[a-z0-9_.]+$'),
  username_norm         text generated always as (lower(username)) stored,
  display_name          text not null default '' check (char_length(display_name) <= 64),
  avatar_path           text,           -- storage://avatars/<uuid>
  avatar_external_url   text,           -- e.g. Telegram photo remote URL
  bio                   text not null default '' check (char_length(bio) <= 280),
  phone_e164            text,
  telegram_username     text,
  access_state          public.access_state not null default 'pending_verification',
  access_state_reason   text,
  -- Google eligibility (see the `account-age-gate` edge function) ------------
  google_email          text,
  google_account_created_at timestamptz,
  google_account_age_days integer check (google_account_age_days is null
                                         or google_account_age_days >= 0),
  eligibility_verified_at timestamptz,
  eligibility_attempts  smallint not null default 0 check (eligibility_attempts between 0 and 255),
  eligibility_method    text,           -- gmail_profile | gmail_oldest_message | drive_oldest_file
  -- Presence ----------------------------------------------------------------
  -- Derived (never stored) as `last_seen_at > now() - interval '5 min'`: no
  -- write amplification, no client-writable boolean to guard.
  last_seen_at          timestamptz,
  -- Moderation / lifecycle ---------------------------------------------------
  deleted_at            timestamptz,
  created_at            timestamptz not null default clock_timestamp(),
  updated_at            timestamptz not null default clock_timestamp()
);

comment on table public.profiles is
  'Public identity document for each auth user. Never stores secrets or tokens.';
comment on column public.profiles.access_state is
  'RLS gate: only ''active'' accounts may create or send messages.';

create unique index if not exists profiles_username_norm_key
  on public.profiles (username_norm);
create unique index if not exists profiles_phone_e164_key
  on public.profiles (phone_e164) where phone_e164 is not null;
create index if not exists profiles_directory_idx
  on public.profiles (username_norm) include (display_name, avatar_path);
create index if not exists profiles_presence_idx
  on public.profiles (last_seen_at desc nulls last) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- chats — a conversation. `direct` for 1:1, `group` for 3+.
-- Telegram-mirrored chats are ordinary chats flagged `is_telegram_mirror`.
-- ---------------------------------------------------------------------------
create table if not exists public.chats (
  id                  uuid primary key default app.uuid_v7(),
  kind                public.chat_kind not null default 'direct',
  title               text check (title is null or char_length(title) between 1 and 120),
  avatar_path         text,
  avatar_external_url text,
  created_by          uuid references public.profiles (id) on delete set null,
  is_telegram_mirror  boolean not null default false,
  tg_peer_id          bigint,           -- TDLib chat_id (peer scoped to owner account)
  tg_chat_type        text check (tg_chat_type is null
                                  or tg_chat_type in ('private', 'basic_group', 'supergroup', 'channel')),
  last_message_id     uuid,             -- FK added below to break the circular dependency
  last_message_at     timestamptz,
  created_at          timestamptz not null default clock_timestamp(),
  updated_at          timestamptz not null default clock_timestamp(),
  constraint chats_title_shape check (
    (kind = 'group'  and title is not null) or
    (kind = 'direct' and (title is null or is_telegram_mirror))
  ),
  constraint chats_mirror_shape check (
    (not is_telegram_mirror and tg_peer_id is null) or
    (is_telegram_mirror and tg_peer_id is not null and created_by is not null)
  )
);

comment on table public.chats is 'Conversation container shared by app-native and Telegram-mirrored traffic.';
comment on column public.chats.tg_peer_id is 'Telegram chat id; unique per owning Telegram account.';

create unique index if not exists chats_tg_peer_key
  on public.chats (created_by, tg_peer_id) where tg_peer_id is not null and is_telegram_mirror;
create index if not exists chats_recency_idx
  on public.chats (last_message_at desc nulls last, id desc);

-- ---------------------------------------------------------------------------
-- chat_participants — membership + per-user read state / badge.
-- `left_at` keeps history readable while removing the chat from the list.
-- ---------------------------------------------------------------------------
create table if not exists public.chat_participants (
  chat_id               uuid not null references public.chats (id) on delete cascade,
  user_id               uuid not null references public.profiles (id) on delete cascade,
  role                  public.participant_role not null default 'member',
  unread_count          integer not null default 0 check (unread_count >= 0),
  last_read_message_id  uuid,
  last_read_at          timestamptz,
  muted_until           timestamptz,
  pinned_at             timestamptz,
  joined_at             timestamptz not null default clock_timestamp(),
  left_at               timestamptz,
  updated_at            timestamptz not null default clock_timestamp(),
  primary key (chat_id, user_id)
);

create index if not exists chat_participants_user_idx
  on public.chat_participants (user_id, left_at, chat_id desc);

-- ---------------------------------------------------------------------------
-- messages — single append-only timeline for every transport.
--
-- media jsonb contract (validated by app.validate_message_media below):
--   image : { bucket, path, mime, width, height, size_bytes, blurhash?,
--             caption?, tg_file_id? }
--   voice : { bucket, path, mime, duration_ms, size_bytes, waveform[0..100]*64,
--             text_transcript?, tg_file_id? }
--   text  : absent
-- ---------------------------------------------------------------------------
create table if not exists public.messages (
  id                 uuid primary key default app.uuid_v7(),
  chat_id            uuid not null references public.chats (id) on delete cascade,
  sender_id          uuid references public.profiles (id) on delete set null,
  sender_peer_id     uuid,              -- FK -> telegram_peers, added in 00003
  sender_name        text not null default '',  -- snapshot, filled by trigger; keeps the feed join-free
  sender_avatar_path text,
  kind               public.message_kind not null,
  body               text check (body is null or char_length(body) <= 8000),
  media              jsonb,
  reply_to_id        uuid references public.messages (id) on delete set null,
  source             public.message_source not null default 'app',
  -- Delivery ---------------------------------------------------------
  state              public.delivery_state not null default 'pending',
  state_changed_at   timestamptz not null default clock_timestamp(),
  sent_at            timestamptz,
  delivered_at       timestamptz,
  read_at            timestamptz,
  failure_code       text,
  failure_reason     text,
  -- Telegram correlation (idempotency + echo suppression) -----------
  tg_message_id      bigint,
  tg_send_id         bigint,            -- TDLib `send_id` for our own outgoing sends
  tg_peer_sender_id  bigint,
  -- Write / sync bookkeeping -----------------------------------------
  client_message_id  uuid,              -- client-generated idempotency key
  synced_to_telegram_at timestamptz,
  edited_at          timestamptz,
  deleted_at         timestamptz,
  created_at         timestamptz not null default clock_timestamp(),
  -- NOTE: deliberately *not* a GENERATED column. Postgres refuses UPDATEs on
  -- tables that combine REPLICA IDENTITY FULL (which Realtime needs for tick
  -- payloads, see 00008) with generated columns ("cannot update table"). A
  -- trigger-maintained tsvector keeps both features, and the GIN index below is
  -- identical.
  search_tsv         tsvector,

  -- A message always carries exactly one sender identity: an app user, a
  -- Telegram peer (mirrored traffic), or nothing at all (system notices).
  constraint messages_shape check (
    (kind = 'text'  and coalesce(sender_id, sender_peer_id) is not null
                      and btrim(coalesce(body, '')) <> '' and media is null) or
    (kind = 'image' and coalesce(sender_id, sender_peer_id) is not null
                      and (media is not null or btrim(coalesce(body, '')) <> '')) or
    (kind = 'voice' and coalesce(sender_id, sender_peer_id) is not null and media is not null) or
    (kind = 'system' and sender_id is null and sender_peer_id is null
                       and btrim(coalesce(body, '')) <> '')
  ),
  constraint messages_media_is_object check (media is null or jsonb_typeof(media) = 'object'),
  constraint messages_no_self_reply check (reply_to_id is null or reply_to_id <> id),
  constraint messages_telegram_shape check (
    (source = 'telegram' and tg_message_id is not null) or (source = 'app')
  )
);

comment on table public.messages is
  'Append-only message log for all chats. Realtime-published; the Flutter UI renders it directly.';
comment on column public.messages.tg_send_id is
  'TDLib send_id used to reconcile the echo of a message we forwarded to Telegram.';
comment on column public.messages.sender_name is
  'Denormalised sender snapshot: avoids joins in the hot feed/list queries.';

create unique index if not exists messages_client_idem_key
  on public.messages (sender_id, client_message_id) where client_message_id is not null;
create unique index if not exists messages_telegram_key
  on public.messages (chat_id, source, tg_message_id) where tg_message_id is not null;
create unique index if not exists messages_tg_send_key
  on public.messages (chat_id, tg_send_id) where tg_send_id is not null;
create index if not exists messages_feed_idx
  on public.messages (chat_id, id desc) where deleted_at is null;
create index if not exists messages_feed_all_idx
  on public.messages (chat_id, id desc);
create index if not exists messages_pending_outbox_idx
  on public.messages (state, id) where source = 'app' and state in ('sending', 'pending', 'sent');
create index if not exists messages_search_idx
  on public.messages using gin (search_tsv);
create index if not exists messages_sender_idx
  on public.messages (sender_id, id desc) where deleted_at is null;

alter table public.chats
  drop constraint if exists chats_last_message_fk,
  add constraint chats_last_message_fk
  foreign key (last_message_id) references public.messages (id) on delete set null;

-- ---------------------------------------------------------------------------
-- message_reads — per-message read receipts (group chats, and the source of
-- the blue tick for 1:1 chats).
-- ---------------------------------------------------------------------------
create table if not exists public.message_reads (
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  read_at    timestamptz not null default clock_timestamp(),
  primary key (message_id, user_id)
);

create index if not exists message_reads_message_idx on public.message_reads (message_id);
