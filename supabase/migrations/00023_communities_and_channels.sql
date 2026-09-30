-- =============================================================================
-- 00023_communities_and_channels.sql
-- MessengerX 3.0 — Discord-shaped communities and Telegram-shaped channels.
--
-- The messaging core (00002) already has everything a conversation needs:
-- participants with roles, a message timeline, read state, realtime and media.
-- So instead of inventing a second message store, this migration *structures*
-- chats:
--
--   • a community ("server") owns categories, roles, invites and bans, and each
--     of its text/voice/announcement channels points at a real `chats` row —
--     which means reactions, receipts, typing and media work on day one;
--   • a broadcast channel is simply `chats.kind = 'channel'`: subscribers are
--     participants, posting is a permission, and the read-only rule is a
--     trigger rather than a client convention;
--   • a `community_roles.permissions` bitmask plus per-channel overwrites give
--     Discord's model (role permissions − channel deny) with SQL as the judge.
--
-- Enum note: Postgres refuses to *use* an enum value in the transaction that
-- adds it, so every immediate statement below compares `kind::text` and the
-- literal 'channel' only appears inside plpgsql bodies (parsed at execution).
-- =============================================================================

begin;

alter type public.chat_kind add value if not exists 'channel';

-- ---------------------------------------------------------------------------
-- 1. Channels are chats: identity columns that only a broadcast channel uses.
-- ---------------------------------------------------------------------------
alter table public.chats
  add column if not exists handle           text,
  add column if not exists description      text check (description is null or char_length(description) <= 1000),
  add column if not exists is_public        boolean not null default false,
  add column if not exists topic            text check (topic is null or char_length(topic) <= 200),
  add column if not exists subscriber_count integer not null default 0 check (subscriber_count >= 0),
  add column if not exists post_policy      text not null default 'admins'
                                            check (post_policy in ('owner', 'admins', 'everyone')),
  add column if not exists community_id     uuid,
  add column if not exists category_id      uuid;

create unique index if not exists chats_handle_key
  on public.chats (lower(handle)) where handle is not null;

comment on column public.chats.post_policy is
  'Who may post in a channel: owner | admins | everyone. Enforced by app.guard_channel_post(), not by the UI.';

-- 00002 required a title for every group; a channel needs one too. The check is
-- rewritten through `kind::text` because the enum value committed above cannot
-- be named in this transaction.
alter table public.chats drop constraint if exists chats_title_shape;
alter table public.chats add constraint chats_title_shape check (
  (kind::text = 'direct' and (title is null or is_telegram_mirror))
  or (kind::text <> 'direct' and title is not null)
);

-- ---------------------------------------------------------------------------
-- 2. Communities.
-- ---------------------------------------------------------------------------
create table if not exists public.communities (
  id            uuid primary key default app.uuid_v7(),
  owner_id      uuid not null references public.profiles (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 2 and 100),
  slug          text not null unique check (slug ~ '^[a-z0-9-]{3,48}$'),
  description   text check (description is null or char_length(description) <= 2000),
  icon_key      text,
  banner_key    text,
  is_public     boolean not null default true,
  is_verified   boolean not null default false,
  is_removed    boolean not null default false,
  member_count  integer not null default 0 check (member_count >= 0),
  online_count  integer not null default 0 check (online_count >= 0),
  rules         jsonb not null default '[]'::jsonb,
  welcome       text check (welcome is null or char_length(welcome) <= 500),
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp(),
  deleted_at    timestamptz,
  constraint communities_rules_shape check (jsonb_typeof(rules) = 'array' and jsonb_array_length(rules) <= 30)
);

comment on table public.communities is
  'Discord-style server: roles + categories + channels. Channels are rows in `chats`, so the messaging stack is reused wholesale.';

create index if not exists communities_discover_idx
  on public.communities (member_count desc, id) where is_public and not is_removed and deleted_at is null;

create table if not exists public.community_categories (
  id            uuid primary key default app.uuid_v7(),
  community_id  uuid not null references public.communities (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 60),
  position      integer not null default 0,
  created_at    timestamptz not null default clock_timestamp()
);

create index if not exists community_categories_idx on public.community_categories (community_id, position);

create table if not exists public.community_roles (
  id            uuid primary key default app.uuid_v7(),
  community_id  uuid not null references public.communities (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 40),
  color         text not null default '#99aab5' check (color ~ '^#[0-9a-fA-F]{6}$'),
  position      integer not null default 0,
  permissions   bigint not null default 0,
  is_default    boolean not null default false,   -- the @everyone role
  is_hoisted    boolean not null default false,   -- shown separately in the member list
  mentionable   boolean not null default true,
  is_managed    boolean not null default false,   -- owned by a bot
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp()
);

comment on column public.community_roles.permissions is
  'Bitmask of app.perm_* values. Effective permissions = OR(roles) − channel overwrite denials, with ADMINISTRATOR short-circuiting everything.';

create unique index if not exists community_roles_default_key
  on public.community_roles (community_id) where is_default;
create index if not exists community_roles_order_idx on public.community_roles (community_id, position desc);

create table if not exists public.community_members (
  community_id uuid not null references public.communities (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  nickname     text check (nickname is null or char_length(nickname) <= 32),
  role_ids     uuid[] not null default '{}'::uuid[],
  joined_at    timestamptz not null default clock_timestamp(),
  updated_at   timestamptz not null default clock_timestamp(),
  is_muted     boolean not null default false,
  muted_until  timestamptz,
  message_count integer not null default 0 check (message_count >= 0),
  last_seen_at timestamptz,
  primary key (community_id, user_id),
  constraint community_members_roles_shape check (array_length(role_ids, 1) is null or array_length(role_ids, 1) <= 32)
);

create index if not exists community_members_user_idx on public.community_members (user_id, community_id);

create table if not exists public.community_channels (
  id               uuid primary key default app.uuid_v7(),
  community_id     uuid not null references public.communities (id) on delete cascade,
  category_id      uuid references public.community_categories (id) on delete set null,
  chat_id          uuid not null unique references public.chats (id) on delete cascade,
  name             text not null check (char_length(btrim(name)) between 1 and 60),
  topic            text check (topic is null or char_length(topic) <= 200),
  kind             text not null default 'text'
                   check (kind in ('text', 'voice', 'announcement', 'forum', 'stage')),
  position         integer not null default 0,
  is_private       boolean not null default false,
  slowmode_seconds integer not null default 0 check (slowmode_seconds between 0 and 21600),
  user_limit       integer not null default 0 check (user_limit between 0 and 99),
  is_nsfw          boolean not null default false,
  created_at       timestamptz not null default clock_timestamp(),
  updated_at       timestamptz not null default clock_timestamp(),
  deleted_at       timestamptz
);

comment on table public.community_channels is
  'A channel inside a community. `chat_id` is the real conversation: text channels are group chats, voice channels use the same row for presence and chat.';

create index if not exists community_channels_idx
  on public.community_channels (community_id, position) where deleted_at is null;

alter table public.chats
  drop constraint if exists chats_community_fk;
alter table public.chats
  add constraint chats_community_fk foreign key (community_id) references public.communities (id) on delete cascade;

create table if not exists public.community_channel_overwrites (
  channel_id  uuid not null references public.community_channels (id) on delete cascade,
  target_type text not null check (target_type in ('role', 'member')),
  target_id   uuid not null,
  allow       bigint not null default 0,
  deny        bigint not null default 0,
  primary key (channel_id, target_type, target_id)
);

comment on table public.community_channel_overwrites is
  'Per-channel permission overrides, Discord-style: role first (lowest wins last), then member overwrites. Evaluated by app.channel_permissions().';

create table if not exists public.community_invites (
  code         text primary key check (code ~ '^[A-Za-z0-9_-]{6,32}$'),
  community_id uuid not null references public.communities (id) on delete cascade,
  channel_id   uuid references public.community_channels (id) on delete set null,
  created_by   uuid references public.profiles (id) on delete set null,
  max_uses     integer not null default 0 check (max_uses >= 0),   -- 0 = unlimited
  uses         integer not null default 0 check (uses >= 0),
  expires_at   timestamptz,
  created_at   timestamptz not null default clock_timestamp()
);

create index if not exists community_invites_community_idx on public.community_invites (community_id, created_at desc);

create table if not exists public.community_bans (
  community_id uuid not null references public.communities (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  reason       text check (reason is null or char_length(reason) <= 400),
  banned_by    uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default clock_timestamp(),
  primary key (community_id, user_id)
);

-- Voice presence (P2P mesh signalling: the database only records who is in the
-- room; audio travels peer-to-peer, which is what keeps voice free to run).
create table if not exists public.community_voice_states (
  channel_id  uuid not null references public.community_channels (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  session_id  text not null,
  is_muted    boolean not null default false,
  is_deafened boolean not null default false,
  is_video    boolean not null default false,
  is_streaming boolean not null default false,
  joined_at   timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp(),
  primary key (channel_id, user_id)
);

-- ---------------------------------------------------------------------------
-- 3. Permission model.
-- ---------------------------------------------------------------------------
create or replace function app.perm_all() returns bigint language sql immutable as $$ select 9223372036854775807::bigint $$;

create or replace function app.perm_view_channel()      returns bigint language sql immutable as $$ select 1::bigint << 1 $$;
create or replace function app.perm_send_messages()     returns bigint language sql immutable as $$ select 1::bigint << 2 $$;
create or replace function app.perm_manage_messages()   returns bigint language sql immutable as $$ select 1::bigint << 3 $$;
create or replace function app.perm_kick_members()      returns bigint language sql immutable as $$ select 1::bigint << 4 $$;
create or replace function app.perm_ban_members()       returns bigint language sql immutable as $$ select 1::bigint << 5 $$;
create or replace function app.perm_manage_channels()   returns bigint language sql immutable as $$ select 1::bigint << 6 $$;
create or replace function app.perm_manage_roles()      returns bigint language sql immutable as $$ select 1::bigint << 7 $$;
create or replace function app.perm_manage_community()  returns bigint language sql immutable as $$ select 1::bigint << 8 $$;
create or replace function app.perm_create_invites()    returns bigint language sql immutable as $$ select 1::bigint << 9 $$;
create or replace function app.perm_mention_everyone()  returns bigint language sql immutable as $$ select 1::bigint << 10 $$;
create or replace function app.perm_attach_files()      returns bigint language sql immutable as $$ select 1::bigint << 11 $$;
create or replace function app.perm_add_reactions()     returns bigint language sql immutable as $$ select 1::bigint << 12 $$;
create or replace function app.perm_manage_bots()       returns bigint language sql immutable as $$ select 1::bigint << 13 $$;
create or replace function app.perm_moderate_members()  returns bigint language sql immutable as $$ select 1::bigint << 14 $$;
create or replace function app.perm_create_threads()    returns bigint language sql immutable as $$ select 1::bigint << 15 $$;
create or replace function app.perm_stream()            returns bigint language sql immutable as $$ select 1::bigint << 16 $$;
create or replace function app.perm_administrator()     returns bigint language sql immutable as $$ select 1::bigint << 0 $$;

-- Default @everyone permissions: read, write, attach, react, start threads.
create or replace function app.perm_everyone_default() returns bigint language sql immutable as $$
  select (1::bigint << 1) | (1::bigint << 2) | (1::bigint << 9) | (1::bigint << 11) | (1::bigint << 12) | (1::bigint << 15)
$$;

-- OR of every role the member holds. Owner short-circuits to everything.
create or replace function app.community_permissions(p_community uuid, p_user uuid)
returns bigint
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when p_user is null or p_community is null then 0::bigint
    when exists (select 1 from public.communities c where c.id = p_community and c.owner_id = p_user)
      then app.perm_all()
    else coalesce((
      select bit_or(r.permissions) | case when bool_or(r.is_default) then app.perm_everyone_default() else 0 end
        from public.community_members m
        join public.community_roles r
          on r.community_id = m.community_id
         and (r.is_default or r.id = any (m.role_ids))
       where m.community_id = p_community and m.user_id = p_user
    ), 0::bigint)
  end;
$$;

comment on function app.community_permissions(uuid, uuid) is
  'Effective community permissions for one member (owner ⇒ all). Channel overwrites are applied on top by app.channel_permissions().';

create or replace function app.channel_permissions(p_channel_id uuid, p_user uuid)
returns bigint
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with ctx as (
    select ch.id, ch.community_id, ch.is_private,
           app.community_permissions(ch.community_id, p_user) as base,
           exists (select 1 from public.community_members m
                    where m.community_id = ch.community_id and m.user_id = p_user) as is_member
      from public.community_channels ch
     where ch.id = p_channel_id and ch.deleted_at is null
  ), role_mask as (
    select coalesce(bit_or(o.allow), 0) as allow, coalesce(bit_or(o.deny), 0) as deny
      from public.community_channel_overwrites o
      join public.community_members m
        on m.community_id = (select community_id from ctx) and m.user_id = p_user
     where o.channel_id = p_channel_id
       and o.target_type = 'role'
       and o.target_id = any (m.role_ids || coalesce((
             select array_agg(r.id) from public.community_roles r
              where r.community_id = m.community_id and r.is_default), '{}'::uuid[]))
  ), member_mask as (
    select coalesce(bit_or(o.allow), 0) as allow, coalesce(bit_or(o.deny), 0) as deny
      from public.community_channel_overwrites o
     where o.channel_id = p_channel_id and o.target_type = 'member' and o.target_id = p_user
  )
  select case
    when (select base from ctx) is null then 0::bigint
    -- ADMINISTRATOR bypasses overwrites entirely — that is what makes it
    -- administrator rather than "another permission".
    when ((select base from ctx) & app.perm_administrator()) <> 0 then app.perm_all()
    when not (select is_member from ctx) then 0::bigint
    -- A private channel is opt-in by design: it needs an explicit overwrite
    -- granting VIEW_CHANNEL, not merely membership of the community.
    when (select is_private from ctx)
         and (((select allow from role_mask) | (select allow from member_mask))
              & app.perm_view_channel()) = 0 then 0::bigint
    else (
      ((select base from ctx) | (select allow from role_mask)) & ~(select deny from role_mask)
    ) | ((select allow from member_mask) & ~(select deny from member_mask))
  end;
$$;

comment on function app.channel_permissions(uuid, uuid) is
  'Effective permissions in one channel: community roles, then role overwrites, then member overwrites. Private channels additionally require an explicit VIEW_CHANNEL grant.';

create or replace function app.channel_can(p_channel_id uuid, p_user uuid, p_perm bigint)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select (app.channel_permissions(p_channel_id, p_user) & p_perm) = p_perm;
$$;

-- The caller's own view of their permissions, for rendering the UI honestly
-- (a hidden button is not a security control, but a shown one that fails is
-- worse UX than one that never appears).
create or replace function public.community_my_permissions(p_community_id uuid)
returns bigint
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select app.community_permissions(p_community_id, app.current_uid());
$$;

-- ---------------------------------------------------------------------------
-- 4. Message-time enforcement: channel posting rules + community slowmode.
--    A separate trigger, so the messaging core (00004) stays untouched.
-- ---------------------------------------------------------------------------
create or replace function app.guard_channel_post()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_chat      public.chats%rowtype;
  v_member    public.community_members%rowtype;
  v_channel   public.community_channels%rowtype;
  v_is_admin  boolean;
  v_last_post timestamptz;
begin
  if new.sender_id is null then
    return new;   -- mirror/bridge rows are governed by the bridge RPCs
  end if;

  select * into v_chat from public.chats c where c.id = new.chat_id;
  if not found then
    return new;
  end if;

  -- 1. Broadcast channels: post_policy decides, and the poster's participant
  --    role is the tiebreaker (owner > admin > subscriber).
  if v_chat.kind::text = 'channel' then
    select cp.role in ('owner', 'admin') into v_is_admin
      from public.chat_participants cp
     where cp.chat_id = new.chat_id and cp.user_id = new.sender_id;

    if not coalesce(v_is_admin, false) then
      if v_chat.post_policy is null or v_chat.post_policy <> 'everyone' then
        raise exception 'only the channel admin may post here' using errcode = '42501';
      end if;
      if not exists (select 1 from public.chat_participants cp
                      where cp.chat_id = new.chat_id and cp.user_id = new.sender_id and cp.left_at is null) then
        raise exception 'join the channel before posting' using errcode = '42501';
      end if;
    end if;
  end if;

  -- 2. Community channels: the role bitmask decides, and slowmode is timed
  --    against the sender's own last message in that channel.
  if v_chat.kind::text = 'group' and v_chat.community_id is not null then
    select * into v_channel from public.community_channels ch
     where ch.chat_id = new.chat_id and ch.deleted_at is null;
    if found then
      if not app.channel_can(v_channel.id, new.sender_id, app.perm_send_messages()) then
        raise exception 'you do not have permission to send messages in this channel'
          using errcode = '42501';
      end if;

      select * into v_member from public.community_members m
       where m.community_id = v_channel.community_id and m.user_id = new.sender_id;
      if found and v_member.is_muted and (v_member.muted_until is null or v_member.muted_until > clock_timestamp()) then
        raise exception 'you are muted in this community' using errcode = '42501';
      end if;

      if v_channel.slowmode_seconds > 0
         and (app.channel_permissions(v_channel.id, new.sender_id) & app.perm_manage_messages()) = 0 then
        select max(m.created_at) into v_last_post
          from public.messages m
         where m.chat_id = new.chat_id and m.sender_id = new.sender_id and m.deleted_at is null;
        if v_last_post is not null
           and v_last_post > clock_timestamp() - make_interval(secs => v_channel.slowmode_seconds) then
          raise exception 'slowmode: wait % seconds', v_channel.slowmode_seconds using errcode = '42501';
        end if;
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists messages_guard_channel_post on public.messages;
create trigger messages_guard_channel_post
  before insert on public.messages
  for each row execute function app.guard_channel_post();

-- Presence counter for a community: derived on read, not stored per heartbeat.
create or replace function app.community_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.communities set member_count = member_count + 1, updated_at = clock_timestamp()
     where id = new.community_id;
  elsif tg_op = 'DELETE' then
    update public.communities set member_count = greatest(member_count - 1, 0), updated_at = clock_timestamp()
     where id = old.community_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists community_members_recount on public.community_members;
create trigger community_members_recount
  after insert or delete on public.community_members
  for each row execute function app.community_recount();

-- Subscriber counter for broadcast channels rides chat_participants.
create or replace function app.channel_subscriber_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.chats set subscriber_count = subscriber_count + 1
     where id = new.chat_id and kind::text = 'channel';
  elsif tg_op = 'DELETE' then
    update public.chats set subscriber_count = greatest(subscriber_count - 1, 0)
     where id = old.chat_id and kind::text = 'channel';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists chat_participants_channel_count on public.chat_participants;
create trigger chat_participants_channel_count
  after insert or delete on public.chat_participants
  for each row execute function app.channel_subscriber_recount();

-- ---------------------------------------------------------------------------
-- 5. Community RPCs.
-- ---------------------------------------------------------------------------
create or replace function public.community_create(
  p_name        text,
  p_slug        text,
  p_description text default null,
  p_is_public   boolean default true,
  p_icon_key    text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_id      uuid;
  v_default uuid;
  v_cat     uuid;
  v_chat    uuid;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) or not app.sender_may_post(v_uid) then
    raise exception 'this account may not create a community' using errcode = '42501';
  end if;
  if p_slug !~ '^[a-z0-9-]{3,48}$' then
    raise exception 'a community slug is 3-48 characters of a-z, 0-9 and -' using errcode = '22023';
  end if;

  insert into public.communities (owner_id, name, slug, description, is_public, icon_key)
  values (v_uid, btrim(p_name), lower(p_slug), nullif(btrim(coalesce(p_description, '')), ''),
          coalesce(p_is_public, true), p_icon_key)
  returning id into v_id;

  -- @everyone, then the owner as a member holding it.
  insert into public.community_roles (community_id, name, permissions, is_default, position)
  values (v_id, '@everyone', app.perm_everyone_default(), true, 0)
  returning id into v_default;

  insert into public.community_members (community_id, user_id, role_ids)
  values (v_id, v_uid, '{}'::uuid[]);

  -- A server with no channels is a dead end, so bootstrap #general + a voice
  -- room the way every Discord user expects to find them.
  insert into public.community_categories (community_id, name, position)
  values (v_id, 'General', 0) returning id into v_cat;

  insert into public.chats (kind, title, created_by, community_id, category_id)
  values ('group', 'general', v_uid, v_id, v_cat) returning id into v_chat;
  insert into public.chat_participants (chat_id, user_id, role)
  values (v_chat, v_uid, 'owner');
  insert into public.community_channels (community_id, category_id, chat_id, name, kind, position)
  values (v_id, v_cat, v_chat, 'general', 'text', 0);

  insert into public.chats (kind, title, created_by, community_id, category_id)
  values ('group', 'Lounge', v_uid, v_id, v_cat) returning id into v_chat;
  insert into public.chat_participants (chat_id, user_id, role)
  values (v_chat, v_uid, 'owner');
  insert into public.community_channels (community_id, category_id, chat_id, name, kind, position)
  values (v_id, v_cat, v_chat, 'Lounge', 'voice', 1);

  return v_id;
end;
$$;

create or replace function public.community_update(
  p_community_id uuid,
  p_name         text default null,
  p_description  text default null,
  p_is_public    boolean default null,
  p_icon_key     text default null,
  p_rules        jsonb default null,
  p_welcome      text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not app.channel_can_manage_community(p_community_id) then
    raise exception 'you may not edit this community' using errcode = '42501';
  end if;
  update public.communities c set
    name        = coalesce(nullif(btrim(p_name), ''), c.name),
    description = case when p_description is null then c.description else nullif(btrim(p_description), '') end,
    is_public   = coalesce(p_is_public, c.is_public),
    icon_key    = coalesce(p_icon_key, c.icon_key),
    rules       = coalesce(p_rules, c.rules),
    welcome     = case when p_welcome is null then c.welcome else nullif(btrim(p_welcome), '') end,
    updated_at  = clock_timestamp()
   where c.id = p_community_id;
end;
$$;

-- Small helper so every RPC reads the same way.
create or replace function app.channel_can_manage_community(p_community_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select (app.community_permissions(p_community_id, app.current_uid())
          & app.perm_manage_community()) = app.perm_manage_community();
$$;

create or replace function public.community_delete(p_community_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if not exists (select 1 from public.communities c where c.id = p_community_id and c.owner_id = v_uid)
     and not app.caller_is_service_role() then
    raise exception 'only the owner may delete this community' using errcode = '42501';
  end if;
  update public.communities set deleted_at = clock_timestamp(), is_removed = true where id = p_community_id;
end;
$$;

create or replace function public.community_join(p_community_id uuid default null, p_slug text default null, p_invite text default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_target public.communities%rowtype;
  v_invite public.community_invites%rowtype;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'this account may not join yet' using errcode = '42501';
  end if;

  if p_invite is not null then
    select * into v_invite from public.community_invites i where i.code = p_invite;
    if not found then
      raise exception 'that invite does not exist' using errcode = '22023';
    end if;
    if v_invite.expires_at is not null and v_invite.expires_at < clock_timestamp() then
      raise exception 'that invite has expired' using errcode = '22023';
    end if;
    if v_invite.max_uses > 0 and v_invite.uses >= v_invite.max_uses then
      raise exception 'that invite is used up' using errcode = '22023';
    end if;
    select * into v_target from public.communities c where c.id = v_invite.community_id;
    update public.community_invites set uses = uses + 1 where code = p_invite;
  elsif p_community_id is not null then
    select * into v_target from public.communities c where c.id = p_community_id;
  elsif p_slug is not null then
    select * into v_target from public.communities c where c.slug = lower(btrim(p_slug));
  else
    raise exception 'community_join needs an id, a slug or an invite' using errcode = '22023';
  end if;

  if v_target.id is null or v_target.deleted_at is not null or v_target.is_removed then
    raise exception 'that community is not available' using errcode = '22023';
  end if;
  if exists (select 1 from public.community_bans b
              where b.community_id = v_target.id and b.user_id = v_uid) then
    raise exception 'you are banned from this community' using errcode = '42501';
  end if;
  if not v_target.is_public and p_invite is null then
    raise exception 'this community is invite-only' using errcode = '42501';
  end if;

  insert into public.community_members (community_id, user_id)
  values (v_target.id, v_uid)
  on conflict (community_id, user_id) do nothing;

  -- Public text channels join you automatically; private ones stay opt-in.
  insert into public.chat_participants (chat_id, user_id, role)
  select ch.chat_id, v_uid, 'member'
    from public.community_channels ch
   where ch.community_id = v_target.id
     and ch.deleted_at is null
     and ch.kind in ('text', 'announcement', 'forum')
     and not ch.is_private
  on conflict (chat_id, user_id) do nothing;

  return v_target.id;
end;
$$;

create or replace function public.community_leave(p_community_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if exists (select 1 from public.communities c where c.id = p_community_id and c.owner_id = v_uid) then
    raise exception 'the owner cannot leave; transfer or delete the community' using errcode = '42501';
  end if;
  delete from public.chat_participants cp
   using public.community_channels ch
   where cp.chat_id = ch.chat_id and ch.community_id = p_community_id and cp.user_id = v_uid;
  delete from public.community_members m
   where m.community_id = p_community_id and m.user_id = v_uid;
end;
$$;

create or replace function public.community_channel_create(
  p_community_id uuid,
  p_name         text,
  p_kind         text default 'text',
  p_category_id  uuid default null,
  p_topic        text default null,
  p_is_private   boolean default false,
  p_position     integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_chat  uuid;
  v_id    uuid;
  v_title text;
begin
  if (app.community_permissions(p_community_id, v_uid) & app.perm_manage_channels()) = 0 then
    raise exception 'you may not manage channels here' using errcode = '42501';
  end if;
  if p_kind not in ('text', 'voice', 'announcement', 'forum', 'stage') then
    raise exception 'unknown channel kind %', p_kind using errcode = '22023';
  end if;

  v_title := case when p_kind = 'voice' then btrim(p_name) else lower(regexp_replace(btrim(p_name), '[^A-Za-z0-9_-]+', '-', 'g')) end;
  if char_length(v_title) < 1 then
    raise exception 'a channel needs a name' using errcode = '22023';
  end if;

  insert into public.chats (kind, title, created_by, community_id, category_id)
  values ('group', v_title, v_uid, p_community_id, p_category_id)
  returning id into v_chat;

  insert into public.chat_participants (chat_id, user_id, role)
  select v_chat, m.user_id, case when c.owner_id = m.user_id then 'owner'::public.participant_role else 'member'::public.participant_role end
    from public.community_members m
    join public.communities c on c.id = m.community_id
   where m.community_id = p_community_id
     and not p_is_private
  on conflict (chat_id, user_id) do nothing;

  insert into public.community_channels (community_id, category_id, chat_id, name, kind, position, is_private, topic)
  values (p_community_id, p_category_id, v_chat, v_title, p_kind,
          least(greatest(coalesce(p_position, 0), 0), 9999), coalesce(p_is_private, false),
          nullif(btrim(coalesce(p_topic, '')), ''))
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.community_channel_update(
  p_channel_id     uuid,
  p_name           text default null,
  p_topic          text default null,
  p_position       integer default null,
  p_is_private     boolean default null,
  p_slowmode_seconds integer default null,
  p_category_id    uuid default null,
  p_user_limit     integer default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_community uuid;
begin
  select ch.community_id into v_community from public.community_channels ch where ch.id = p_channel_id;
  if v_community is null or (app.community_permissions(v_community, app.current_uid()) & app.perm_manage_channels()) = 0 then
    raise exception 'you may not manage this channel' using errcode = '42501';
  end if;
  update public.community_channels ch set
    name             = coalesce(nullif(btrim(p_name), ''), ch.name),
    topic            = case when p_topic is null then ch.topic else nullif(btrim(p_topic), '') end,
    position         = coalesce(p_position, ch.position),
    is_private       = coalesce(p_is_private, ch.is_private),
    slowmode_seconds = coalesce(p_slowmode_seconds, ch.slowmode_seconds),
    category_id      = coalesce(p_category_id, ch.category_id),
    user_limit       = coalesce(p_user_limit, ch.user_limit),
    updated_at       = clock_timestamp()
   where ch.id = p_channel_id;
end;
$$;

create or replace function public.community_channel_delete(p_channel_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_community uuid;
  v_chat      uuid;
begin
  select ch.community_id, ch.chat_id into v_community, v_chat
    from public.community_channels ch where ch.id = p_channel_id;
  if v_community is null or (app.community_permissions(v_community, app.current_uid()) & app.perm_manage_channels()) = 0 then
    raise exception 'you may not delete this channel' using errcode = '42501';
  end if;
  update public.community_channels set deleted_at = clock_timestamp() where id = p_channel_id;
  -- The chat row goes with it: a deleted channel must not keep receiving
  -- messages through a stale link.
  delete from public.chats c where c.id = v_chat;
end;
$$;

create or replace function public.community_role_create(
  p_community_id uuid,
  p_name         text,
  p_color        text default '#99aab5',
  p_permissions  bigint default 0,
  p_hoisted      boolean default false,
  p_mentionable  boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_id uuid;
begin
  if (app.community_permissions(p_community_id, app.current_uid()) & app.perm_manage_roles()) = 0 then
    raise exception 'you may not manage roles here' using errcode = '42501';
  end if;
  insert into public.community_roles (community_id, name, color, permissions, is_hoisted, mentionable, position)
  values (p_community_id, btrim(p_name), coalesce(p_color, '#99aab5'), coalesce(p_permissions, 0),
          coalesce(p_hoisted, false), coalesce(p_mentionable, true),
          coalesce((select max(r.position) + 1 from public.community_roles r where r.community_id = p_community_id), 1))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.community_role_update(
  p_role_id     uuid,
  p_name        text default null,
  p_color       text default null,
  p_permissions bigint default null,
  p_hoisted     boolean default null,
  p_mentionable boolean default null,
  p_position    integer default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_community uuid;
begin
  select r.community_id into v_community from public.community_roles r where r.id = p_role_id;
  if v_community is null or (app.community_permissions(v_community, app.current_uid()) & app.perm_manage_roles()) = 0 then
    raise exception 'you may not manage this role' using errcode = '42501';
  end if;
  update public.community_roles r set
    name        = coalesce(nullif(btrim(p_name), ''), r.name),
    color       = coalesce(p_color, r.color),
    permissions = coalesce(p_permissions, r.permissions),
    is_hoisted  = coalesce(p_hoisted, r.is_hoisted),
    mentionable = coalesce(p_mentionable, r.mentionable),
    position    = coalesce(p_position, r.position),
    updated_at  = clock_timestamp()
   where r.id = p_role_id;
end;
$$;

create or replace function public.community_role_delete(p_role_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_community uuid;
  v_default   boolean;
begin
  select r.community_id, r.is_default into v_community, v_default
    from public.community_roles r where r.id = p_role_id;
  if v_community is null or (app.community_permissions(v_community, app.current_uid()) & app.perm_manage_roles()) = 0 then
    raise exception 'you may not delete this role' using errcode = '42501';
  end if;
  if v_default then
    raise exception 'the @everyone role cannot be deleted' using errcode = '22023';
  end if;
  delete from public.community_roles r where r.id = p_role_id;
end;
$$;

create or replace function public.community_member_set_roles(p_community_id uuid, p_user_id uuid, p_role_ids uuid[])
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_me   bigint := app.community_permissions(p_community_id, v_uid);
  v_them bigint;
begin
  if (v_me & app.perm_manage_roles()) = 0 then
    raise exception 'you may not assign roles here' using errcode = '42501';
  end if;
  if exists (select 1 from public.communities c where c.id = p_community_id and c.owner_id = p_user_id) then
    raise exception 'the owner already holds every role' using errcode = '22023';
  end if;
  if exists (select 1 from public.community_members m
              where m.community_id = p_community_id and m.user_id = p_user_id) is false then
    raise exception 'that account is not a member' using errcode = '22023';
  end if;

  v_them := app.community_permissions(p_community_id, p_user_id);
  -- Discord's "you cannot out-rank yourself" rule, expressed as permissions:
  -- only an administrator may hand out administrator.
  if (v_them & app.perm_administrator()) <> 0 and (v_me & app.perm_administrator()) = 0 then
    raise exception 'you may not change an administrator''s roles' using errcode = '42501';
  end if;

  update public.community_members m
     set role_ids = (
           select coalesce(array_agg(r.id), '{}'::uuid[])
             from public.community_roles r
            where r.community_id = p_community_id and r.id = any (p_role_ids) and not r.is_default
         ),
         updated_at = clock_timestamp()
   where m.community_id = p_community_id and m.user_id = p_user_id;
end;
$$;

create or replace function public.community_member_moderate(
  p_community_id uuid,
  p_user_id      uuid,
  p_action       text,          -- kick | ban | unban | mute | unmute | nickname
  p_reason       text default null,
  p_minutes      integer default null,
  p_nickname     text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_me  bigint := app.community_permissions(p_community_id, v_uid);
begin
  if exists (select 1 from public.communities c where c.id = p_community_id and c.owner_id = p_user_id) then
    raise exception 'the owner cannot be moderated' using errcode = '42501';
  end if;

  case p_action
    when 'kick' then
      if (v_me & app.perm_kick_members()) = 0 then
        raise exception 'you may not kick members' using errcode = '42501';
      end if;
      delete from public.community_members m where m.community_id = p_community_id and m.user_id = p_user_id;
      delete from public.chat_participants cp
       using public.community_channels ch
       where cp.chat_id = ch.chat_id and ch.community_id = p_community_id and cp.user_id = p_user_id;
    when 'ban' then
      if (v_me & app.perm_ban_members()) = 0 then
        raise exception 'you may not ban members' using errcode = '42501';
      end if;
      insert into public.community_bans (community_id, user_id, reason, banned_by)
      values (p_community_id, p_user_id, nullif(btrim(coalesce(p_reason, '')), ''), v_uid)
      on conflict (community_id, user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by;
      delete from public.community_members m where m.community_id = p_community_id and m.user_id = p_user_id;
      delete from public.chat_participants cp
       using public.community_channels ch
       where cp.chat_id = ch.chat_id and ch.community_id = p_community_id and cp.user_id = p_user_id;
    when 'unban' then
      if (v_me & app.perm_ban_members()) = 0 then
        raise exception 'you may not unban members' using errcode = '42501';
      end if;
      delete from public.community_bans b where b.community_id = p_community_id and b.user_id = p_user_id;
    when 'mute' then
      if (v_me & app.perm_moderate_members()) = 0 then
        raise exception 'you may not mute members' using errcode = '42501';
      end if;
      update public.community_members m
         set is_muted = true,
             muted_until = case when p_minutes is null then null
                                else clock_timestamp() + make_interval(mins => greatest(p_minutes, 1)) end,
             updated_at = clock_timestamp()
       where m.community_id = p_community_id and m.user_id = p_user_id;
    when 'unmute' then
      if (v_me & app.perm_moderate_members()) = 0 then
        raise exception 'you may not unmute members' using errcode = '42501';
      end if;
      update public.community_members m
         set is_muted = false, muted_until = null, updated_at = clock_timestamp()
       where m.community_id = p_community_id and m.user_id = p_user_id;
    when 'nickname' then
      if v_uid <> p_user_id and (v_me & app.perm_manage_roles()) = 0 then
        raise exception 'you may not rename other members' using errcode = '42501';
      end if;
      update public.community_members m
         set nickname = nullif(btrim(coalesce(p_nickname, '')), ''), updated_at = clock_timestamp()
       where m.community_id = p_community_id and m.user_id = p_user_id;
    else
      raise exception 'unknown moderation action %', p_action using errcode = '22023';
  end case;
end;
$$;

create or replace function public.community_invite_create(
  p_community_id uuid,
  p_max_uses     integer default 0,
  p_expires_hours integer default 168,
  p_channel_id   uuid default null
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_code text;
begin
  if (app.community_permissions(p_community_id, v_uid) & app.perm_create_invites()) = 0 then
    raise exception 'you may not create invites here' using errcode = '42501';
  end if;
  -- md5() is core Postgres; pgcrypto is not guaranteed to be installed on
  -- every project, and an invite code does not need cryptographic strength —
  -- it needs to be unguessable enough for a 7-day link and unique.
  v_code := upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text || random()::text), 1, 16));
  v_code := replace(replace(v_code, '+', '-'), '=', '');
  insert into public.community_invites (code, community_id, channel_id, created_by, max_uses, expires_at)
  values (v_code, p_community_id, p_channel_id, v_uid, greatest(coalesce(p_max_uses, 0), 0),
          case when p_expires_hours is null or p_expires_hours <= 0 then null
               else clock_timestamp() + make_interval(hours => p_expires_hours) end);
  return v_code;
end;
$$;

comment on function public.community_invite_create(uuid, integer, integer, uuid) is
  'Mints a short invite code. `p_expires_hours` <= 0 means never expires.';

-- Discovery + full server view -----------------------------------------------
create or replace function public.community_directory(p_query text default null, p_limit integer default 30)
returns table (
  id            uuid,
  name          text,
  slug          text,
  description   text,
  icon_key      text,
  banner_key    text,
  is_verified   boolean,
  member_count  integer,
  online_count  integer,
  joined        boolean,
  my_permissions bigint
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select c.id, c.name, c.slug, c.description, c.icon_key, c.banner_key, c.is_verified,
         c.member_count,
         (select count(*)::int from public.community_members m
           join public.profiles p on p.id = m.user_id
          where m.community_id = c.id
            and p.last_seen_at > clock_timestamp() - interval '5 minutes') as online_count,
         exists (select 1 from public.community_members m
                  where m.community_id = c.id and m.user_id = app.current_uid()) as joined,
         app.community_permissions(c.id, app.current_uid())
    from public.communities c
   where c.deleted_at is null
     and not c.is_removed
     and (c.is_public
          or exists (select 1 from public.community_members m
                      where m.community_id = c.id and m.user_id = app.current_uid()))
     and (nullif(btrim(coalesce(p_query, '')), '') is null
          or c.name ilike '%' || btrim(p_query) || '%'
          or c.slug ilike '%' || btrim(p_query) || '%'
          or coalesce(c.description, '') ilike '%' || btrim(p_query) || '%')
   order by c.member_count desc, c.created_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

create or replace function public.community_overview(p_community_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_community jsonb;
begin
  select to_jsonb(x) into v_community from (
    select c.id, c.name, c.slug, c.description, c.icon_key, c.banner_key, c.is_verified,
           c.member_count, c.rules, c.welcome, c.created_at,
           c.owner_id,
           exists (select 1 from public.community_members m
                    where m.community_id = c.id and m.user_id = v_uid) as joined,
           app.community_permissions(c.id, v_uid) as my_permissions
      from public.communities c
     where c.id = p_community_id and c.deleted_at is null
  ) x;

  if v_community is null then
    return null;
  end if;

  return jsonb_build_object(
    'community', v_community,
    'roles', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.position desc)
        from (select id, name, color, position, permissions, is_default, is_hoisted, mentionable, is_managed
                from public.community_roles where community_id = p_community_id) r
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(to_jsonb(cat) order by cat.position)
        from (select id, name, position from public.community_categories where community_id = p_community_id) cat
    ), '[]'::jsonb),
    'channels', coalesce((
      select jsonb_agg(to_jsonb(ch) order by ch.position)
        from (
          select ch.id, ch.name, ch.topic, ch.kind, ch.position, ch.category_id, ch.chat_id,
                 ch.is_private, ch.slowmode_seconds, ch.user_limit,
                 (select count(*)::int from public.community_voice_states vs where vs.channel_id = ch.id) as voice_count
            from public.community_channels ch
           where ch.community_id = p_community_id and ch.deleted_at is null
             and (app.channel_permissions(ch.id, v_uid) & app.perm_view_channel()) = app.perm_view_channel()
        ) ch
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.joined_at)
        from (
          select m.user_id, m.nickname, m.role_ids, m.joined_at,
                 coalesce(nullif(btrim(p.display_name), ''), p.username) as display_name,
                 p.username, p.discriminator, p.avatar_path, p.verified,
                 (p.last_seen_at > clock_timestamp() - interval '5 minutes') as is_online
            from public.community_members m
            join public.profiles p on p.id = m.user_id
           where m.community_id = p_community_id
           order by m.joined_at
           limit 200
        ) m
    ), '[]'::jsonb),
    'bans', case when (app.community_permissions(p_community_id, v_uid) & app.perm_ban_members()) <> 0
      then coalesce((
        select jsonb_agg(to_jsonb(b))
          from (select b.user_id, b.reason, b.created_at from public.community_bans b
                 where b.community_id = p_community_id) b
      ), '[]'::jsonb)
      else '[]'::jsonb end
  );
end;
$$;

-- Overwrites ------------------------------------------------------------------
create or replace function public.community_overwrite_set(
  p_channel_id  uuid,
  p_target_type text,
  p_target_id   uuid,
  p_allow       bigint default 0,
  p_deny        bigint default 0
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_community uuid;
begin
  select ch.community_id into v_community from public.community_channels ch where ch.id = p_channel_id;
  if v_community is null or (app.community_permissions(v_community, app.current_uid()) & app.perm_manage_roles()) = 0 then
    raise exception 'you may not manage overwrites here' using errcode = '42501';
  end if;
  if p_target_type not in ('role', 'member') then
    raise exception 'target type must be role | member' using errcode = '22023';
  end if;
  insert into public.community_channel_overwrites (channel_id, target_type, target_id, allow, deny)
  values (p_channel_id, p_target_type, p_target_id, coalesce(p_allow, 0), coalesce(p_deny, 0))
  on conflict (channel_id, target_type, target_id) do update
    set allow = excluded.allow, deny = excluded.deny;
end;
$$;

-- Voice presence ---------------------------------------------------------------
create or replace function public.voice_join(p_channel_id uuid, p_session_id text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_community uuid;
  v_limit integer;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select ch.community_id, ch.user_limit into v_community, v_limit
    from public.community_channels ch where ch.id = p_channel_id and ch.deleted_at is null;
  if v_community is null then
    raise exception 'that voice channel does not exist' using errcode = '22023';
  end if;
  if not app.channel_can(p_channel_id, v_uid, app.perm_view_channel()) then
    raise exception 'you may not join this channel' using errcode = '42501';
  end if;
  select count(*) into v_count from public.community_voice_states vs where vs.channel_id = p_channel_id;
  if v_limit > 0 and v_count >= v_limit
     and not exists (select 1 from public.community_voice_states vs
                      where vs.channel_id = p_channel_id and vs.user_id = v_uid) then
    raise exception 'that voice room is full' using errcode = '22023';
  end if;

  insert into public.community_voice_states (channel_id, user_id, session_id)
  values (p_channel_id, v_uid, p_session_id)
  on conflict (channel_id, user_id) do update
    set session_id = excluded.session_id, updated_at = clock_timestamp();
end;
$$;

create or replace function public.voice_leave(p_channel_id uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  delete from public.community_voice_states vs
   where vs.channel_id = p_channel_id and vs.user_id = app.current_uid();
$$;

create or replace function public.voice_set_state(
  p_channel_id uuid,
  p_is_muted   boolean default null,
  p_is_deafened boolean default null,
  p_is_video   boolean default null,
  p_is_streaming boolean default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.community_voice_states vs set
    is_muted     = coalesce(p_is_muted, vs.is_muted),
    is_deafened  = coalesce(p_is_deafened, vs.is_deafened),
    is_video     = coalesce(p_is_video, vs.is_video),
    is_streaming = coalesce(p_is_streaming, vs.is_streaming),
    updated_at   = clock_timestamp()
   where vs.channel_id = p_channel_id and vs.user_id = app.current_uid();
  if not found then
    if p_is_streaming then
      raise exception 'join the voice room before streaming' using errcode = '22023';
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Broadcast channels (Telegram-shaped).
-- ---------------------------------------------------------------------------
create or replace function public.channel_create(
  p_title       text,
  p_handle      text,
  p_description text default null,
  p_is_public   boolean default true,
  p_post_policy text default 'admins',
  p_avatar_key  text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_id    uuid;
  v_handle text;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) or not app.sender_may_post(v_uid) then
    raise exception 'this account may not create a channel' using errcode = '42501';
  end if;
  v_handle := lower(btrim(coalesce(p_handle, '')));
  if v_handle !~ '^[a-z0-9_]{4,32}$' then
    raise exception 'a channel handle is 4-32 characters of a-z, 0-9 and _' using errcode = '22023';
  end if;
  if p_post_policy not in ('owner', 'admins', 'everyone') then
    raise exception 'post policy must be owner | admins | everyone' using errcode = '22023';
  end if;

  insert into public.chats (kind, title, created_by, handle, description, is_public, post_policy, avatar_path)
  values ('channel', btrim(p_title), v_uid, v_handle, nullif(btrim(coalesce(p_description, '')), ''),
          coalesce(p_is_public, true), coalesce(p_post_policy, 'admins'), p_avatar_key)
  returning id into v_id;

  insert into public.chat_participants (chat_id, user_id, role)
  values (v_id, v_uid, 'owner');

  return v_id;
end;
$$;

create or replace function public.channel_join(p_chat_id uuid default null, p_handle text default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_chat public.chats%rowtype;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  if p_chat_id is not null then
    select * into v_chat from public.chats c where c.id = p_chat_id and c.kind::text = 'channel';
  elsif p_handle is not null then
    select * into v_chat from public.chats c
     where c.kind::text = 'channel' and lower(coalesce(c.handle, '')) = lower(btrim(replace(p_handle, '@', '')));
  end if;

  if v_chat.id is null then
    raise exception 'that channel does not exist' using errcode = '22023';
  end if;
  if not v_chat.is_public and not exists (
    select 1 from public.chat_participants cp where cp.chat_id = v_chat.id and cp.user_id = v_uid
  ) then
    raise exception 'this channel is private' using errcode = '42501';
  end if;

  insert into public.chat_participants (chat_id, user_id, role)
  values (v_chat.id, v_uid, 'member')
  on conflict (chat_id, user_id) do update set left_at = null, updated_at = clock_timestamp();
  return v_chat.id;
end;
$$;

create or replace function public.channel_leave(p_chat_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_role public.participant_role;
begin
  select cp.role into v_role from public.chat_participants cp
   where cp.chat_id = p_chat_id and cp.user_id = v_uid;
  if v_role = 'owner' then
    raise exception 'the owner cannot leave the channel' using errcode = '42501';
  end if;
  delete from public.chat_participants cp where cp.chat_id = p_chat_id and cp.user_id = v_uid;
end;
$$;

create or replace function public.channel_set_role(p_chat_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_is_admin boolean;
begin
  if p_role not in ('admin', 'member') then
    raise exception 'a subscriber role is admin | member' using errcode = '22023';
  end if;
  select cp.role = 'owner' into v_is_admin from public.chat_participants cp
   where cp.chat_id = p_chat_id and cp.user_id = v_uid;
  if not coalesce(v_is_admin, false) then
    raise exception 'only the channel owner may change roles' using errcode = '42501';
  end if;
  update public.chat_participants cp
     set role = p_role::public.participant_role, updated_at = clock_timestamp()
   where cp.chat_id = p_chat_id and cp.user_id = p_user_id and cp.role <> 'owner';
  if not found then
    raise exception 'that account is not a subscriber' using errcode = '22023';
  end if;
end;
$$;

create or replace function public.channel_directory(p_query text default null, p_limit integer default 30)
returns table (
  chat_id       uuid,
  title         text,
  handle        text,
  description   text,
  avatar_path   text,
  is_public     boolean,
  post_policy   text,
  subscriber_count integer,
  joined        boolean,
  my_role       text,
  last_post_at  timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select c.id, c.title, c.handle, c.description, c.avatar_path, c.is_public, c.post_policy,
         c.subscriber_count,
         exists (select 1 from public.chat_participants cp
                  where cp.chat_id = c.id and cp.user_id = app.current_uid() and cp.left_at is null),
         (select cp.role::text from public.chat_participants cp
           where cp.chat_id = c.id and cp.user_id = app.current_uid()),
         c.last_message_at
    from public.chats c
   where c.kind::text = 'channel'
     and (c.is_public
          or exists (select 1 from public.chat_participants cp
                      where cp.chat_id = c.id and cp.user_id = app.current_uid()))
     and (nullif(btrim(coalesce(p_query, '')), '') is null
          or c.title ilike '%' || btrim(p_query) || '%'
          or coalesce(c.handle, '') ilike '%' || btrim(replace(p_query, '@', '')) || '%'
          or coalesce(c.description, '') ilike '%' || btrim(p_query) || '%')
   order by c.subscriber_count desc, c.last_message_at desc nulls last
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

comment on function public.channel_directory(text, integer) is
  'Channel discovery for the Messages tab: public channels plus the ones the caller already belongs to.';

-- ---------------------------------------------------------------------------
-- 7. RLS + grants.
-- ---------------------------------------------------------------------------
alter table public.communities                 enable row level security;
alter table public.community_categories        enable row level security;
alter table public.community_roles             enable row level security;
alter table public.community_members           enable row level security;
alter table public.community_channels          enable row level security;
alter table public.community_channel_overwrites enable row level security;
alter table public.community_invites           enable row level security;
alter table public.community_bans              enable row level security;
alter table public.community_voice_states      enable row level security;

-- Membership is the read key; the RPCs above are the write path.
create or replace function app.is_community_member(p_community uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (select 1 from public.community_members m
                  where m.community_id = p_community and m.user_id = app.current_uid());
$$;

drop policy if exists communities_select on public.communities;
create policy communities_select on public.communities
  for select to authenticated
  using (
    not is_removed
    and (is_public or app.is_community_member(id))
  );

drop policy if exists community_categories_select on public.community_categories;
create policy community_categories_select on public.community_categories
  for select to authenticated
  using (app.is_community_member(community_id) or exists (
    select 1 from public.communities c where c.id = community_id and c.is_public and not c.is_removed));

drop policy if exists community_roles_select on public.community_roles;
create policy community_roles_select on public.community_roles
  for select to authenticated
  using (app.is_community_member(community_id) or exists (
    select 1 from public.communities c where c.id = community_id and c.is_public and not c.is_removed));

drop policy if exists community_members_select on public.community_members;
create policy community_members_select on public.community_members
  for select to authenticated
  using (app.is_community_member(community_id));

drop policy if exists community_channels_select on public.community_channels;
create policy community_channels_select on public.community_channels
  for select to authenticated
  using (
    deleted_at is null
    and app.is_community_member(community_id)
    and (app.channel_permissions(id, (select app.current_uid())) & app.perm_view_channel()) <> 0
  );

drop policy if exists community_overwrites_select on public.community_channel_overwrites;
create policy community_overwrites_select on public.community_channel_overwrites
  for select to authenticated
  using (exists (
    select 1 from public.community_channels ch
     where ch.id = channel_id and app.is_community_member(ch.community_id)
       and (app.community_permissions(ch.community_id, (select app.current_uid())) & app.perm_manage_roles()) <> 0));

drop policy if exists community_invites_select on public.community_invites;
create policy community_invites_select on public.community_invites
  for select to authenticated
  using (app.is_community_member(community_id));

drop policy if exists community_bans_select on public.community_bans;
create policy community_bans_select on public.community_bans
  for select to authenticated
  using ((app.community_permissions(community_id, (select app.current_uid())) & app.perm_ban_members()) <> 0);

drop policy if exists community_voice_select on public.community_voice_states;
create policy community_voice_select on public.community_voice_states
  for select to authenticated
  using (exists (select 1 from public.community_channels ch
                  where ch.id = channel_id and app.is_community_member(ch.community_id)));

grant select on public.communities, public.community_categories, public.community_roles,
                public.community_members, public.community_channels, public.community_channel_overwrites,
                public.community_invites, public.community_bans, public.community_voice_states
  to authenticated;
revoke all on public.communities, public.community_categories, public.community_roles,
              public.community_members, public.community_channels, public.community_channel_overwrites,
              public.community_invites, public.community_bans, public.community_voice_states
  from anon;

grant execute on function
  public.community_create(text, text, text, boolean, text),
  public.community_update(uuid, text, text, boolean, text, jsonb, text),
  public.community_delete(uuid),
  public.community_join(uuid, text, text),
  public.community_leave(uuid),
  public.community_channel_create(uuid, text, text, uuid, text, boolean, integer),
  public.community_channel_update(uuid, text, text, integer, boolean, integer, uuid, integer),
  public.community_channel_delete(uuid),
  public.community_role_create(uuid, text, text, bigint, boolean, boolean),
  public.community_role_update(uuid, text, text, bigint, boolean, boolean, integer),
  public.community_role_delete(uuid),
  public.community_member_set_roles(uuid, uuid, uuid[]),
  public.community_member_moderate(uuid, uuid, text, text, integer, text),
  public.community_invite_create(uuid, integer, integer, uuid),
  public.community_directory(text, integer),
  public.community_overview(uuid),
  public.community_my_permissions(uuid),
  public.community_overwrite_set(uuid, text, uuid, bigint, bigint),
  public.voice_join(uuid, text),
  public.voice_leave(uuid),
  public.voice_set_state(uuid, boolean, boolean, boolean, boolean),
  public.channel_create(text, text, text, boolean, text, text),
  public.channel_join(uuid, text),
  public.channel_leave(uuid),
  public.channel_set_role(uuid, uuid, text),
  public.channel_directory(text, integer)
to authenticated;

-- The permission bitmask accessors are called from policies, so every role that
-- can be inside a policy needs EXECUTE — including anon for the public catalogues.
grant execute on function
  app.perm_all(), app.perm_view_channel(), app.perm_send_messages(), app.perm_manage_messages(),
  app.perm_kick_members(), app.perm_ban_members(), app.perm_manage_channels(), app.perm_manage_roles(),
  app.perm_manage_community(), app.perm_create_invites(), app.perm_mention_everyone(), app.perm_attach_files(),
  app.perm_add_reactions(), app.perm_manage_bots(), app.perm_moderate_members(), app.perm_create_threads(),
  app.perm_stream(), app.perm_administrator(), app.perm_everyone_default()
to anon, authenticated, service_role;

commit;
