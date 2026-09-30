-- =============================================================================
-- 00026 — the bot platform
--
-- One platform, three faces, all of them free to run:
--
--   • Discord mechanics — slash commands with option schemas, roles and
--     automated moderation rules, per-server installs with a permission mask,
--     and webhook delivery (a `bot_events` outbox any Vercel Edge function can
--     drain).
--   • Telegram mechanics — a single bearer-token Bot API (`public.bot_api`),
--     `getUpdates` long-polling or webhooks, inline queries answered into the
--     composer, and scheduled broadcasts that repeat.
--   • @BotFather — a real account in the Messages tab that mints, configures
--     and revokes bots from inside the app. Creating a bot is free; the only
--     paid thing in the economy is a *custom profile tag*.
--
-- A bot is a real account: it gets an `auth.users` row, a `profiles` row and a
-- discriminator, so it has an avatar, a handle, a profile page and DMs that use
-- the exact same tables as a person. Nothing about messaging special-cases it.
--
-- Everything here is server-side: clients can read what they own, and every
-- mutation is an RPC or the bot token API.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. accounts can be bots
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists account_kind text not null default 'human',
  add column if not exists bot_verified boolean not null default false;

alter table public.profiles drop constraint if exists profiles_account_kind_check;
alter table public.profiles
  add constraint profiles_account_kind_check check (account_kind in ('human', 'bot', 'system'));

create index if not exists profiles_bots_idx on public.profiles (account_kind) where account_kind <> 'human';

comment on column public.profiles.account_kind is
  'human | bot | system. Bots are real profiles so every feed, chat and mention works unchanged.';

-- `account_kind`/`bot_verified` join the server-managed column list: a client
-- must not be able to promote itself to a bot (or clear the flag).
create or replace function app.guard_profile_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  -- NB: never list a *generated* column here. `username_norm` is always NULL in
  -- NEW during a BEFORE trigger (Postgres fills it after the trigger), so a
  -- comparison would report a change on every single update.
  v_protected text[] := array[
    'id', 'username', 'discriminator', 'access_state', 'access_state_reason',
    'google_email', 'google_account_created_at', 'google_account_age_days',
    'eligibility_verified_at', 'eligibility_attempts', 'eligibility_method',
    'follower_count', 'following_count', 'post_count', 'verified',
    'account_kind', 'bot_verified', 'deleted_at', 'created_at'
  ];
  v_col text;
begin
  if app.is_service_role() then
    return new;
  end if;
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  foreach v_col in array v_protected loop
    if to_jsonb(new) -> v_col is distinct from to_jsonb(old) -> v_col then
      raise exception 'these profile fields are server-managed' using errcode = '42501';
    end if;
  end loop;

  if new.last_seen_at is distinct from old.last_seen_at and new.id <> v_uid then
    raise exception 'only your own presence may be written' using errcode = '42501';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. bots
-- ---------------------------------------------------------------------------
create table if not exists public.bots (
  id                  uuid primary key default app.uuid_v7(),
  owner_id            uuid not null references public.profiles (id) on delete cascade,
  profile_id          uuid not null unique references public.profiles (id) on delete cascade,
  -- Telegram's convention: a bot handle ends in "bot". @BotFather itself is the
  -- one reserved exception, because the platform owns that name.
  username            text not null check (username ~ '^[a-z][a-z0-9_]{1,30}bot$' or username = 'botfather'),
  display_name        text not null default '' check (char_length(display_name) <= 64),
  about               text not null default '' check (char_length(about) <= 120),
  description         text not null default '' check (char_length(description) <= 512),
  avatar_path         text,
  -- The raw token is shown once, at creation or rotation, and never stored:
  -- what lives here is a hash and a display prefix.
  token_hash          text not null,
  token_prefix        text not null,
  token_rotated_at    timestamptz not null default clock_timestamp(),
  webhook_url         text check (webhook_url is null or webhook_url ~ '^https://'),
  webhook_secret      text,
  is_public           boolean not null default true,
  is_active           boolean not null default true,
  inline_enabled      boolean not null default true,
  inline_placeholder  text,
  join_groups         boolean not null default true,
  privacy_mode        boolean not null default true,
  rate_limit_per_minute smallint not null default 60 check (rate_limit_per_minute between 1 and 600),
  calls_this_minute   smallint not null default 0,
  minute_window       timestamptz not null default clock_timestamp(),
  last_used_at        timestamptz,
  is_botfather        boolean not null default false,
  created_at          timestamptz not null default clock_timestamp(),
  updated_at          timestamptz not null default clock_timestamp()
);

create unique index if not exists bots_username_key on public.bots (lower(username));
create index if not exists bots_owner_idx on public.bots (owner_id);
create unique index if not exists bots_one_botfather on public.bots (is_botfather) where is_botfather;

comment on table public.bots is
  'A bot: an account (profiles row) plus the credentials and behaviour that make it programmable. Free to create; @BotFather mints the token.';

create table if not exists public.bot_commands (
  id                 uuid primary key default app.uuid_v7(),
  bot_id             uuid not null references public.bots (id) on delete cascade,
  name               text not null check (name ~ '^[a-z0-9_-]{1,32}$'),
  description        text not null default '' check (char_length(description) <= 120),
  usage              text,
  options            jsonb not null default '[]'::jsonb,
  handler            text not null default 'builtin' check (handler in ('builtin', 'webhook')),
  builtin_action     text check (builtin_action in (
                       'mute', 'unmute', 'ban', 'unban', 'kick', 'warn', 'purge', 'pin',
                       'assign_role', 'announce', 'poll', 'echo', 'help', 'settings')),
  default_permission text not null default 'everyone'
                       check (default_permission in ('everyone', 'moderators', 'admins', 'owner')),
  is_hidden          boolean not null default false,
  position           smallint not null default 0,
  created_at         timestamptz not null default clock_timestamp()
);

create unique index if not exists bot_commands_name_key on public.bot_commands (bot_id, name);
create index if not exists bot_commands_bot_idx on public.bot_commands (bot_id, position);

comment on column public.bot_commands.options is
  'Discord-shaped application-command options: [{name, description, type, required, choices:[{name,value}]}].';

create table if not exists public.bot_installs (
  id            uuid primary key default app.uuid_v7(),
  bot_id        uuid not null references public.bots (id) on delete cascade,
  chat_id       uuid not null references public.chats (id) on delete cascade,
  community_id  uuid references public.communities (id) on delete set null,
  installed_by  uuid references public.profiles (id) on delete set null,
  permissions   bigint not null default 0,
  webhook_enabled boolean not null default true,
  is_enabled    boolean not null default true,
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp()
);

create unique index if not exists bot_installs_key on public.bot_installs (bot_id, chat_id);
create index if not exists bot_installs_chat_idx on public.bot_installs (chat_id) where is_enabled;

comment on column public.bot_installs.permissions is
  'The `app.perm_*` bitmask the installer handed the bot. A command can never exceed it — that is the Discord model.';

-- ---------------------------------------------------------------------------
-- 3. the update/event outbox (webhooks, inline queries, getUpdates)
-- ---------------------------------------------------------------------------
create table if not exists public.bot_events (
  id           uuid primary key default app.uuid_v7(),
  update_id    bigint generated always as identity,
  bot_id       uuid not null references public.bots (id) on delete cascade,
  kind         text not null check (kind in (
                 'message', 'command', 'inline_query', 'member_join', 'member_leave',
                 'reaction', 'moderation', 'broadcast', 'webhook_test')),
  chat_id      uuid references public.chats (id) on delete set null,
  message_id   uuid references public.messages (id) on delete set null,
  actor_id     uuid references public.profiles (id) on delete set null,
  payload      jsonb not null default '{}'::jsonb,
  status       text not null default 'pending' check (status in ('pending', 'delivered', 'failed')),
  attempts     smallint not null default 0,
  max_attempts smallint not null default 5,
  available_at timestamptz not null default clock_timestamp(),
  leased_until timestamptz,
  leased_by    text,
  delivered_at timestamptz,
  error        text,
  created_at   timestamptz not null default clock_timestamp()
);

create index if not exists bot_events_pending_idx
  on public.bot_events (bot_id, available_at) where status = 'pending';
create index if not exists bot_events_update_idx on public.bot_events (bot_id, update_id);
create unique index if not exists bot_events_dedupe_key
  on public.bot_events (bot_id, update_id);

comment on table public.bot_events is
  'Append-only update stream per bot. Drained either by getUpdates (offset ack, Telegram style) or by a webhook worker that leases rows.';

create table if not exists public.bot_broadcasts (
  id             uuid primary key default app.uuid_v7(),
  bot_id         uuid not null references public.bots (id) on delete cascade,
  created_by     uuid references public.profiles (id) on delete set null,
  chat_id        uuid references public.chats (id) on delete cascade,
  community_id   uuid references public.communities (id) on delete set null,
  body           text not null check (char_length(body) between 1 and 8000),
  media          jsonb,
  repeat_seconds integer check (repeat_seconds is null or repeat_seconds between 60 and 31536000),
  scheduled_for  timestamptz not null default clock_timestamp(),
  next_run_at    timestamptz not null default clock_timestamp(),
  status         text not null default 'scheduled'
                   check (status in ('scheduled', 'sent', 'canceled', 'failed')),
  sent_count     integer not null default 0,
  fail_count     integer not null default 0,
  last_run_at    timestamptz,
  last_error     text,
  created_at     timestamptz not null default clock_timestamp(),
  updated_at     timestamptz not null default clock_timestamp()
);

create index if not exists bot_broadcasts_due_idx
  on public.bot_broadcasts (next_run_at) where status = 'scheduled';

create table if not exists public.bot_inline_queries (
  id          uuid primary key default app.uuid_v7(),
  bot_id      uuid not null references public.bots (id) on delete cascade,
  user_id     uuid references public.profiles (id) on delete set null,
  chat_id     uuid references public.chats (id) on delete set null,
  query       text not null default '' check (char_length(query) <= 256),
  results     jsonb,
  answered_at timestamptz,
  created_at  timestamptz not null default clock_timestamp(),
  expires_at  timestamptz not null default clock_timestamp() + interval '2 minutes'
);

create index if not exists bot_inline_queries_user_idx on public.bot_inline_queries (user_id, created_at desc);

create table if not exists public.bot_moderation_rules (
  id           uuid primary key default app.uuid_v7(),
  bot_id       uuid not null references public.bots (id) on delete cascade,
  community_id uuid references public.communities (id) on delete cascade,
  chat_id      uuid references public.chats (id) on delete cascade,
  kind         text not null check (kind in (
                 'keyword', 'link', 'invite_link', 'mention_limit', 'caps', 'flood', 'new_account')),
  config       jsonb not null default '{}'::jsonb,
  action       text not null default 'delete' check (action in (
                 'delete', 'warn', 'mute', 'kick', 'ban', 'flag')),
  duration_minutes integer check (duration_minutes is null or duration_minutes between 1 and 525600),
  is_enabled   boolean not null default true,
  hits         bigint not null default 0,
  created_at   timestamptz not null default clock_timestamp(),
  -- A rule always targets something concrete: one chat, or a whole community
  -- the bot is installed in.
  constraint bot_rules_scope check (chat_id is not null or community_id is not null)
);

create index if not exists bot_rules_chat_idx
  on public.bot_moderation_rules (chat_id) where is_enabled;
create index if not exists bot_rules_community_idx
  on public.bot_moderation_rules (community_id) where is_enabled;

create table if not exists public.bot_warnings (
  id           uuid primary key default app.uuid_v7(),
  bot_id       uuid not null references public.bots (id) on delete cascade,
  community_id uuid references public.communities (id) on delete cascade,
  chat_id      uuid references public.chats (id) on delete set null,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  issued_by    uuid references public.profiles (id) on delete set null,
  reason       text,
  created_at   timestamptz not null default clock_timestamp()
);

create index if not exists bot_warnings_user_idx on public.bot_warnings (community_id, user_id);

alter table public.messages
  add column if not exists via_bot_id uuid references public.bots (id) on delete set null;

create index if not exists messages_via_bot_idx on public.messages (via_bot_id) where via_bot_id is not null;

comment on column public.messages.via_bot_id is
  'Set when the message came out of an inline query, so the UI can render "via @bot" like Telegram does.';

-- ---------------------------------------------------------------------------
-- 4. helpers
-- ---------------------------------------------------------------------------
-- Tokens are `mxb_<prefix>_<secret>`: 12 hex characters of prefix for display,
-- 32 hex characters of secret. The secret is stored as md5(prefix || secret) —
-- no pgcrypto dependency, and the entropy lives in the secret, not the hash.
create or replace function app.bot_token_hash(p_token text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$ select md5(coalesce(p_token, '')) $$;

create or replace function app.bot_mint_token(p_bot_id uuid)
returns text
language sql
volatile
set search_path = pg_catalog
as $$
  select 'mxb_' || substr(md5(p_bot_id::text), 1, 12) || '_'
         || substr(md5(random()::text || clock_timestamp()::text || p_bot_id::text), 1, 16)
         || substr(md5(clock_timestamp()::text || random()::text), 1, 16);
$$;

create or replace function app.bot_by_token(p_token text)
returns public.bots
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_bot public.bots%rowtype;
begin
  if p_token is null or p_token = '' then
    raise exception 'a bot token is required' using errcode = '28000';
  end if;
  select * into v_bot from public.bots b where b.token_hash = app.bot_token_hash(p_token);
  if not found or not v_bot.is_active then
    raise exception 'invalid or revoked bot token' using errcode = '28000';
  end if;
  return v_bot;
end;
$$;

comment on function app.bot_by_token(text) is
  'Resolves a bearer token to its bot. The raw token never touches the database.';

-- Simple sliding-minute budget, enforced on every token call so a runaway bot
-- cannot hammer shared infrastructure.
create or replace function app.bot_touch(p_bot_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_bot public.bots%rowtype;
begin
  update public.bots b
     set calls_this_minute = case
           when b.minute_window > clock_timestamp() - interval '1 minute' then b.calls_this_minute + 1
           else 1
         end,
         minute_window = case
           when b.minute_window > clock_timestamp() - interval '1 minute' then b.minute_window
           else clock_timestamp()
         end,
         last_used_at = clock_timestamp()
   where b.id = p_bot_id
  returning * into v_bot;

  if v_bot.calls_this_minute > v_bot.rate_limit_per_minute then
    raise exception 'rate limit exceeded for @%', v_bot.username using errcode = '53400';
  end if;
end;
$$;

create or replace function app.bot_can(p_bot_id uuid, p_chat_id uuid, p_perm bigint)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce((
    select (i.permissions & p_perm) = p_perm
      from public.bot_installs i
     where i.bot_id = p_bot_id and i.chat_id = p_chat_id and i.is_enabled
  ), false);
$$;

create or replace function app.bot_install(p_bot_id uuid, p_chat_id uuid)
returns public.bot_installs
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select * from public.bot_installs i
   where i.bot_id = p_bot_id and i.chat_id = p_chat_id and i.is_enabled;
$$;

-- The one place a bot writes into a chat: a normal message row from the bot's
-- own profile. Realtime, push, unread counts and moderation all just work.
create or replace function app.bot_reply(
  p_bot_id       uuid,
  p_chat_id      uuid,
  p_body         text,
  p_reply_to_id  uuid default null,
  p_media        jsonb default null,
  p_kind         public.message_kind default 'text',
  p_via_bot_id   uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_profile uuid;
  v_chat    public.chats%rowtype;
  v_id      uuid;
begin
  select b.profile_id into v_profile from public.bots b where b.id = p_bot_id;
  if v_profile is null then
    raise exception 'unknown bot' using errcode = '22023';
  end if;
  select * into v_chat from public.chats c where c.id = p_chat_id;
  if not found then
    raise exception 'unknown chat' using errcode = '22023';
  end if;

  insert into public.messages (chat_id, sender_id, kind, body, media, reply_to_id, via_bot_id,
                               state, sent_at)
  values (p_chat_id, v_profile, p_kind, nullif(p_body, ''), p_media, p_reply_to_id, p_via_bot_id,
          'sent', clock_timestamp())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function app.bot_enqueue(
  p_bot_id     uuid,
  p_kind       text,
  p_chat_id    uuid default null,
  p_message_id uuid default null,
  p_actor_id   uuid default null,
  p_payload    jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from public.bots b where b.id = p_bot_id and b.is_active) then
    return null;
  end if;
  insert into public.bot_events (bot_id, kind, chat_id, message_id, actor_id, payload)
  values (p_bot_id, p_kind, p_chat_id, p_message_id, p_actor_id, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- `/mute @someone 10 reason`, `/ban@GuardBot spam` — returns null when the
-- message is not a command at all.
create or replace function app.bot_parse_command(p_body text)
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $$
  with t as (
    select btrim(coalesce(p_body, '')) as body
  ), m as (
    select regexp_match(body, '^/([a-z0-9_]{1,32})(?:@([a-z0-9_]{1,32}))?(?:\s+([\s\S]*))?$') as parts
      from t
  )
  select case when m.parts is null then null else jsonb_build_object(
    'name', m.parts[1],
    'bot',  nullif(m.parts[2], ''),
    'args', btrim(coalesce(m.parts[3], '')),
    'argv', case when btrim(coalesce(m.parts[3], '')) = '' then '[]'::jsonb
                 else to_jsonb(regexp_split_to_array(btrim(m.parts[3]), '\s+')) end
  ) end
  from m;
$$;

comment on function app.bot_parse_command(text) is
  'Parses "/name", "/name@bot" and their arguments. NULL when the body is not a command.';

-- Map a permissions bitmask to the four audience levels a command can declare.
create or replace function app.bot_is_moderator(p_community_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p_community_id is not null and p_user_id is not null
     and (app.community_permissions(p_community_id, p_user_id)
          & (app.perm_manage_messages() | app.perm_kick_members() | app.perm_ban_members()
             | app.perm_moderate_members() | app.perm_administrator())) <> 0;
$$;

create or replace function app.bot_is_admin(p_community_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p_community_id is not null and p_user_id is not null
     and (app.community_permissions(p_community_id, p_user_id)
          & (app.perm_manage_community() | app.perm_administrator())) <> 0;
$$;

create or replace function app.bot_command_allowed(p_command public.bot_commands, p_user_id uuid, p_community_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case p_command.default_permission
    when 'everyone' then true
    when 'moderators' then app.bot_is_moderator(p_community_id, p_user_id)
    when 'admins' then app.bot_is_admin(p_community_id, p_user_id)
    when 'owner' then p_community_id is not null and exists (
      select 1 from public.communities c where c.id = p_community_id and c.owner_id = p_user_id)
    else false
  end;
$$;

-- Resolve "@handle", a uuid, or the author of the message being replied to.
create or replace function app.bot_target_user(
  p_chat_id uuid,
  p_message public.messages,
  p_arg     text
)
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
begin
  if p_arg ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select p.id into v_id from public.profiles p where p.id = p_arg::uuid;
  elsif p_arg <> '' then
    select p.id into v_id
      from public.profiles p
      join public.chat_participants cp on cp.user_id = p.id and cp.chat_id = p_chat_id
     where p.username_norm = lower(ltrim(p_arg, '@'))
     limit 1;
  end if;

  if v_id is null and p_message.reply_to_id is not null then
    select m.sender_id into v_id from public.messages m where m.id = p_message.reply_to_id;
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. builtin command execution
--
-- A builtin is a real moderation action the bot performs with *the installer's*
-- permissions — never more. `app.bot_can` is the ceiling for the whole install,
-- and each action additionally asserts the specific permission it needs.
-- ---------------------------------------------------------------------------
create or replace function app.bot_builtin(
  p_bot        public.bots,
  p_install    public.bot_installs,
  p_command    public.bot_commands,
  p_message    public.messages,
  p_args       text,
  p_argv       jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_chat      public.chats%rowtype;
  v_target    uuid;
  v_action    text := coalesce(p_command.builtin_action, 'help');
  v_minutes   integer;
  v_n         integer;
  v_poll_id   uuid;
  v_role      uuid;
  v_text      text;
begin
  select * into v_chat from public.chats c where c.id = p_message.chat_id;
  v_target := app.bot_target_user(p_message.chat_id, p_message, coalesce(p_argv ->> 0, ''));
  v_minutes := nullif(regexp_replace(coalesce(p_argv ->> 1, ''), '[^0-9]', '', 'g'), '')::integer;

  -- ---- moderation that needs a community -----------------------------------
  if v_action in ('mute', 'unmute', 'ban', 'unban', 'kick', 'warn', 'assign_role') then
    if p_install.community_id is null then
      return jsonb_build_object('text', 'That command only works inside a community.');
    end if;
    if not app.bot_can(p_bot.id, p_message.chat_id,
                       case v_action
                         when 'ban' then app.perm_ban_members()
                         when 'unban' then app.perm_ban_members()
                         when 'kick' then app.perm_kick_members()
                         when 'warn' then app.perm_manage_messages()
                         when 'assign_role' then app.perm_manage_roles()
                         else app.perm_moderate_members()
                       end) then
      return jsonb_build_object('text',
        'I was not installed with that permission. An admin can re-install me with it.');
    end if;
    if v_target is null then
      return jsonb_build_object('text', 'Who? Mention them (@handle) or reply to their message.');
    end if;

    if v_action = 'warn' then
      insert into public.bot_warnings (bot_id, community_id, chat_id, user_id, issued_by, reason)
      values (p_bot.id, p_install.community_id, p_message.chat_id, v_target, p_message.sender_id,
              nullif(substr(p_args, 1, 200), ''));
      select count(*) into v_n from public.bot_warnings w
       where w.community_id = p_install.community_id and w.user_id = v_target;
      return jsonb_build_object('text', format('Warning %s logged for <@%s>.', v_n, v_target),
                                'warnings', v_n);
    end if;

    if v_action = 'assign_role' then
      -- Accept a role id or a role name.
      select r.id into v_role
        from public.community_roles r
       where r.community_id = p_install.community_id
         and (r.id::text = coalesce(p_argv ->> 1, '') or lower(r.name) = lower(coalesce(p_argv ->> 1, '')));
      if v_role is null then
        return jsonb_build_object('text', 'Give me the role id: /' || p_command.name || ' @handle <role-id>');
      end if;
      perform public.community_member_set_roles(
        p_install.community_id, v_target,
        (select coalesce(array_agg(distinct r), '{}')
           from unnest(coalesce((select m.role_ids from public.community_members m
                                  where m.community_id = p_install.community_id and m.user_id = v_target),
                                '{}'::uuid[]) || v_role) as r));
      return jsonb_build_object('text', format('Role assigned to <@%s>.', v_target));
    end if;

    perform public.community_member_moderate(
      p_install.community_id, v_target, v_action,
      nullif(substr(p_args, 1, 200), ''),
      case when v_action = 'mute' then coalesce(v_minutes, 10) else null end);

    return jsonb_build_object('text', format('%s: <@%s>%s.', initcap(v_action), v_target,
      case when v_action = 'mute' then format(' for %s minutes', coalesce(v_minutes, 10)) else '' end));
  end if;

  -- ---- channel/message actions --------------------------------------------
  if v_action = 'purge' then
    if not app.bot_can(p_bot.id, p_message.chat_id, app.perm_manage_messages()) then
      return jsonb_build_object('text', 'I need Manage Messages to purge.');
    end if;
    v_n := least(greatest(coalesce(nullif(regexp_replace(coalesce(p_argv ->> 0, ''), '[^0-9]', '', 'g'), '')::integer, 10), 1), 100);
    with doomed as (
      select m.id from public.messages m
       where m.chat_id = p_message.chat_id
         and m.deleted_at is null
         and m.created_at <= p_message.created_at
       order by m.created_at desc
       limit v_n
    )
    update public.messages m
       set deleted_at = clock_timestamp()
      from doomed d
     where m.id = d.id;
    return jsonb_build_object('text', format('Purged %s message(s).', v_n), 'purged', v_n);
  end if;

  if v_action = 'pin' then
    if not app.bot_can(p_bot.id, p_message.chat_id, app.perm_manage_messages()) then
      return jsonb_build_object('text', 'I need Manage Messages to pin.');
    end if;
    if p_message.reply_to_id is null then
      return jsonb_build_object('text', 'Reply to the message you want pinned, then run the command.');
    end if;
    perform public.pin_message(p_message.reply_to_id, true);
    return jsonb_build_object('text', 'Pinned.');
  end if;

  if v_action = 'poll' then
    v_text := coalesce(p_args, '');
    if position('|' in v_text) = 0 then
      return jsonb_build_object('text', 'Ask me like: /poll Question? | first | second');
    end if;
    v_poll_id := public.poll_create(
      p_message.chat_id,
      btrim(split_part(v_text, '|', 1)),
      (select array_agg(btrim(x)) from unnest(string_to_array(v_text, '|')) with ordinality as u(x, i) where i > 1),
      'regular', true, false, null, null, null, null);
    return jsonb_build_object('text', 'Poll posted.', 'message_id', v_poll_id);
  end if;

  if v_action = 'announce' then
    if not app.bot_can(p_bot.id, p_message.chat_id, app.perm_manage_channels()) then
      return jsonb_build_object('text', 'I need Manage Channels to announce.');
    end if;
    if p_install.community_id is null then
      return jsonb_build_object('text', 'Announcements are a community feature.');
    end if;
    v_n := 0;
    for v_chat in
      select distinct c.*
        from public.chats c
        join public.community_channels ch on ch.chat_id = c.id and ch.deleted_at is null
       where ch.community_id = p_install.community_id
         and ch.kind::text in ('announcement', 'text')
         and (ch.kind::text = 'announcement' or ch.name in ('general', 'announcements'))
    loop
      perform app.bot_reply(p_bot.id, v_chat.id, nullif(substr(p_args, 1, 4000), ''));
      v_n := v_n + 1;
    end loop;
    return jsonb_build_object('text', format('Announced in %s channel(s).', v_n));
  end if;

  if v_action = 'settings' then
    return jsonb_build_object('text', format(
      E'@%s\n• installed in this chat: yes\n• permissions: %s\n• scope: %s',
      p_bot.username, p_install.permissions,
      coalesce((select c.title from public.communities c where c.id = p_install.community_id), 'direct / group')));
  end if;

  if v_action = 'echo' then
    return jsonb_build_object('text', nullif(substr(p_args, 1, 4000), ''));
  end if;

  -- 'help' and anything unknown: list the bot's public commands.
  return jsonb_build_object('text', coalesce((
    select string_agg('/' || c.name || ' — ' || c.description, E'\n' order by c.position, c.name)
      from public.bot_commands c
     where c.bot_id = p_bot.id and not c.is_hidden), 'No commands registered yet.'),
    'commands', true);
end;
$$;

comment on function app.bot_builtin(public.bots, public.bot_installs, public.bot_commands, public.messages, text, jsonb) is
  'Runs a builtin slash command. Every branch re-checks the install permission mask, so a bot can never out-rank the person who installed it.';

-- ---------------------------------------------------------------------------
-- 6. @BotFather
--
-- A normal bot account, seeded by this migration, that answers in its own DM.
-- Every command replies as a message from the bot's profile, which is why the
-- client needs no special case: the Messages tab just shows a chat.
-- ---------------------------------------------------------------------------
create or replace function app.botfather_bot_id()
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, public
as $$ select b.id from public.bots b where b.is_botfather limit 1 $$;

create or replace function app.botfather_text(p_user uuid, p_text text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_cmd     jsonb;
  v_name    text := lower(coalesce(app.bot_parse_command(p_text) ->> 'name', ''));
  v_args    text := coalesce(app.bot_parse_command(p_text) ->> 'args', '');
  v_argv    text[];
  v_bot     public.bots%rowtype;
  v_handle  text;
  v_created text;
  i         integer;
  v_help    text :=
    E'MessengerX BotFather — I make bots, and bots are free.\n\n'
    || E'/newbot <name> [handle] — create a bot, get its token\n'
    || E'/mybots — list the bots you own\n'
    || E'/token <handle> — rotate the token (the old one stops working)\n'
    || E'/setname <handle> <new name>\n'
    || E'/setabout <handle> <text>\n'
    || E'/setinline <handle> <placeholder|off>\n'
    || E'/setcommands <handle> <name - description; name2 - …>\n'
    || E'/setwebhook <handle> <https url|off>\n'
    || E'/deletebot <handle>\n\n'
    || E'Full API: POST bot_api with {token, method, payload} — getMe, sendMessage, '
    || E'answerInlineQuery, getUpdates, setMyCommands, banChatMember …';
begin
  if p_user is null then
    return 'Sign in first.';
  end if;
  if not app.access_ok(p_user) then
    return 'Your account cannot create bots yet.';
  end if;

  v_argv := case when v_args = '' then '{}'::text[] else regexp_split_to_array(v_args, '\s+') end;

  if v_name in ('start', 'help', '') then
    return v_help;
  end if;

  if v_name = 'newbot' then
    if coalesce(v_argv[1], '') = '' then
      return 'Usage: /newbot <display name> [handle]. The handle must end in "bot".';
    end if;
    -- The first argument is the display name; an optional second is the handle.
    -- Only a plausible second word is treated as a handle ("Bot" in
    -- "/newbot Delivery Bot" is part of the name, not a handle).
    v_handle := lower(regexp_replace(
      coalesce(nullif(case when char_length(coalesce(v_argv[2], '')) >= 4 and lower(v_argv[2]) <> 'bot'
                           then v_argv[2] else coalesce(v_argv[1], '') end, ''), 'my_bot'),
      '[^a-zA-Z0-9_]', '', 'g'));
    if v_handle !~ 'bot$' then
      v_handle := v_handle || 'bot';
    end if;
    if v_handle !~ '^[a-z]' then
      v_handle := 'm' || v_handle;
    end if;
    if char_length(v_handle) < 5 then
      v_handle := left(v_handle, 28) || 'x' || 'bot';
    end if;
    v_handle := left(v_handle, 32);
    -- Handle collisions get a short suffix instead of an error, which is what
    -- BotFather does.
    for i in 1..5 loop
      exit when not exists (select 1 from public.bots b where lower(b.username) = v_handle);
      v_handle := left(v_handle, 24) || substr(md5(random()::text), 1, 4) || 'bot';
    end loop;
    begin
      v_created := public.bot_create(v_handle, v_argv[1], null, true) ->> 'message';
    exception when others then
      return 'I could not create that bot: ' || sqlerrm;
    end;
    return E'Done! Here is your bot:\n\n' || v_created
      || E'\n\nKeep the token secret — anyone who has it can post as your bot.\n'
      || E'Configure it with /setcommands, /setinline and /setwebhook, or read /help.';
  end if;

  if v_name = 'mybots' then
    return coalesce((
      select string_agg(format('@%s — %s (id %s)', b.username, b.display_name, b.id), E'\n' order by b.created_at)
        from public.bots b where b.owner_id = p_user), 'You have no bots yet. Try /newbot My Bot mybot.');
  end if;

  -- The remaining commands all operate on one of the caller's own bots.
  if v_name in ('token', 'revoke', 'setname', 'setabout', 'setinline', 'setcommands', 'setwebhook', 'deletebot') then
    v_handle := lower(ltrim(coalesce(v_argv[1], ''), '@'));
    if v_handle = '' then
      return 'Which bot? ' || v_name || ' <handle> …';
    end if;
    select * into v_bot from public.bots b where lower(b.username) = v_handle and b.owner_id = p_user;
    if not found then
      return format('You own no bot called @%s.', v_handle);
    end if;

    if v_name in ('token', 'revoke') then
      return format(E'New token for @%s:\n%s\n\nThe previous token is dead. Store it somewhere safe — '
                    || 'it is shown once.', v_bot.username, public.bot_rotate_token(v_bot.id));
    end if;

    if v_name = 'setname' then
      perform public.bot_update(v_bot.id, substr(v_args, char_length(v_argv[1]) + 2), null, null, null);
      return format('@%s renamed.', v_bot.username);
    end if;

    if v_name = 'setabout' then
      perform public.bot_update(v_bot.id, null, substr(v_args, char_length(v_argv[1]) + 2), null, null);
      return format('About text updated for @%s.', v_bot.username);
    end if;

    if v_name = 'setinline' then
      perform public.bot_update(v_bot.id, null, null,
                                case when lower(v_argv[2]) in ('off', 'no', 'false') then null
                                     else substr(v_args, char_length(v_argv[1]) + 2) end);
      return case when lower(v_argv[2]) in ('off', 'no', 'false')
                  then format('Inline mode off for @%s.', v_bot.username)
                  else format('Inline placeholder set for @%s.', v_bot.username) end;
    end if;

    if v_name = 'setwebhook' then
      perform public.bot_webhook_set(v_bot.id, case when lower(v_argv[2]) in ('off', 'none') then null else v_argv[2] end);
      return 'Webhook updated.';
    end if;

    if v_name = 'setcommands' then
      perform public.bot_set_commands(v_bot.id, nullif(substr(v_args, char_length(v_argv[1]) + 2), ''),
                                      'mute - Silence a member; ban - Remove them; purge - Clear messages; help - List commands');
      return format('Commands updated for @%s. Send them as "name - description; name2 - description2".', v_bot.username);
    end if;

    if v_name = 'deletebot' then
      perform public.bot_delete(v_bot.id);
      return format('@%s is gone. Its messages stay in the chats it spoke in.', v_bot.username);
    end if;
  end if;

  return 'I did not understand that. ' || v_help;
end;
$$;

-- Route every message a person sends in their BotFather DM.
create or replace function app.botfather_handle_message(p_message public.messages)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_botfather uuid := app.botfather_bot_id();
  v_profile   uuid;
  v_reply     text;
begin
  if v_botfather is null or p_message.sender_id is null then
    return;
  end if;
  select b.profile_id into v_profile from public.bots b where b.id = v_botfather;
  if v_profile is null or p_message.sender_id = v_profile then
    return;
  end if;
  if not exists (select 1 from public.chat_participants cp
                  where cp.chat_id = p_message.chat_id and cp.user_id = v_profile and cp.left_at is null) then
    return;
  end if;

  v_reply := app.botfather_text(p_message.sender_id, coalesce(p_message.body, ''));
  perform app.bot_reply(v_botfather, p_message.chat_id, v_reply, p_message.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. triggers: dispatch, moderation, membership and reactions
-- ---------------------------------------------------------------------------
create or replace function app.bot_dispatch_message()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_cmd      jsonb;
  v_install  public.bot_installs%rowtype;
  v_bot      public.bots%rowtype;
  v_commands public.bot_commands%rowtype;
  v_author   public.profiles%rowtype;
  v_result   jsonb;
  v_payload  jsonb;
begin
  if new.sender_id is null or coalesce(new.body, '') = '' then
    return new;
  end if;

  -- Bots never trigger bots; that is how loops start.
  select * into v_author from public.profiles p where p.id = new.sender_id;
  if v_author.account_kind <> 'human' then
    return new;
  end if;

  -- @BotFather answers its own DMs with no install involved, so this runs
  -- before the install check and returns immediately for every other chat.
  perform app.botfather_handle_message(new);

  if not exists (select 1 from public.bot_installs i where i.chat_id = new.chat_id and i.is_enabled) then
    return new;
  end if;

  v_cmd := app.bot_parse_command(new.body);

  for v_install in
    select i.* from public.bot_installs i where i.chat_id = new.chat_id and i.is_enabled
  loop
    select * into v_bot from public.bots b where b.id = v_install.bot_id and b.is_active;
    continue when not found;

    if v_cmd is not null
       and (v_cmd ->> 'bot') is not null
       and lower(v_cmd ->> 'bot') <> lower(v_bot.username) then
      continue;   -- addressed to a different bot
    end if;

    v_payload := jsonb_build_object(
      'update_id', null,
      'message', jsonb_build_object(
        'id', new.id,
        'chat_id', new.chat_id,
        'author_id', new.sender_id,
        'author_username', v_author.username,
        'text', new.body,
        'created_at', new.created_at),
      'community_id', v_install.community_id);

    if v_cmd is null then
      -- Privacy mode hides ordinary chatter unless the bot is mentioned or the
      -- chat is a direct conversation with it.
      if v_bot.privacy_mode
         and position('@' || v_bot.username in lower(new.body)) = 0
         and not exists (select 1 from public.chats c
                          where c.id = new.chat_id and c.kind = 'direct') then
        continue;
      end if;
      perform app.bot_enqueue(v_bot.id, 'message', new.chat_id, new.id, new.sender_id, v_payload);
      continue;
    end if;

    select * into v_commands
      from public.bot_commands c
     where c.bot_id = v_bot.id and c.name = (v_cmd ->> 'name');
    if not found then
      perform app.bot_enqueue(v_bot.id, 'command', new.chat_id, new.id, new.sender_id,
        v_payload || jsonb_build_object('command', v_cmd ->> 'name', 'args', v_cmd ->> 'args',
                                        'known', false));
      continue;
    end if;

    if not app.bot_command_allowed(v_commands, new.sender_id, v_install.community_id) then
      perform app.bot_reply(v_bot.id, new.chat_id,
        format('You are not allowed to use /%s here.', v_commands.name), new.id);
      continue;
    end if;

    v_payload := v_payload || jsonb_build_object(
      'command', v_commands.name, 'args', v_cmd ->> 'args',
      'argv', coalesce(v_cmd -> 'argv', '[]'::jsonb), 'options', v_commands.options);

    if v_commands.handler = 'webhook' then
      perform app.bot_enqueue(v_bot.id, 'command', new.chat_id, new.id, new.sender_id, v_payload);
    else
      v_result := app.bot_builtin(v_bot, v_install, v_commands, new, v_cmd ->> 'args',
                                  coalesce(v_cmd -> 'argv', '[]'::jsonb));
      if coalesce(v_result ->> 'text', '') <> '' then
        perform app.bot_reply(v_bot.id, new.chat_id, v_result ->> 'text', new.id);
      end if;
      perform app.bot_enqueue(v_bot.id, 'command', new.chat_id, new.id, new.sender_id,
                              v_payload || jsonb_build_object('result', v_result));
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists messages_bot_dispatch on public.messages;
create trigger messages_bot_dispatch
  after insert on public.messages
  for each row execute function app.bot_dispatch_message();

create or replace function app.bot_rule_applies(p_rule public.bot_moderation_rules, p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when p_rule.chat_id is not null then p_rule.chat_id = p_chat_id
    when p_rule.community_id is not null then exists (
      select 1 from public.community_channels ch
       where ch.chat_id = p_chat_id and ch.deleted_at is null
         and ch.community_id = p_rule.community_id)
    else false
  end;
$$;

comment on function app.bot_rule_applies(public.bot_moderation_rules, uuid) is
  'A rule with a chat applies there; a rule with a community applies in that community''s channels only.';

-- Automated moderation. A BEFORE trigger returning NULL silently drops the
-- message, which is exactly "deleted on arrival" — and the hit is recorded so
-- the owner can see what their rules have been doing.
create or replace function app.bot_moderate_message()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_rule    public.bot_moderation_rules%rowtype;
  v_recent  integer;
  v_links   integer;
  v_caps    integer;
  v_letters integer;
  v_author  public.profiles%rowtype;
  v_words   text[];
begin
  if new.sender_id is null or new.kind::text <> 'text' or coalesce(new.body, '') = '' then
    return new;
  end if;

  if not exists (select 1 from public.bot_moderation_rules r
                  where r.is_enabled and app.bot_rule_applies(r, new.chat_id)) then
    return new;
  end if;

  select * into v_author from public.profiles p where p.id = new.sender_id;
  if v_author.account_kind <> 'human' then
    return new;
  end if;

  -- Community staff are never auto-moderated.
  if exists (select 1 from public.community_channels ch
              where ch.chat_id = new.chat_id and ch.deleted_at is null
                and app.bot_is_moderator(ch.community_id, new.sender_id)) then
    return new;
  end if;

  for v_rule in
    select r.* from public.bot_moderation_rules r
     where r.is_enabled and app.bot_rule_applies(r, new.chat_id)
     order by r.chat_id nulls last
  loop
    v_words := case when jsonb_typeof(v_rule.config -> 'words') = 'array'
                    then array(select jsonb_array_elements_text(v_rule.config -> 'words'))
                    else '{}'::text[] end;

    if v_rule.kind = 'keyword'
       and exists (select 1 from unnest(v_words) w
                    where lower(new.body) like '%' || lower(w) || '%') then
      null;
    elsif v_rule.kind in ('link', 'invite_link') then
      v_links := (select count(*) from regexp_matches(lower(new.body), 'https?://', 'g'));
      if v_links = 0 or (v_rule.kind = 'invite_link'
                         and position('t.me/joinchat' in lower(new.body)) = 0
                         and position('+' in new.body) = 0) then
        continue;
      end if;
    elsif v_rule.kind = 'mention_limit' then
      if (select count(*) from regexp_matches(new.body, '@[a-z0-9_]+', 'g'))
         < coalesce((v_rule.config ->> 'max')::integer, 5) then
        continue;
      end if;
    elsif v_rule.kind = 'caps' then
      v_letters := (select count(*) from regexp_matches(new.body, '[A-Za-z]', 'g'));
      v_caps := (select count(*) from regexp_matches(new.body, '[A-Z]', 'g'));
      if v_letters < 10
         or v_caps::numeric / v_letters < coalesce((v_rule.config ->> 'ratio')::numeric, 0.7) then
        continue;
      end if;
    elsif v_rule.kind = 'flood' then
      select count(*) into v_recent from public.messages m
       where m.chat_id = new.chat_id and m.sender_id = new.sender_id
         and m.created_at > clock_timestamp()
             - make_interval(secs => coalesce((v_rule.config ->> 'seconds')::integer, 10));
      if v_recent < coalesce((v_rule.config ->> 'count')::integer, 5) then
        continue;
      end if;
    elsif v_rule.kind = 'new_account' then
      if v_author.created_at < clock_timestamp()
           - make_interval(days => coalesce((v_rule.config ->> 'min_age_days')::integer, 1)) then
        continue;
      end if;
    else
      continue;
    end if;

    update public.bot_moderation_rules r set hits = r.hits + 1 where r.id = v_rule.id;

    if v_rule.action = 'flag' then
      perform app.bot_enqueue(v_rule.bot_id, 'moderation', new.chat_id, null, new.sender_id,
        jsonb_build_object('rule', v_rule.kind, 'action', 'flag', 'body', left(new.body, 500),
                           'author_id', new.sender_id));
      continue;   -- flag lets the message through
    end if;

    if v_rule.action in ('mute', 'kick', 'ban') and v_rule.community_id is not null then
      perform public.community_member_moderate(
        v_rule.community_id, new.sender_id, v_rule.action,
        'automated moderation: ' || v_rule.kind, v_rule.duration_minutes);
    end if;

    perform app.bot_enqueue(v_rule.bot_id, 'moderation', new.chat_id, null, new.sender_id,
      jsonb_build_object('rule', v_rule.kind, 'action', v_rule.action, 'body', left(new.body, 500),
                         'author_id', new.sender_id));

    return null;   -- message never lands
  end loop;

  return new;
end;
$$;

drop trigger if exists messages_bot_moderate on public.messages;
create trigger messages_bot_moderate
  before insert on public.messages
  for each row execute function app.bot_moderate_message();

-- ---------------------------------------------------------------------------
-- 8. client RPCs
-- ---------------------------------------------------------------------------
create or replace function public.bot_create(
  p_username     text,
  p_display_name text,
  p_about        text default null,
  p_inline       boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid      uuid := app.current_uid();
  v_handle   text := lower(regexp_replace(btrim(coalesce(p_username, '')), '[^a-z0-9_]', '', 'g'));
  v_token    text;
  v_bot_id   uuid;
  v_profile  uuid;
  v_name     text := nullif(left(btrim(coalesce(p_display_name, '')), 64), '');
  v_owned    integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'this account cannot create bots yet' using errcode = '42501';
  end if;

  v_handle := left(v_handle, 28);
  if v_handle !~ '^[a-z][a-z0-9_]{1,28}bot$' then
    if v_handle !~ 'bot$' then
      v_handle := v_handle || 'bot';
    end if;
    if v_handle !~ '^[a-z]' then
      v_handle := 'm' || v_handle;
    end if;
  end if;
  if v_handle !~ '^[a-z][a-z0-9_]{0,29}bot$' or char_length(v_handle) > 32 then
    raise exception 'a bot handle is 4-32 characters and must end in "bot"' using errcode = '22023';
  end if;
  if exists (select 1 from public.bots b where lower(b.username) = v_handle) then
    raise exception 'that handle is taken' using errcode = '23505';
  end if;

  select count(*) into v_owned from public.bots b where b.owner_id = v_uid;
  if v_owned >= 20 then
    raise exception 'you already own 20 bots' using errcode = '22023';
  end if;

  v_profile := gen_random_uuid();
  v_token := app.bot_mint_token(v_profile);

  -- A bot is a real account: this fires app.handle_new_user(), which builds the
  -- profile (and its discriminator) exactly like a person's.
  insert into auth.users (id, raw_app_meta_data, raw_user_meta_data)
  values (v_profile,
          jsonb_build_object('provider', 'bot'),
          jsonb_build_object('full_name', coalesce(v_name, initcap(v_handle)), 'username', v_handle));

  update public.profiles p
     set username      = v_handle,
         account_kind  = 'bot',
         bot_verified  = true,
         access_state  = 'active',
         bio           = left(coalesce(p_about, ''), 280),
         updated_at    = clock_timestamp()
   where p.id = v_profile;

  insert into public.bots (owner_id, profile_id, username, display_name, about, token_hash, token_prefix,
                           inline_enabled, inline_placeholder)
  values (v_uid, v_profile, v_handle, coalesce(v_name, initcap(v_handle)),
          left(coalesce(p_about, ''), 120), app.bot_token_hash(v_token), left(v_token, 16),
          coalesce(p_inline, true),
          case when coalesce(p_inline, true) then 'Search ' || coalesce(v_name, v_handle) end)
  returning id into v_bot_id;

  -- Sensible defaults so a fresh bot answers /help and /mute on day one.
  perform public.bot_set_commands(v_bot_id, null, null, jsonb_build_array(
    jsonb_build_object('name', 'help', 'description', 'List what this bot can do', 'builtin', 'help'),
    jsonb_build_object('name', 'mute', 'description', 'Mute a member for N minutes', 'builtin', 'mute',
                       'permission', 'moderators',
                       'options', jsonb_build_array(
                         jsonb_build_object('name', 'user', 'type', 'user', 'required', true),
                         jsonb_build_object('name', 'minutes', 'type', 'integer', 'required', false))),
    jsonb_build_object('name', 'ban', 'description', 'Ban a member', 'builtin', 'ban',
                       'permission', 'moderators'),
    jsonb_build_object('name', 'purge', 'description', 'Delete the last N messages', 'builtin', 'purge',
                       'permission', 'moderators'),
    jsonb_build_object('name', 'poll', 'description', 'Post a poll', 'builtin', 'poll')));

  return jsonb_build_object(
    'id', v_bot_id,
    'profile_id', v_profile,
    'username', v_handle,
    'display_name', coalesce(v_name, initcap(v_handle)),
    'token', v_token,
    'message', format(E'@%s is live.\nToken: %s\n\nUse it as a bearer token against bot_api, '
                      || 'or point a webhook at your own server.',
                      v_handle, v_token));
end;
$$;

comment on function public.bot_create(text, text, text, boolean) is
  'Creates a bot account and returns {id, username, token, message}. The token is shown once and never stored in plain text. Free, like everything except custom tags.';

create or replace function public.bot_update(
  p_bot_id             uuid,
  p_display_name       text default null,
  p_about              text default null,
  p_inline_placeholder text default null,
  p_description        text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_bot public.bots%rowtype;
  v_profile uuid;
  v_name text;
begin
  select * into v_bot from public.bots b where b.id = p_bot_id and b.owner_id = v_uid;
  if not found then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;

  v_name := nullif(left(btrim(coalesce(p_display_name, '')), 64), '');
  update public.bots b
     set display_name       = coalesce(v_name, b.display_name),
         about              = coalesce(nullif(left(btrim(coalesce(p_about, '')), 120), ''), b.about),
         description        = coalesce(nullif(left(btrim(coalesce(p_description, '')), 512), ''), b.description),
         inline_placeholder = coalesce(p_inline_placeholder, b.inline_placeholder),
         inline_enabled     = case when p_inline_placeholder is not null then true else b.inline_enabled end,
         updated_at         = clock_timestamp()
   where b.id = p_bot_id
  returning b.profile_id into v_profile;

  update public.profiles p
     set display_name = coalesce(v_name, p.display_name),
         bio          = coalesce(nullif(left(btrim(coalesce(p_about, '')), 280), ''), p.bio),
         updated_at   = clock_timestamp()
   where p.id = v_profile;
end;
$$;

create or replace function public.bot_rotate_token(p_bot_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_token text;
begin
  if not exists (select 1 from public.bots b where b.id = p_bot_id and b.owner_id = v_uid) then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;
  v_token := app.bot_mint_token(p_bot_id);
  update public.bots b
     set token_hash = app.bot_token_hash(v_token),
         token_prefix = left(v_token, 16),
         token_rotated_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where b.id = p_bot_id;
  return v_token;
end;
$$;

create or replace function public.bot_delete(p_bot_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_profile uuid;
begin
  select b.profile_id into v_profile from public.bots b
   where b.id = p_bot_id and b.owner_id = v_uid and b.is_active;
  if v_profile is null then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;

  -- Retirement, not erasure. Everything the bot ever said lives in people's
  -- history, and `messages_shape` (rightly) forbids a text message with no
  -- sender — so dropping the account would either break the delete or orphan
  -- the thread. The token dies, the handle is freed, the installs go.
  delete from public.bot_installs i where i.bot_id = p_bot_id;
  update public.chat_participants cp
     set left_at = clock_timestamp(), updated_at = clock_timestamp()
   where cp.user_id = v_profile and cp.left_at is null;

  update public.bots b
     set is_active = false, is_public = false, inline_enabled = false,
         webhook_url = null, webhook_secret = null,
         username = left(b.username, 12) || '_off' || substr(md5(b.id::text), 1, 4) || 'bot',
         token_hash = app.bot_token_hash(gen_random_uuid()::text),
         updated_at = clock_timestamp()
   where b.id = p_bot_id;

  update public.profiles p
     set username = left(p.username, 12) || '_off' || substr(md5(p.id::text), 1, 4) || 'bot',
         display_name = 'Retired bot',
         deleted_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where p.id = v_profile;
end;
$$;

comment on function public.bot_delete(uuid) is
  'Retires a bot: token revoked, handle freed, installs removed, history intact (Telegram and Discord behave the same way).';

create or replace function public.bot_set_commands(
  p_bot_id   uuid,
  p_spec     text default null,
  p_defaults text default null,
  p_commands jsonb default null
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_entry jsonb;
  v_parts text[];
  v_n     integer := 0;
  v_spec  text := coalesce(nullif(btrim(p_spec), ''), nullif(btrim(p_defaults), ''));
begin
  if not exists (select 1 from public.bots b where b.id = p_bot_id and b.owner_id = v_uid) then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;

  if p_commands is null and v_spec is not null then
    -- "name - description; name2 - description2" (what BotFather accepts).
    select coalesce(jsonb_agg(jsonb_build_object(
             'name', lower(btrim(split_part(btrim(part), '-', 1))),
             'description', btrim(substr(btrim(part), position('-' in btrim(part)) + 1))) ||
             jsonb_build_object('builtin', lower(btrim(split_part(btrim(part), '-', 1))))), '[]'::jsonb)
      into p_commands
      from unnest(string_to_array(v_spec, ';')) as part
     where btrim(part) <> '';
  end if;

  if p_commands is null or jsonb_typeof(p_commands) <> 'array' then
    raise exception 'nothing to set: pass a command list' using errcode = '22023';
  end if;

  delete from public.bot_commands c where c.bot_id = p_bot_id;

  for v_entry in select * from jsonb_array_elements(p_commands) loop
    v_n := v_n + 1;
    insert into public.bot_commands (bot_id, name, description, usage, options, handler,
                                     builtin_action, default_permission, is_hidden, position)
    values (
      p_bot_id,
      lower(btrim(coalesce(v_entry ->> 'name', ''))),
      left(coalesce(v_entry ->> 'description', ''), 120),
      nullif(left(coalesce(v_entry ->> 'usage', ''), 120), ''),
      coalesce(v_entry -> 'options', '[]'::jsonb),
      case when coalesce(v_entry ->> 'handler', 'builtin') = 'webhook' then 'webhook' else 'builtin' end,
      case when v_entry ->> 'builtin' in ('mute','unmute','ban','unban','kick','warn','purge','pin',
                                          'assign_role','announce','poll','echo','help','settings')
           then v_entry ->> 'builtin' else null end,
      case when v_entry ->> 'permission' in ('everyone','moderators','admins','owner')
           then v_entry ->> 'permission' else 'everyone' end,
      coalesce((v_entry ->> 'hidden')::boolean, false),
      v_n)
    on conflict (bot_id, name) do update
      set description = excluded.description, options = excluded.options,
          handler = excluded.handler, builtin_action = excluded.builtin_action,
          default_permission = excluded.default_permission, is_hidden = excluded.is_hidden,
          position = excluded.position;
  end loop;

  return v_n;
end;
$$;

-- What a bot gets when the installer does not pick a mask: enough to be a
-- useful moderator, and never more than the installer holds (see bot_install).
create or replace function app.perm_bot_default()
returns bigint
language sql
immutable
set search_path = pg_catalog, public
as $$
  select app.perm_view_channel() | app.perm_send_messages() | app.perm_manage_messages()
       | app.perm_moderate_members() | app.perm_attach_files() | app.perm_add_reactions()
       | app.perm_create_threads()
$$;

comment on function app.perm_bot_default() is
  'Default permission mask handed to a freshly installed bot, before it is clamped to the installer.';

-- Install the bot into a chat. The permission mask is clamped to what the
-- installer holds themselves, and a community install also gives the bot a
-- membership row so the ordinary channel guards let it speak.
create or replace function public.bot_install(
  p_bot_id      uuid,
  p_chat_id     uuid,
  p_permissions bigint default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid      uuid := app.current_uid();
  v_bot      public.bots%rowtype;
  v_chat     public.chats%rowtype;
  v_grants   bigint;
  v_install  uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_bot from public.bots b where b.id = p_bot_id and b.is_active;
  if not found then
    raise exception 'unknown bot' using errcode = '22023';
  end if;
  select * into v_chat from public.chats c where c.id = p_chat_id;
  if not found then
    raise exception 'unknown chat' using errcode = '22023';
  end if;
  if v_chat.kind::text = 'direct' then
    raise exception 'bots cannot be installed into a direct chat — just message them' using errcode = '22023';
  end if;
  if not v_bot.join_groups then
    raise exception '@% does not join groups or channels', v_bot.username using errcode = '42501';
  end if;

  if v_chat.community_id is not null then
    if (app.community_permissions(v_chat.community_id, v_uid) & app.perm_manage_bots()) = 0
       and not exists (select 1 from public.communities c
                        where c.id = v_chat.community_id and c.owner_id = v_uid) then
      raise exception 'you need Manage Bots here' using errcode = '42501';
    end if;
    -- You can never hand a bot more than you have.
    v_grants := coalesce(p_permissions, app.perm_bot_default())
                & app.community_permissions(v_chat.community_id, v_uid);
  else
    if not exists (select 1 from public.chat_participants cp
                    where cp.chat_id = p_chat_id and cp.user_id = v_uid and cp.left_at is null) then
      raise exception 'you are not in that chat' using errcode = '42501';
    end if;
    v_grants := coalesce(p_permissions, app.perm_bot_default());
  end if;

  insert into public.bot_installs (bot_id, chat_id, community_id, installed_by, permissions)
  values (p_bot_id, p_chat_id, v_chat.community_id, v_uid, v_grants)
  on conflict (bot_id, chat_id) do update
    set permissions = excluded.permissions, is_enabled = true,
        installed_by = excluded.installed_by, updated_at = clock_timestamp()
  returning id into v_install;

  -- The bot is a participant so it can be spoken to, mentioned and seen.
  insert into public.chat_participants (chat_id, user_id, role)
  values (p_chat_id, v_bot.profile_id, 'member')
  on conflict (chat_id, user_id) do update set left_at = null, updated_at = clock_timestamp();

  if v_chat.community_id is not null then
    insert into public.community_members (community_id, user_id, nickname)
    values (v_chat.community_id, v_bot.profile_id, v_bot.display_name)
    on conflict (community_id, user_id) do nothing;
  end if;

  perform app.bot_enqueue(v_bot.id, 'member_join', p_chat_id, null, v_uid,
    jsonb_build_object('chat_id', p_chat_id, 'installed_by', v_uid, 'permissions', v_grants));

  return v_install;
end;
$$;

create or replace function public.bot_uninstall(p_bot_id uuid, p_chat_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_chat  public.chats%rowtype;
  v_prof  uuid;
begin
  select * into v_chat from public.chats c where c.id = p_chat_id;
  if not found then
    raise exception 'unknown chat' using errcode = '22023';
  end if;
  if v_chat.community_id is not null then
    if (app.community_permissions(v_chat.community_id, v_uid) & app.perm_manage_bots()) = 0
       and not exists (select 1 from public.bots b where b.id = p_bot_id and b.owner_id = v_uid) then
      raise exception 'you need Manage Bots here' using errcode = '42501';
    end if;
  elsif not exists (select 1 from public.chat_participants cp
                     where cp.chat_id = p_chat_id and cp.user_id = v_uid and cp.left_at is null) then
    raise exception 'you are not in that chat' using errcode = '42501';
  end if;

  select b.profile_id into v_prof from public.bots b where b.id = p_bot_id;
  delete from public.bot_installs i where i.bot_id = p_bot_id and i.chat_id = p_chat_id;
  if v_chat.kind::text <> 'direct' then
    update public.chat_participants cp
       set left_at = clock_timestamp(), updated_at = clock_timestamp()
     where cp.chat_id = p_chat_id and cp.user_id = v_prof;
  end if;
end;
$$;

create or replace function public.bot_my()
returns table (
  id uuid, username text, display_name text, about text, avatar_path text,
  is_active boolean, inline_enabled boolean, webhook_url text,
  installs integer, commands integer, created_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select b.id, b.username, b.display_name, b.about, p.avatar_path,
         b.is_active, b.inline_enabled, b.webhook_url,
         (select count(*)::int from public.bot_installs i where i.bot_id = b.id),
         (select count(*)::int from public.bot_commands c where c.bot_id = b.id),
         b.created_at
    from public.bots b
    join public.profiles p on p.id = b.profile_id
   where b.owner_id = app.current_uid() and b.is_active
   order by b.created_at desc;
$$;

create or replace function public.bot_directory(p_query text default null, p_limit integer default 30)
returns table (
  id uuid, username text, display_name text, about text, avatar_path text,
  inline_enabled boolean, verified boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select b.id, b.username, b.display_name, b.about, p.avatar_path, b.inline_enabled, p.bot_verified
    from public.bots b
    join public.profiles p on p.id = b.profile_id
   where b.is_public and b.is_active
     and p.deleted_at is null
     and (p_query is null or btrim(p_query) = ''
          or b.username ilike '%' || btrim(p_query) || '%'
          or b.display_name ilike '%' || btrim(p_query) || '%')
   order by b.username
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

create or replace function public.bot_chat_commands(p_chat_id uuid)
returns table (
  bot_id uuid, username text, display_name text, avatar_path text,
  command text, description text, options jsonb, permission text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select b.id, b.username, b.display_name, p.avatar_path,
         c.name, c.description, c.options, c.default_permission
    from public.bot_installs i
    join public.bots b on b.id = i.bot_id and b.is_active
    join public.profiles p on p.id = b.profile_id
    join public.bot_commands c on c.bot_id = b.id and not c.is_hidden
   where i.chat_id = p_chat_id and i.is_enabled
     and app.is_chat_member(p_chat_id, app.current_uid())
   order by b.username, c.position, c.name;
$$;

-- The DM with @BotFather, created on demand from the Messages tab.
create or replace function public.botfather_chat()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_botprof uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  select b.profile_id into v_botprof from public.bots b where b.is_botfather limit 1;
  if v_botprof is null then
    raise exception 'BotFather is not provisioned' using errcode = '55000';
  end if;
  return public.create_direct_chat(v_botprof, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. inline queries (Telegram mechanics, answered into the composer)
-- ---------------------------------------------------------------------------
create or replace function public.bot_inline_query(p_bot text, p_query text, p_chat_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_bot public.bots%rowtype;
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  select * into v_bot from public.bots b
   where lower(b.username) = lower(ltrim(coalesce(p_bot, ''), '@')) and b.is_active and b.inline_enabled;
  if not found then
    raise exception 'no inline bot called %', p_bot using errcode = '22023';
  end if;

  insert into public.bot_inline_queries (bot_id, user_id, chat_id, query)
  values (v_bot.id, v_uid, p_chat_id, left(coalesce(p_query, ''), 256))
  returning id into v_id;

  perform app.bot_enqueue(v_bot.id, 'inline_query', p_chat_id, null, v_uid,
    jsonb_build_object('inline_query_id', v_id, 'query', left(coalesce(p_query, ''), 256),
                       'from', jsonb_build_object('id', v_uid)));

  return v_id;
end;
$$;

create or replace function public.bot_inline_result(p_query_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'id', q.id, 'query', q.query, 'answered', q.answered_at is not null,
    'results', coalesce(q.results, '[]'::jsonb), 'expired', q.expires_at < clock_timestamp())
    from public.bot_inline_queries q
   where q.id = p_query_id and q.user_id = app.current_uid();
$$;

-- Sending a chosen inline result into a chat, marked "via @bot" (Telegram's
-- hidden gem: the message comes from you, credited to the bot).
create or replace function public.bot_inline_send(
  p_query_id uuid,
  p_result_id text,
  p_chat_id uuid,
  p_body text default null,
  p_media jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_query public.bot_inline_queries%rowtype;
  v_body  text := p_body;
  v_media jsonb := p_media;
  v_hit   jsonb;
begin
  select * into v_query from public.bot_inline_queries q
   where q.id = p_query_id and q.user_id = v_uid and q.expires_at > clock_timestamp();
  if not found then
    raise exception 'that inline query expired' using errcode = '22023';
  end if;
  if not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'you are not in that chat' using errcode = '42501';
  end if;

  if p_result_id is not null and jsonb_typeof(v_query.results) = 'array' then
    select r into v_hit from jsonb_array_elements(v_query.results) r
     where coalesce(r ->> 'id', '') = p_result_id;
    if v_hit is not null then
      v_body := coalesce(v_body, v_hit ->> 'text', v_hit ->> 'title');
      if v_media is null and (v_hit ? 'url' or v_hit ? 'photo_url') then
        v_media := jsonb_build_object('url', coalesce(v_hit ->> 'url', v_hit ->> 'photo_url'));
      end if;
    end if;
  end if;

  return app.bot_reply(v_query.bot_id, p_chat_id, v_body, null, v_media, 'text', v_query.bot_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. webhooks, moderation rules and broadcasts (owner-facing)
-- ---------------------------------------------------------------------------
create or replace function public.bot_webhook_set(p_bot_id uuid, p_url text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_secret text;
begin
  if not exists (select 1 from public.bots b where b.id = p_bot_id and b.owner_id = v_uid) then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;
  if p_url is not null and p_url <> '' and p_url !~ '^https://' then
    raise exception 'a webhook must be an https URL' using errcode = '22023';
  end if;

  v_secret := substr(md5(random()::text || clock_timestamp()::text), 1, 32);
  update public.bots b
     set webhook_url = nullif(btrim(coalesce(p_url, '')), ''),
         webhook_secret = case when nullif(btrim(coalesce(p_url, '')), '') is null then null else v_secret end,
         updated_at = clock_timestamp()
   where b.id = p_bot_id;
  return v_secret;
end;
$$;

comment on function public.bot_webhook_set(uuid, text) is
  'Sets (or clears) the delivery URL and returns the signing secret the dispatcher sends as X-Bot-Secret. Shown once.';

create or replace function public.bot_rules_save(
  p_bot_id      uuid,
  p_rule_id     uuid default null,
  p_kind        text default 'keyword',
  p_config      jsonb default '{}'::jsonb,
  p_action      text default 'delete',
  p_chat_id     uuid default null,
  p_community_id uuid default null,
  p_duration_minutes integer default null,
  p_is_enabled  boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if not exists (select 1 from public.bots b where b.id = p_bot_id and b.owner_id = v_uid) then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;
  if p_kind not in ('keyword','link','invite_link','mention_limit','caps','flood','new_account') then
    raise exception 'unknown rule kind %', p_kind using errcode = '22023';
  end if;
  if p_action not in ('delete','warn','mute','kick','ban','flag') then
    raise exception 'unknown rule action %', p_action using errcode = '22023';
  end if;

  if p_rule_id is null then
    insert into public.bot_moderation_rules (bot_id, community_id, chat_id, kind, config, action,
                                             duration_minutes, is_enabled)
    values (p_bot_id, p_community_id, p_chat_id, p_kind, coalesce(p_config, '{}'::jsonb), p_action,
            p_duration_minutes, coalesce(p_is_enabled, true))
    returning id into v_id;
  else
    update public.bot_moderation_rules r
       set kind = p_kind, config = coalesce(p_config, r.config), action = p_action,
           chat_id = p_chat_id, community_id = p_community_id,
           duration_minutes = p_duration_minutes, is_enabled = coalesce(p_is_enabled, r.is_enabled)
     where r.id = p_rule_id and r.bot_id = p_bot_id
    returning id into v_id;
    if v_id is null then
      raise exception 'unknown rule' using errcode = '22023';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.bot_rules_list(p_bot_id uuid)
returns setof public.bot_moderation_rules
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select r.* from public.bot_moderation_rules r
   where r.bot_id = p_bot_id
     and exists (select 1 from public.bots b where b.id = r.bot_id and b.owner_id = app.current_uid())
   order by r.created_at desc;
$$;

create or replace function public.bot_broadcast_schedule(
  p_bot_id        uuid,
  p_body          text,
  p_chat_id       uuid default null,
  p_community_id  uuid default null,
  p_send_at       timestamptz default null,
  p_repeat_seconds integer default null,
  p_media         jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if not exists (select 1 from public.bots b where b.id = p_bot_id and b.owner_id = v_uid) then
    raise exception 'that is not your bot' using errcode = '42501';
  end if;
  if p_chat_id is null and p_community_id is null then
    raise exception 'a broadcast needs a chat or a community' using errcode = '22023';
  end if;
  if p_chat_id is not null then
    if not exists (select 1 from public.bot_installs i
                    where i.bot_id = p_bot_id and i.chat_id = p_chat_id and i.is_enabled
                      and app.bot_can(p_bot_id, p_chat_id, app.perm_send_messages())) then
      raise exception 'the bot is not installed here with permission to post' using errcode = '42501';
    end if;
  end if;

  insert into public.bot_broadcasts (bot_id, created_by, chat_id, community_id, body, media,
                                     repeat_seconds, scheduled_for, next_run_at)
  values (p_bot_id, v_uid, p_chat_id, p_community_id, left(p_body, 8000), p_media,
          p_repeat_seconds, coalesce(p_send_at, clock_timestamp()), coalesce(p_send_at, clock_timestamp()))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.bot_broadcast_list(p_bot_id uuid)
returns table (
  id uuid, chat_id uuid, community_id uuid, body text, status text,
  scheduled_for timestamptz, next_run_at timestamptz, repeat_seconds integer,
  sent_count integer, fail_count integer, last_error text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select s.id, s.chat_id, s.community_id, s.body, s.status, s.scheduled_for, s.next_run_at,
         s.repeat_seconds, s.sent_count, s.fail_count, s.last_error
    from public.bot_broadcasts s
   where s.bot_id = p_bot_id
     and exists (select 1 from public.bots b where b.id = s.bot_id and b.owner_id = app.current_uid())
   order by s.created_at desc
   limit 100;
$$;

create or replace function public.bot_broadcast_cancel(p_broadcast_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.bot_broadcasts s
     set status = 'canceled', updated_at = clock_timestamp()
   where s.id = p_broadcast_id
     and exists (select 1 from public.bots b where b.id = s.bot_id and b.owner_id = app.current_uid());
  if not found then
    raise exception 'unknown broadcast' using errcode = '22023';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. service-role workers (Vercel Edge functions on any cron)
-- ---------------------------------------------------------------------------
create or replace function app.claim_bot_events(
  p_worker        text,
  p_limit         integer default 50,
  p_lease_seconds integer default 60
)
returns setof public.bot_events
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  return query
  with due as (
    select e.id
      from public.bot_events e
      join public.bots b on b.id = e.bot_id
     where b.is_active
       and b.webhook_url is not null
       and e.status = 'pending'
       and e.available_at <= clock_timestamp()
       and e.attempts < e.max_attempts
       and (e.leased_until is null or e.leased_until < clock_timestamp())
     order by e.update_id
     limit least(greatest(coalesce(p_limit, 50), 1), 200)
     for update of e skip locked
  )
  update public.bot_events e
     set leased_until = clock_timestamp() + make_interval(secs => least(greatest(p_lease_seconds, 5), 900)),
         leased_by = p_worker,
         attempts = e.attempts + 1
    from due
   where e.id = due.id
  returning e.*;
end;
$$;

create or replace function app.bot_event_ack(p_event_id uuid, p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_ok then
    update public.bot_events e
       set status = 'delivered', delivered_at = clock_timestamp(), leased_until = null, error = null
     where e.id = p_event_id;
  else
    update public.bot_events e
       set status = case when e.attempts >= e.max_attempts then 'failed' else 'pending' end,
           error = left(coalesce(p_error, 'delivery failed'), 500),
           available_at = clock_timestamp() + make_interval(secs => least(300, 5 * e.attempts * e.attempts)),
           leased_until = null
     where e.id = p_event_id;
  end if;
end;
$$;

create or replace function app.run_bot_broadcasts(p_limit integer default 20)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job   public.bot_broadcasts%rowtype;
  v_chat  uuid;
  v_sent  integer;
  v_n     integer := 0;
begin
  for v_job in
    select s.* from public.bot_broadcasts s
     where s.status = 'scheduled' and s.next_run_at <= clock_timestamp()
     order by s.next_run_at
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
     for update skip locked
  loop
    v_sent := 0;
    begin
      if v_job.chat_id is not null then
        perform app.bot_reply(v_job.bot_id, v_job.chat_id, v_job.body, null, v_job.media);
        v_sent := 1;
      else
        for v_chat in
          select distinct ch.chat_id
            from public.community_channels ch
            join public.bot_installs i on i.chat_id = ch.chat_id and i.bot_id = v_job.bot_id and i.is_enabled
           where ch.community_id = v_job.community_id and ch.deleted_at is null
             and app.bot_can(v_job.bot_id, ch.chat_id, app.perm_send_messages())
        loop
          perform app.bot_reply(v_job.bot_id, v_chat, v_job.body, null, v_job.media);
          v_sent := v_sent + 1;
        end loop;
      end if;

      update public.bot_broadcasts s
         set sent_count = s.sent_count + v_sent,
             last_run_at = clock_timestamp(),
             last_error = null,
             next_run_at = case when s.repeat_seconds is null then s.next_run_at
                                else clock_timestamp() + make_interval(secs => s.repeat_seconds) end,
             status = case when s.repeat_seconds is null then 'sent' else 'scheduled' end,
             updated_at = clock_timestamp()
       where s.id = v_job.id;
    exception when others then
      update public.bot_broadcasts s
         set fail_count = s.fail_count + 1, last_error = left(sqlerrm, 500),
             last_run_at = clock_timestamp(),
             next_run_at = case when s.repeat_seconds is null then s.next_run_at
                                else clock_timestamp() + make_interval(secs => s.repeat_seconds) end,
             status = case when s.repeat_seconds is null then 'failed' else 'scheduled' end,
             updated_at = clock_timestamp()
       where s.id = v_job.id;
    end;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

comment on function app.claim_bot_events(text, integer, integer) is
  'Leases pending webhook updates (FOR UPDATE SKIP LOCKED). Any scheduler can drive it: a Vercel cron, a worker, or getUpdates.';

-- ---------------------------------------------------------------------------
-- 12. the unified Bot API — one bearer token, Telegram-shaped methods
--
-- A bot is a server: it holds a token and calls `bot_api` with a method and a
-- payload. Webhooks work too (the outbox + claim/ack above), so an existing
-- Telegram or Discord bot can be ported without a rewrite.
-- ---------------------------------------------------------------------------
create or replace function app.bot_api_dispatch(p_bot public.bots, p_method text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_chat_id  uuid;
  v_new_id   uuid;
  v_profile  uuid;
  v_user     uuid;
  v_offset   bigint;
  v_limit    integer;
  v_commands jsonb;
  v_entry    jsonb;
begin
  v_chat_id := nullif(coalesce(p_payload ->> 'chat_id', ''), '')::uuid;
  if v_chat_id is null and coalesce(p_payload ->> 'chat_id', '') like '@%' then
    select c.id into v_chat_id from public.chats c
     where lower(c.handle) = lower(ltrim(p_payload ->> 'chat_id', '@'));
  end if;
  v_profile := p_bot.profile_id;

  case lower(coalesce(p_method, ''))

    when 'getme' then
      return jsonb_build_object(
        'id', v_profile, 'bot_id', p_bot.id, 'username', p_bot.username,
        'display_name', p_bot.display_name, 'about', p_bot.about,
        'inline_enabled', p_bot.inline_enabled, 'can_join_groups', p_bot.join_groups,
        'privacy_mode', p_bot.privacy_mode);

    when 'sendmessage' then
      if v_chat_id is null then
        raise exception 'chat_id is required' using errcode = '22023';
      end if;
      if not exists (select 1 from public.chats c where c.id = v_chat_id) then
        raise exception 'chat not found' using errcode = '22023';
      end if;
      -- Group traffic needs the install (and its permission); a DM with the bot
      -- is always allowed, which is how a person talks to a bot at all.
      if exists (select 1 from public.chats c where c.id = v_chat_id and c.kind::text <> 'direct') then
        if not exists (select 1 from public.bot_installs i
                        where i.bot_id = p_bot.id and i.chat_id = v_chat_id and i.is_enabled) then
          raise exception 'the bot is not installed in that chat' using errcode = '42501';
        end if;
        if not app.bot_can(p_bot.id, v_chat_id, app.perm_send_messages()) then
          raise exception 'the bot may not post in that chat' using errcode = '42501';
        end if;
      end if;
      if coalesce(p_payload ->> 'text', '') = '' and p_payload -> 'media' is null then
        raise exception 'text or media is required' using errcode = '22023';
      end if;
      v_new_id := app.bot_reply(
        p_bot.id, v_chat_id, left(coalesce(p_payload ->> 'text', ''), 8000),
        nullif(coalesce(p_payload ->> 'reply_to_message_id', ''), '')::uuid,
        p_payload -> 'media');
      return jsonb_build_object('message_id', v_new_id, 'date', clock_timestamp(),
                                'chat_id', v_chat_id, 'from', v_profile);

    when 'editmessagetext' then
      if not exists (select 1 from public.messages m
                      where m.id = nullif(coalesce(p_payload ->> 'message_id', ''), '')::uuid
                        and m.sender_id = v_profile and m.deleted_at is null) then
        raise exception 'message not found' using errcode = '22023';
      end if;
      update public.messages m
         set body = left(coalesce(p_payload ->> 'text', ''), 8000)
       where m.id = nullif(coalesce(p_payload ->> 'message_id', ''), '')::uuid;
      return jsonb_build_object('edited', true);

    when 'deletemessage' then
      update public.messages m
         set deleted_at = clock_timestamp()
       where m.id = nullif(coalesce(p_payload ->> 'message_id', ''), '')::uuid
         and m.sender_id = v_profile and m.deleted_at is null;
      return jsonb_build_object('deleted', found);

    when 'pinchatmessage' then
      if not app.bot_can(p_bot.id, v_chat_id, app.perm_manage_messages()) then
        raise exception 'the bot needs Manage Messages' using errcode = '42501';
      end if;
      perform public.pin_message(nullif(coalesce(p_payload ->> 'message_id', ''), '')::uuid, true);
      return jsonb_build_object('pinned', true);

    when 'unpinchatmessage' then
      perform public.pin_message(nullif(coalesce(p_payload ->> 'message_id', ''), '')::uuid, false);
      return jsonb_build_object('pinned', false);

    when 'sendchataction' then
      update public.chat_participants cp
         set updated_at = clock_timestamp()
       where cp.chat_id = v_chat_id and cp.user_id = v_profile;
      return jsonb_build_object('action', coalesce(p_payload ->> 'action', 'typing'));

    when 'getchat' then
      return coalesce((
        select jsonb_build_object('id', c.id, 'title', c.title, 'kind', c.kind::text,
                                  'handle', c.handle, 'is_public', c.is_public,
                                  'member_count', c.subscriber_count)
          from public.chats c where c.id = v_chat_id), 'null'::jsonb);

    when 'getchatmember' then
      v_user := nullif(coalesce(p_payload ->> 'user_id', ''), '')::uuid;
      return coalesce((
        select jsonb_build_object('user_id', cp.user_id, 'role', cp.role::text,
                                  'joined_at', cp.joined_at, 'is_member', cp.left_at is null)
          from public.chat_participants cp where cp.chat_id = v_chat_id and cp.user_id = v_user),
        'null'::jsonb);

    when 'banchatmember' then
      v_user := nullif(coalesce(p_payload ->> 'user_id', ''), '')::uuid;
      if not app.bot_can(p_bot.id, v_chat_id, app.perm_ban_members()) then
        raise exception 'the bot needs Ban Members' using errcode = '42501';
      end if;
      perform public.community_member_moderate(
        (select c.community_id from public.chats c where c.id = v_chat_id),
        v_user, 'ban', coalesce(p_payload ->> 'reason', 'via bot_api'), null);
      return jsonb_build_object('banned', true);

    when 'unbanchatmember' then
      v_user := nullif(coalesce(p_payload ->> 'user_id', ''), '')::uuid;
      if not app.bot_can(p_bot.id, v_chat_id, app.perm_ban_members()) then
        raise exception 'the bot needs Ban Members' using errcode = '42501';
      end if;
      perform public.community_member_moderate(
        (select c.community_id from public.chats c where c.id = v_chat_id),
        v_user, 'unban', null, null);
      return jsonb_build_object('unbanned', true);

    when 'restrictchatmember' then
      v_user := nullif(coalesce(p_payload ->> 'user_id', ''), '')::uuid;
      if not app.bot_can(p_bot.id, v_chat_id, app.perm_moderate_members()) then
        raise exception 'the bot needs Timeout Members' using errcode = '42501';
      end if;
      perform public.community_member_moderate(
        (select c.community_id from public.chats c where c.id = v_chat_id),
        v_user, 'mute', coalesce(p_payload ->> 'reason', 'via bot_api'),
        coalesce((p_payload ->> 'minutes')::integer, 10));
      return jsonb_build_object('muted', true);

    when 'promotechatmember' then
      if not app.bot_can(p_bot.id, v_chat_id, app.perm_manage_roles()) then
        raise exception 'the bot needs Manage Roles' using errcode = '42501';
      end if;
      perform public.community_member_set_roles(
        (select c.community_id from public.chats c where c.id = v_chat_id),
        nullif(coalesce(p_payload ->> 'user_id', ''), '')::uuid,
        coalesce((select array_agg(r.value::uuid) from jsonb_array_elements_text(coalesce(p_payload -> 'role_ids', '[]'::jsonb)) r), '{}'::uuid[]));
      return jsonb_build_object('promoted', true);

    when 'getchatmembercount' then
      return jsonb_build_object('count', coalesce((
        select count(*) from public.chat_participants cp
         where cp.chat_id = v_chat_id and cp.left_at is null), 0));

    when 'setmycommands' then
      v_commands := coalesce(p_payload -> 'commands', '[]'::jsonb);
      perform public.bot_set_commands(p_bot.id, null, null,
        (select coalesce(jsonb_agg(jsonb_build_object(
           'name', e ->> 'command',
           'description', e ->> 'description',
           'options', coalesce(e -> 'options', '[]'::jsonb),
           'builtin', e ->> 'builtin',
           'handler', e ->> 'handler',
           'permission', e ->> 'permission')), '[]'::jsonb)
           from jsonb_array_elements(v_commands) e));
      return jsonb_build_object('set', jsonb_array_length(v_commands));

    when 'getmycommands' then
      return coalesce((
        select jsonb_agg(jsonb_build_object('command', c.name, 'description', c.description,
                                            'options', c.options, 'handler', c.handler,
                                            'builtin', c.builtin_action,
                                            'permission', c.default_permission)
                          order by c.position, c.name)
          from public.bot_commands c where c.bot_id = p_bot.id), '[]'::jsonb);

    when 'setwebhook' then
      perform public.bot_webhook_set(p_bot.id, nullif(coalesce(p_payload ->> 'url', ''), ''));
      return jsonb_build_object('webhook', coalesce(p_payload ->> 'url', ''));

    when 'deletewebhook' then
      perform public.bot_webhook_set(p_bot.id, null);
      return jsonb_build_object('webhook', null);

    when 'answerinlinequery' then
      if not exists (select 1 from public.bot_inline_queries q
                      where q.id = nullif(coalesce(p_payload ->> 'inline_query_id', ''), '')::uuid
                        and q.bot_id = p_bot.id) then
        raise exception 'unknown inline query' using errcode = '22023';
      end if;
      update public.bot_inline_queries q
         set results = coalesce(p_payload -> 'results', '[]'::jsonb),
             answered_at = clock_timestamp()
       where q.id = nullif(coalesce(p_payload ->> 'inline_query_id', ''), '')::uuid;
      return jsonb_build_object('answered', true);

    when 'leavechat' then
      perform public.bot_uninstall(p_bot.id, v_chat_id);
      return jsonb_build_object('left', true);

    when 'getupdates' then
      v_offset := greatest(coalesce((p_payload ->> 'offset')::bigint, 0), 0);
      v_limit  := least(greatest(coalesce((p_payload ->> 'limit')::integer, 100), 1), 100);
      -- Telegram semantics: confirming an offset retires everything below it.
      if v_offset > 0 then
        update public.bot_events e
           set status = 'delivered', delivered_at = clock_timestamp(), leased_until = null
         where e.bot_id = p_bot.id and e.update_id < v_offset and e.status = 'pending';
      end if;
      return coalesce((
        select jsonb_agg(jsonb_build_object(
                 'update_id', t.update_id, 'kind', t.kind, 'chat_id', t.chat_id,
                 'message_id', t.message_id, 'actor_id', t.actor_id,
                 'payload', t.payload, 'created_at', t.created_at) order by t.update_id)
          from (select e.* from public.bot_events e
                 where e.bot_id = p_bot.id
                   and e.update_id >= v_offset
                   and e.status <> 'failed'
                 order by e.update_id
                 limit v_limit) t), '[]'::jsonb);

    else
      raise exception 'unknown method %', p_method using errcode = '22023';
  end case;
end;
$$;

create or replace function public.bot_api(p_token text, p_method text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_bot public.bots%rowtype;
begin
  v_bot := app.bot_by_token(p_token);
  perform app.bot_touch(v_bot.id);
  return jsonb_build_object('ok', true,
                            'result', app.bot_api_dispatch(v_bot, lower(coalesce(p_method, '')), coalesce(p_payload, '{}'::jsonb)));
exception when others then
  -- Telegram shape: failures are data, not SQL errors, so a bot's HTTP client
  -- can handle them uniformly.
  return jsonb_build_object('ok', false, 'error_code', 400, 'description', sqlerrm);
end;
$$;

comment on function public.bot_api(text, text, jsonb) is
  'The whole Bot API. The token is the credential, so it is callable without a session: getMe, sendMessage, editMessageText, deleteMessage, pinChatMessage, getChat, getChatMember, banChatMember, restrictChatMember, promoteChatMember, setMyCommands, answerInlineQuery, setWebhook, getUpdates.';

-- A direct chat with a bot has no install row, but it should still show the
-- bot's command palette (the "/" menu), so participants of a direct chat count.
create or replace function public.bot_chat_commands(p_chat_id uuid)
returns table (
  bot_id uuid, username text, display_name text, avatar_path text,
  command text, description text, options jsonb, permission text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select b.id, b.username, b.display_name, p.avatar_path,
         c.name, c.description, c.options, c.default_permission
    from public.bots b
    join public.profiles p on p.id = b.profile_id
    join public.bot_commands c on c.bot_id = b.id and not c.is_hidden
   where b.is_active
     and app.is_chat_member(p_chat_id, app.current_uid())
     and (
       exists (select 1 from public.bot_installs i
                where i.bot_id = b.id and i.chat_id = p_chat_id and i.is_enabled)
       or exists (select 1 from public.chats ch
                   join public.chat_participants cp on cp.chat_id = ch.id
                  where ch.id = p_chat_id and ch.kind::text = 'direct'
                    and cp.user_id = b.profile_id and cp.left_at is null)
     )
   order by b.username, c.position, c.name;
$$;

-- ---------------------------------------------------------------------------
-- 13. RLS + grants. Nothing here is client-writable; the token API and the
--     owner RPCs are the only write paths.
-- ---------------------------------------------------------------------------
alter table public.bots                  enable row level security;
alter table public.bot_commands          enable row level security;
alter table public.bot_installs          enable row level security;
alter table public.bot_events            enable row level security;
alter table public.bot_broadcasts        enable row level security;
alter table public.bot_inline_queries    enable row level security;
alter table public.bot_moderation_rules  enable row level security;
alter table public.bot_warnings          enable row level security;

drop policy if exists bots_read on public.bots;
create policy bots_read on public.bots
  for select to authenticated
  using (is_public or owner_id = (select app.current_uid()));

drop policy if exists bot_commands_read on public.bot_commands;
create policy bot_commands_read on public.bot_commands
  for select to authenticated
  using (exists (select 1 from public.bots b where b.id = bot_id and (b.is_public or b.owner_id = (select app.current_uid()))));

drop policy if exists bot_installs_read on public.bot_installs;
create policy bot_installs_read on public.bot_installs
  for select to authenticated
  using (app.is_chat_member(chat_id, (select app.current_uid()))
         or exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select app.current_uid())));

-- the update stream is the bot's business, not a client's
drop policy if exists bot_events_none on public.bot_events;
create policy bot_events_owner_none on public.bot_events
  for select to authenticated
  using (exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select app.current_uid())));

drop policy if exists bot_broadcasts_own on public.bot_broadcasts;
create policy bot_broadcasts_own on public.bot_broadcasts
  for select to authenticated
  using (exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select app.current_uid())));

drop policy if exists bot_inline_own on public.bot_inline_queries;
create policy bot_inline_own on public.bot_inline_queries
  for select to authenticated
  using (user_id = (select app.current_uid())
         or exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select app.current_uid())));

drop policy if exists bot_rules_own on public.bot_moderation_rules;
create policy bot_rules_own on public.bot_moderation_rules
  for select to authenticated
  using (exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select app.current_uid())));

drop policy if exists bot_warnings_own on public.bot_warnings;
create policy bot_warnings_own on public.bot_warnings
  for select to authenticated
  using (exists (select 1 from public.bots b where b.id = bot_id and b.owner_id = (select app.current_uid()))
         or user_id = (select app.current_uid()));

-- Column-level reads: a client may see a bot, never its credentials.
grant select (id, owner_id, profile_id, username, display_name, about, description, avatar_path,
              webhook_url, is_public, is_active, inline_enabled, inline_placeholder, join_groups,
              privacy_mode, rate_limit_per_minute, is_botfather, created_at, updated_at)
  on public.bots to authenticated;
grant select on public.bot_commands, public.bot_installs, public.bot_broadcasts,
                public.bot_moderation_rules, public.bot_warnings to authenticated;
-- The update stream and inline queries stay readable (RLS narrows both to the
-- bot's owner / the asker), because realtime on them is how a composer shows an
-- inline answer the moment the bot posts it.
grant select on public.bot_events, public.bot_inline_queries to authenticated;
revoke all on public.bots, public.bot_commands, public.bot_installs, public.bot_events,
              public.bot_broadcasts, public.bot_inline_queries, public.bot_moderation_rules,
              public.bot_warnings from anon;
revoke insert, update, delete on public.bots, public.bot_commands, public.bot_installs,
       public.bot_events, public.bot_broadcasts, public.bot_inline_queries,
       public.bot_moderation_rules, public.bot_warnings from public, anon, authenticated;

grant all on public.bots, public.bot_commands, public.bot_installs, public.bot_events,
             public.bot_broadcasts, public.bot_inline_queries, public.bot_moderation_rules,
             public.bot_warnings to service_role;

grant execute on function
  public.bot_create(text, text, text, boolean),
  public.bot_update(uuid, text, text, text, text),
  public.bot_rotate_token(uuid),
  public.bot_delete(uuid),
  public.bot_set_commands(uuid, text, text, jsonb),
  public.bot_install(uuid, uuid, bigint),
  public.bot_uninstall(uuid, uuid),
  public.bot_my(),
  public.bot_directory(text, integer),
  public.bot_chat_commands(uuid),
  public.botfather_chat(),
  public.bot_inline_query(text, text, uuid),
  public.bot_inline_result(uuid),
  public.bot_inline_send(uuid, text, uuid, text, jsonb),
  public.bot_webhook_set(uuid, text),
  public.bot_rules_save(uuid, uuid, text, jsonb, text, uuid, uuid, integer, boolean),
  public.bot_rules_list(uuid),
  public.bot_broadcast_schedule(uuid, text, uuid, uuid, timestamptz, integer, jsonb),
  public.bot_broadcast_list(uuid),
  public.bot_broadcast_cancel(uuid)
  to authenticated;

revoke execute on function app.bot_token_hash(text), app.bot_mint_token(uuid),
  app.bot_by_token(text), app.bot_touch(uuid), app.bot_reply(uuid, uuid, text, uuid, jsonb, public.message_kind, uuid),
  app.bot_enqueue(uuid, text, uuid, uuid, uuid, jsonb), app.bot_builtin(public.bots, public.bot_installs, public.bot_commands, public.messages, text, jsonb),
  app.botfather_text(uuid, text), app.botfather_handle_message(public.messages),
  app.bot_dispatch_message(), app.bot_moderate_message(), app.bot_rule_applies(public.bot_moderation_rules, uuid),
  app.claim_bot_events(text, integer, integer), app.bot_event_ack(uuid, boolean, text),
  app.run_bot_broadcasts(integer), app.bot_api_dispatch(public.bots, text, jsonb),
  app.bot_command_allowed(public.bot_commands, uuid, uuid), app.bot_target_user(uuid, public.messages, text)
  from public, anon, authenticated;

-- The token API carries its own credential, so a bot backend needs no session.
grant execute on function public.bot_api(text, text, jsonb) to anon, authenticated, service_role;
grant execute on function app.perm_bot_default() to authenticated;
grant execute on function app.claim_bot_events(text, integer, integer),
                          app.bot_event_ack(uuid, boolean, text),
                          app.run_bot_broadcasts(integer) to service_role;
grant execute on function app.bot_by_token(text), app.bot_touch(uuid),
                          app.bot_reply(uuid, uuid, text, uuid, jsonb, public.message_kind, uuid),
                          app.bot_enqueue(uuid, text, uuid, uuid, uuid, jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 14. seed @BotFather
--
-- Provisioned here rather than by an edge function so a self-hosted install has
-- bot creation on first boot — no deploy step, no external service.
-- ---------------------------------------------------------------------------
do $$
declare
  v_profile uuid := '00000000-0000-4000-8000-00000000b07f';
  v_bot     uuid;
begin
  if exists (select 1 from public.bots b where b.is_botfather) then
    return;
  end if;

  if not exists (select 1 from auth.users u where u.id = v_profile) then
    insert into auth.users (id, raw_app_meta_data, raw_user_meta_data)
    values (v_profile,
            jsonb_build_object('provider', 'bot'),
            jsonb_build_object('full_name', 'BotFather', 'username', 'botfather'));
  end if;

  update public.profiles p
     set username     = 'botfather',
         display_name = 'BotFather',
         bio          = 'I make bots. Free, like everything else here.',
         account_kind = 'system',
         bot_verified = true,
         access_state = 'active',
         updated_at   = clock_timestamp()
   where p.id = v_profile;

  insert into public.bots (owner_id, profile_id, username, display_name, about, description,
                           token_hash, token_prefix, is_public, inline_enabled, join_groups,
                           privacy_mode, is_botfather)
  values (v_profile, v_profile, 'botfather', 'BotFather',
          'Create and configure bots.',
          'The master bot. /newbot makes one, /mybots lists yours, /token rotates a credential.',
          app.bot_token_hash('revoked-' || gen_random_uuid()::text), 'mxb_revoked_', true, false, false,
          false, true)
  returning id into v_bot;

  insert into public.bot_commands (bot_id, name, description, handler, builtin_action,
                                   default_permission, position)
  values
    (v_bot, 'newbot',      'Create a new bot',                 'builtin', 'help', 'everyone', 0),
    (v_bot, 'mybots',      'List the bots you own',            'builtin', 'help', 'everyone', 1),
    (v_bot, 'token',       'Rotate a bot token',               'builtin', 'help', 'everyone', 2),
    (v_bot, 'setname',     'Rename a bot',                     'builtin', 'help', 'everyone', 3),
    (v_bot, 'setabout',    'Set a bot description',            'builtin', 'help', 'everyone', 4),
    (v_bot, 'setinline',   'Toggle inline mode',               'builtin', 'help', 'everyone', 5),
    (v_bot, 'setcommands', 'Set the command list',             'builtin', 'help', 'everyone', 6),
    (v_bot, 'setwebhook',  'Point the bot at an https URL',    'builtin', 'help', 'everyone', 7),
    (v_bot, 'deletebot',   'Delete a bot you own',             'builtin', 'help', 'everyone', 8),
    (v_bot, 'help',        'How bots work',                    'builtin', 'help', 'everyone', 9);
end $$;
