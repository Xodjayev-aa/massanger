-- =============================================================================
-- 00003_telegram_tables.sql
-- Massanger — the Telegram bridge control plane.
--
-- Topology (see docs/architecture.md):
--
--   Flutter ──(RLS insert)──▶ public.messages ──(trigger)──▶ telegram_outbox
--                                                           │
--                                        Realtime / LISTEN ▼
--                                   services/telegram-bridge (Node worker)
--                                                           │
--                                               TDLib (JSON client) ▼
--                                                      Telegram MTProto
--                                                           │
--                                    POST /functions/v1/telegram-ingest
--                                                           ▼
--                          bridge_ingest_message() ──▶ messages (source=telegram)
--                                                           │
--                                             Realtime ▼ Flutter UI (instant)
--
-- A *personal* account is used (user's choice: TDLib, not the Bot API), so each
-- user owns their own TDLib instance; `telegram_accounts` is the per-user
-- session registry and `telegram_link_requests` is the interactive
-- authorization handshake queue (phone → code → password).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- telegram_peers — non-authenticated identities discovered on Telegram.
-- They are NOT profiles (no auth.user exists for them); they only carry the
-- display data needed to render mirrored messages.
-- ---------------------------------------------------------------------------
create table if not exists public.telegram_peers (
  id             uuid primary key default app.uuid_v7(),
  owner_user_id  uuid not null references public.profiles (id) on delete cascade,
  tg_user_id     bigint not null,
  username       text,
  first_name     text not null default '',
  last_name      text not null default '',
  display_name   text generated always as (
                   nullif(trim(first_name || ' ' || last_name), '')
                 ) stored,
  phone_country_code text,
  avatar_external_url text,
  is_contact     boolean not null default false,
  created_at     timestamptz not null default clock_timestamp(),
  updated_at     timestamptz not null default clock_timestamp(),
  unique (owner_user_id, tg_user_id)
);

comment on table public.telegram_peers is
  'Telegram-side counterparties for a linked account (shadow identities, no auth user).';

create index if not exists telegram_peers_username_idx
  on public.telegram_peers (owner_user_id, lower(username)) where username is not null;

-- ---------------------------------------------------------------------------
-- telegram_accounts — one linked personal Telegram account per app user,
-- plus the state machine the UI renders on the Profile screen.
-- ---------------------------------------------------------------------------
create table if not exists public.telegram_accounts (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  tg_user_id        bigint unique,
  tg_username       text,
  display_name      text,
  phone_country_code text,
  auth_state        public.telegram_auth_state not null default 'unlinked',
  auth_step_note    text,                 -- human readable hint for the UI
  api_id            integer,              -- not secret (Telegram treats id as public)
  session_ref       text,                 -- opaque worker-local session directory key
  login_token_enc   text,                 -- AES-GCM ciphertext of TDLib exportLoginToken
  worker_id         text,                 -- which bridge instance owns the session
  sync_direction    public.sync_direction not null default 'both',
  auto_download_voice boolean not null default true,
  auto_download_media boolean not null default true,
  mirror_to_app     boolean not null default true,
  last_sync_at      timestamptz,
  last_error_at     timestamptz,
  last_error        text,
  linked_at         timestamptz,
  unlinked_at       timestamptz,
  created_at        timestamptz not null default clock_timestamp(),
  updated_at        timestamptz not null default clock_timestamp()
);

comment on column public.telegram_accounts.session_ref is
  'Pointer to the TDLib session on the worker host. The secret material never leaves the host.';
comment on column public.telegram_accounts.login_token_enc is
  'Optional AES-256-GCM wrapped TDLib login token (base64) so any worker can resume the session.';

create index if not exists telegram_accounts_worker_idx
  on public.telegram_accounts (worker_id, auth_state);

-- ---------------------------------------------------------------------------
-- telegram_link_requests — the out-of-band handshake between the app and the
-- bridge. The app writes what the user typed (phone / code / password); the
-- worker claims the row, feeds TDLib and reports progress. Rows are short
-- lived and `payload` is wiped once consumed.
-- ---------------------------------------------------------------------------
create table if not exists public.telegram_link_requests (
  id            uuid primary key default app.uuid_v7(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  kind          public.link_request_kind not null default 'link',
  status        public.link_request_status not null default 'queued',
  step          text not null default 'queued',   -- queued|awaiting_phone|awaiting_code|awaiting_password|awaiting_qr|done
  payload       jsonb,                            -- sealed credential envelope {alg,iv,ct} (never plaintext)
  qr_code       text,                             -- TDLib requestQrCode prefix for the login QR
  session_ref   text,
  error         text,
  claimed_by    text,
  expires_at    timestamptz not null default (clock_timestamp() + interval '10 minutes'),
  claimed_at    timestamptz,
  completed_at  timestamptz,
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp(),
  constraint link_requests_payload_shape check (payload is null or jsonb_typeof(payload) = 'object')
);

create index if not exists telegram_link_requests_queue_idx
  on public.telegram_link_requests (status, created_at) where status in ('queued', 'claimed', 'awaiting_user');
create index if not exists telegram_link_requests_user_idx
  on public.telegram_link_requests (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- telegram_chats — mapping table: Telegram chat ↔ Massanger chat, per owner.
-- Also stores the per-chat sync toggle (the "sync this chat" switch).
-- ---------------------------------------------------------------------------
create table if not exists public.telegram_chats (
  id                uuid primary key default app.uuid_v7(),
  owner_user_id     uuid not null references public.profiles (id) on delete cascade,
  tg_chat_id        bigint not null,
  tg_chat_type      text not null default 'private'
                      check (tg_chat_type in ('private', 'basic_group', 'supergroup', 'channel')),
  chat_id           uuid references public.chats (id) on delete set null,
  peer_user_id      bigint,             -- for private chats: the other side
  sync_direction    public.sync_direction not null default 'both',
  title             text,
  muted             boolean not null default false,
  last_tg_message_id bigint,
  last_inbound_at   timestamptz,
  last_outbound_at  timestamptz,
  created_at        timestamptz not null default clock_timestamp(),
  updated_at        timestamptz not null default clock_timestamp(),
  unique (owner_user_id, tg_chat_id)
);

create index if not exists telegram_chats_chat_idx on public.telegram_chats (chat_id);

-- ---------------------------------------------------------------------------
-- telegram_outbox — transactional outbox. Written by a trigger inside the same
-- transaction as the message insert, so a message can never be persisted
-- without its delivery job, and vice versa.
-- ---------------------------------------------------------------------------
create table if not exists public.telegram_outbox (
  id               bigint generated always as identity primary key,
  message_id       uuid not null references public.messages (id) on delete cascade,
  owner_user_id    uuid not null references public.profiles (id) on delete cascade,
  chat_id          uuid not null references public.chats (id) on delete cascade,
  tg_chat_id       bigint,                       -- NULL until the chat is resolved
  kind             public.message_kind not null,
  payload          jsonb not null default '{}'::jsonb,
  state            public.outbox_state not null default 'queued',
  attempts         smallint not null default 0 check (attempts >= 0),
  max_attempts     smallint not null default 6 check (max_attempts between 1 and 50),
  next_attempt_at  timestamptz not null default clock_timestamp(),
  claimed_by       text,
  claimed_at       timestamptz,
  tg_message_id    bigint,
  tg_send_id       bigint,
  last_error       text,
  sent_at          timestamptz,
  created_at       timestamptz not null default clock_timestamp(),
  updated_at       timestamptz not null default clock_timestamp(),
  unique (message_id)
);

comment on table public.telegram_outbox is
  'Transactional outbox consumed by the TDLib bridge (at-least-once; idempotent via tg_send_id).';

create index if not exists telegram_outbox_claim_idx
  on public.telegram_outbox (next_attempt_at, id) where state in ('queued', 'failed');
create index if not exists telegram_outbox_owner_idx
  on public.telegram_outbox (owner_user_id, id desc);

-- ---------------------------------------------------------------------------
-- telegram_inbox_events — durable ledger of every event the bridge pushed
-- through the ingest webhook. Provides idempotency across worker restarts and
-- a replayable audit trail.
-- ---------------------------------------------------------------------------
create table if not exists public.telegram_inbox_events (
  id             bigint generated always as identity primary key,
  dedupe_key     text not null unique,       -- owner:chat:message:kind
  owner_user_id  uuid references public.profiles (id) on delete cascade,
  event_type     text not null check (event_type in
                   ('message','message_edit','message_delete','read','chat','peer','unlink','state')),
  payload        jsonb not null default '{}'::jsonb,
  status         text not null default 'received' check (status in
                   ('received','processed','duplicate','skipped','error')),
  message_id     uuid,
  error          text,
  worker_id      text,
  created_at     timestamptz not null default clock_timestamp(),
  processed_at   timestamptz
);

create index if not exists telegram_inbox_events_owner_idx
  on public.telegram_inbox_events (owner_user_id, id desc);
create index if not exists telegram_inbox_events_pending_idx
  on public.telegram_inbox_events (id) where status = 'received';

-- ---------------------------------------------------------------------------
-- google_credentials — encrypted OAuth material kept out of `profiles`.
-- No client-visible policy is ever created for this table: only the edge
-- functions (service_role) can read it.
-- ---------------------------------------------------------------------------
create table if not exists public.google_credentials (
  user_id             uuid primary key references public.profiles (id) on delete cascade,
  email               text not null,
  scopes              text[] not null default '{}',
  refresh_token_enc   text,                 -- AES-256-GCM, base64url
  access_token_enc    text,
  access_token_exp    timestamptz,
  id_token            text,
  granted_at          timestamptz not null default clock_timestamp(),
  revoked_at          timestamptz,
  updated_at          timestamptz not null default clock_timestamp()
);

create index if not exists google_credentials_expiry_idx
  on public.google_credentials (access_token_exp) where revoked_at is null;

-- ---------------------------------------------------------------------------
-- eligibility_checks — audit log for the "Google account must be > 1 year"
-- gate. Immutable, never exposed to clients.
-- ---------------------------------------------------------------------------
create table if not exists public.eligibility_checks (
  id                    uuid primary key default app.uuid_v7(),
  user_id               uuid not null references public.profiles (id) on delete cascade,
  request_id            text unique,
  provider              text not null default 'google',
  method                text not null check (method in
                          ('gmail_profile','gmail_oldest_message','drive_oldest_file','cached','manual')),
  verdict               public.verdict not null,
  account_created_at    timestamptz,
  account_age_days      integer,
  min_age_days          integer not null default 366,
  signals               jsonb not null default '{}'::jsonb,
  reason                text,
  source_ip             text,
  created_at            timestamptz not null default clock_timestamp()
);

create index if not exists eligibility_checks_user_idx
  on public.eligibility_checks (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Late FK: messages.sender_peer_id -> telegram_peers
-- ---------------------------------------------------------------------------
alter table public.messages
  drop constraint if exists messages_sender_peer_fk,
  add constraint messages_sender_peer_fk
  foreign key (sender_peer_id) references public.telegram_peers (id) on delete set null;

create index if not exists messages_peer_idx
  on public.messages (sender_peer_id, id desc) where sender_peer_id is not null;
