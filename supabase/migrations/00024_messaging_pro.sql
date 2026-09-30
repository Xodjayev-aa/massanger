-- =============================================================================
-- 00024_messaging_pro.sql
-- MessengerX 3.0 — the messaging surface reaches Telegram/Discord parity.
--
-- 00002 built a solid transport-agnostic timeline. What was missing is the set
-- of affordances people actually use every day:
--
--   reactions · replies with counters · pinned messages · forwarding ·
--   edit history · @mentions · polls (regular/quiz, anonymous, multi-answer) ·
--   chat folders · archive · saved messages · disappearing messages ·
--   scheduled sends · channel post view counts
--
-- Two design rules hold throughout:
--   1. counters and their rows move together in one trigger, so a stale number
--      is impossible rather than merely unlikely;
--   2. anything scheduled or expiring is *claimed* by whoever is awake (the
--      same pattern as the browser-push queue), which is what keeps every one
--      of these features free to run.
-- =============================================================================

begin;

alter type public.message_kind add value if not exists 'poll';

-- ---------------------------------------------------------------------------
-- 0. One helper 00024 needs everywhere: is this person an admin of the chat?
--    (`app.is_chat_member` already existed; adminship is the new question the
--    pin/channel features ask.)
-- ---------------------------------------------------------------------------
create or replace function app.is_chat_admin(p_chat_id uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.chat_participants cp
     where cp.chat_id = p_chat_id
       and cp.user_id = p_user
       and cp.left_at is null
       and cp.role in ('owner', 'admin')
  );
$$;

comment on function app.is_chat_admin(uuid, uuid) is
  'Owner or admin of a chat/channel. Channels use it for post_policy, pins use it for the pinned list.';

-- ---------------------------------------------------------------------------
-- 1. New columns on the existing core tables.
-- ---------------------------------------------------------------------------
alter table public.messages
  add column if not exists thread_root_id uuid references public.messages (id) on delete set null,
  add column if not exists reply_count    integer not null default 0 check (reply_count >= 0),
  add column if not exists reaction_count integer not null default 0 check (reaction_count >= 0),
  add column if not exists view_count     bigint not null default 0 check (view_count >= 0),
  add column if not exists forwarded_from_chat_id    uuid references public.chats (id) on delete set null,
  add column if not exists forwarded_from_message_id uuid,
  add column if not exists forwarded_from_name       text,
  add column if not exists is_pinned      boolean not null default false,
  add column if not exists expires_at     timestamptz,
  add column if not exists edited_count   smallint not null default 0 check (edited_count >= 0);

alter table public.chats
  add column if not exists ttl_seconds integer check (ttl_seconds is null or ttl_seconds between 60 and 31536000),
  add column if not exists is_saved    boolean not null default false;

alter table public.chat_participants
  add column if not exists archived_at timestamptz,
  add column if not exists folder_ids  uuid[] not null default '{}'::uuid[],
  add column if not exists draft       text check (draft is null or char_length(draft) <= 4000);

create index if not exists messages_thread_idx
  on public.messages (thread_root_id, created_at) where thread_root_id is not null and deleted_at is null;
create index if not exists messages_pinned_idx
  on public.messages (chat_id, created_at desc) where is_pinned and deleted_at is null;
create index if not exists messages_expiry_idx
  on public.messages (expires_at) where expires_at is not null and deleted_at is null;
create unique index if not exists chats_saved_key
  on public.chats (created_by) where is_saved;

comment on column public.messages.expires_at is
  'Set from chats.ttl_seconds at insert time; app.sweep_expiring_messages() deletes what is due.';
comment on column public.chats.is_saved is
  'Telegram-style Saved Messages: a one-participant direct chat with yourself, created on demand.';

-- ---------------------------------------------------------------------------
-- 2. Reactions.
-- ---------------------------------------------------------------------------
create table if not exists public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  emoji      text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default clock_timestamp(),
  primary key (message_id, user_id, emoji)
);

comment on table public.message_reactions is
  'One row per person per emoji (Discord semantics: several people may each add the same one). Discord-style custom tags render from community_roles, Telegram-style quick reactions from app.reaction_palette().';

create index if not exists message_reactions_message_idx on public.message_reactions (message_id, created_at);

create or replace function app.reaction_palette()
returns text[]
language sql
immutable
as $$ select array['👍','❤️','🔥','😂','😮','😢','🙏','🎉','💯','🤝','👀','🚀']::text[] $$;

create or replace function app.message_reactions_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.messages set reaction_count = reaction_count + 1 where id = new.message_id;
    insert into public.notifications (user_id, kind, actor_id, chat_id, payload)
    select m.sender_id, 'mention', new.user_id, m.chat_id,
           jsonb_build_object('reaction', new.emoji, 'message_id', m.id)
      from public.messages m
     where m.id = new.message_id and m.sender_id is not null and m.sender_id <> new.user_id;
  elsif tg_op = 'DELETE' then
    update public.messages set reaction_count = greatest(reaction_count - 1, 0) where id = old.message_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists message_reactions_recount on public.message_reactions;
create trigger message_reactions_recount
  after insert or delete on public.message_reactions
  for each row execute function app.message_reactions_recount();

create or replace function public.react_message(p_message_id uuid, p_emoji text)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_chat uuid;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if char_length(coalesce(p_emoji, '')) not between 1 and 16 then
    raise exception 'pick one emoji' using errcode = '22023';
  end if;

  select m.chat_id into v_chat from public.messages m where m.id = p_message_id and m.deleted_at is null;
  if v_chat is null then
    raise exception 'that message is gone' using errcode = '22023';
  end if;
  if not app.is_chat_member(v_chat, v_uid) then
    raise exception 'you are not in this chat' using errcode = '42501';
  end if;

  if exists (select 1 from public.message_reactions r
              where r.message_id = p_message_id and r.user_id = v_uid and r.emoji = p_emoji) then
    delete from public.message_reactions r
     where r.message_id = p_message_id and r.user_id = v_uid and r.emoji = p_emoji;
  else
    insert into public.message_reactions (message_id, user_id, emoji)
    values (p_message_id, v_uid, p_emoji)
    on conflict do nothing;
  end if;

  select m.reaction_count into v_count from public.messages m where m.id = p_message_id;
  return coalesce(v_count, 0);
end;
$$;

comment on function public.react_message(uuid, text) is
  'Toggle one emoji on a message (Telegram-style tap-to-toggle, several emoji allowed per person).';

create or replace function public.chat_reactions(p_chat_id uuid, p_message_ids uuid[] default null)
returns table (
  message_id uuid,
  emoji      text,
  count      integer,
  mine       boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select r.message_id, r.emoji, count(*)::int, bool_or(r.user_id = app.current_uid())
    from public.message_reactions r
    join public.messages m on m.id = r.message_id
   where m.chat_id = p_chat_id
     and app.is_chat_member(p_chat_id, app.current_uid())
     and (p_message_ids is null or r.message_id = any (p_message_ids))
   group by r.message_id, r.emoji
   order by count(*) desc, r.emoji;
$$;

-- ---------------------------------------------------------------------------
-- 3. Replies, threads, pins, forwarding, edit history.
-- ---------------------------------------------------------------------------
create or replace function app.message_replies_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    if new.reply_to_id is not null then
      update public.messages
         set reply_count = reply_count + 1,
             thread_root_id = coalesce(thread_root_id, new.reply_to_id)
       where id = new.reply_to_id;
    end if;
  elsif tg_op = 'DELETE' then
    if old.reply_to_id is not null then
      update public.messages set reply_count = greatest(reply_count - 1, 0) where id = old.reply_to_id;
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists messages_replies_recount on public.messages;
create trigger messages_replies_recount
  after insert or delete on public.messages
  for each row execute function app.message_replies_recount();

create table if not exists public.message_edits (
  id         bigint generated always as identity primary key,
  message_id uuid not null references public.messages (id) on delete cascade,
  body       text,
  edited_by  uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists message_edits_message_idx on public.message_edits (message_id, created_at desc);

comment on table public.message_edits is
  'Append-only history: every previous body, so an edit is auditable instead of silently rewriting the record.';

create or replace function app.capture_message_edit()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.body is distinct from old.body and old.deleted_at is null then
    insert into public.message_edits (message_id, body, edited_by)
    values (old.id, old.body, app.current_uid());
    new.edited_count := least(old.edited_count + 1, 32767);
  end if;
  return new;
end;
$$;

drop trigger if exists messages_capture_edit on public.messages;
create trigger messages_capture_edit
  before update of body on public.messages
  for each row execute function app.capture_message_edit();

comment on function app.guard_message_update() is
  'Clients may edit only the body of their own live message (recorded in message_edits); every other column stays frozen.';


-- 00005 made messages append-only for clients ("edits go through delete +
-- resend"). With a real edit affordance and an edit history, that rule changes
-- to Discord/Telegram semantics: the *sender* may rewrite the body, and nothing
-- else about the row becomes writable. Media, kind, authorship and timestamps
-- stay frozen, so an edit can never rewrite what a reply pointed at.
create or replace function app.guard_message_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_can_edit boolean;
begin
  if app.is_service_role() then
    return new;
  end if;

  -- Who may edit: the sender, while the message is not deleted, and only in a
  -- chat they are still in.
  v_can_edit := old.sender_id = v_uid
                and old.deleted_at is null
                and new.deleted_at is null
                and app.is_chat_member(old.chat_id, v_uid);

  if new.body is distinct from old.body and not v_can_edit then
    raise exception 'only the sender may edit a message'
      using errcode = '42501';
  end if;

  if new.kind is distinct from old.kind
     or new.media is distinct from old.media
     or new.reply_to_id is distinct from old.reply_to_id
     or new.chat_id is distinct from old.chat_id
     or new.sender_id is distinct from old.sender_id
     or new.source is distinct from old.source
     or new.tg_message_id is distinct from old.tg_message_id
     or new.tg_send_id is distinct from old.tg_send_id
  then
    raise exception 'a message edit may only change its body'
      using errcode = '42501';
  end if;

  if (new.state is distinct from old.state or new.failure_code is distinct from old.failure_code)
     and old.sender_id is distinct from v_uid
  then
    raise exception 'only the sender may change delivery state'
      using errcode = '42501';
  end if;

  if new.deleted_at is distinct from old.deleted_at and old.sender_id is distinct from v_uid then
    raise exception 'only the sender may delete a message'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create or replace function public.pin_message(p_message_id uuid, p_pinned boolean default true)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_chat uuid;
begin
  select m.chat_id into v_chat from public.messages m where m.id = p_message_id and m.deleted_at is null;
  if v_chat is null then
    raise exception 'that message is gone' using errcode = '22023';
  end if;
  if not app.is_chat_admin(v_chat, v_uid) then
    raise exception 'only an admin may pin messages here' using errcode = '42501';
  end if;
  update public.messages set is_pinned = p_pinned, updated_at = clock_timestamp() where id = p_message_id;
  if p_pinned then
    insert into public.notifications (user_id, kind, actor_id, chat_id, payload)
    select cp.user_id, 'system', v_uid, v_chat, jsonb_build_object('pinned', p_message_id)
      from public.chat_participants cp
     where cp.chat_id = v_chat and cp.user_id <> v_uid and cp.left_at is null;
  end if;
end;
$$;

create or replace function public.chat_pinned(p_chat_id uuid, p_limit integer default 20)
returns table (
  id         uuid,
  body       text,
  kind       text,
  sender_name text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select m.id, m.body, m.kind::text, m.sender_name, m.created_at
    from public.messages m
   where m.chat_id = p_chat_id
     and m.is_pinned
     and m.deleted_at is null
     and app.is_chat_member(p_chat_id, app.current_uid())
   order by m.created_at desc
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

-- Forward: one row per target chat, source snapshot preserved, no reply graph
-- carried over (a forwarded message is a new message).
create or replace function public.forward_message(p_message_id uuid, p_target_chat_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_source public.messages%rowtype;
  v_chat   uuid;
  v_chat_row public.chats%rowtype;
  v_count  integer := 0;
  v_name   text;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_target_chat_ids is null or array_length(p_target_chat_ids, 1) is null then
    raise exception 'pick at least one chat' using errcode = '22023';
  end if;

  select * into v_source from public.messages m where m.id = p_message_id and m.deleted_at is null;
  if not found then
    raise exception 'that message is gone' using errcode = '22023';
  end if;
  if not app.is_chat_member(v_source.chat_id, v_uid) then
    raise exception 'you are not in the source chat' using errcode = '42501';
  end if;

  select coalesce(nullif(btrim(c.title), ''), 'Chat') into v_name
    from public.chats c where c.id = v_source.chat_id;
  v_name := coalesce(v_source.sender_name, v_name);

  foreach v_chat in array p_target_chat_ids loop
    if not app.is_chat_member(v_chat, v_uid) then
      continue;   -- silently skip chats the caller cannot post in
    end if;
    select * into v_chat_row from public.chats c where c.id = v_chat;
    if v_chat_row.kind::text = 'channel' then
      if not app.is_chat_admin(v_chat, v_uid) and v_chat_row.post_policy <> 'everyone' then
        continue;
      end if;
    end if;

    insert into public.messages (
      chat_id, sender_id, kind, body, media, source,
      forwarded_from_chat_id, forwarded_from_message_id, forwarded_from_name
    ) values (
      v_chat, v_uid, v_source.kind, v_source.body, v_source.media, 'app',
      v_source.chat_id, v_source.id, v_name
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.is_chat_admin_public(p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$ select app.is_chat_admin(p_chat_id, app.current_uid()) $$;

-- ---------------------------------------------------------------------------
-- 4. Mentions.
-- ---------------------------------------------------------------------------
create table if not exists public.message_mentions (
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (message_id, user_id)
);

create index if not exists message_mentions_user_idx on public.message_mentions (user_id, created_at desc);

comment on table public.message_mentions is
  'Resolved @handles per message. Written by app.resolve_message_mentions() from the body, so the client never decides who was mentioned.';

create or replace function app.resolve_message_mentions()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_handle text;
  v_user   uuid;
begin
  if new.kind::text <> 'text' or new.body is null or new.deleted_at is not null then
    return new;
  end if;

  for v_handle in
    select distinct lower(m[1])
      from regexp_matches(new.body, '@([A-Za-z0-9_.]{3,32})', 'g') as m
  loop
    select p.id into v_user from public.profiles p
     where p.username_norm = v_handle and p.deleted_at is null;
    continue when v_user is null;

    insert into public.message_mentions (message_id, user_id) values (new.id, v_user)
    on conflict do nothing;

    if v_user <> coalesce(new.sender_id, '00000000-0000-0000-0000-000000000000'::uuid) then
      insert into public.notifications (user_id, kind, actor_id, chat_id, payload)
      values (v_user, 'mention', new.sender_id, new.chat_id,
              jsonb_build_object('excerpt', left(coalesce(new.body, ''), 140), 'message_id', new.id));
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists messages_resolve_mentions on public.messages;
create trigger messages_resolve_mentions
  after insert on public.messages
  for each row execute function app.resolve_message_mentions();

-- ---------------------------------------------------------------------------
-- 5. Polls (Telegram shape: regular or quiz, anonymous, single or multi).
-- ---------------------------------------------------------------------------
create table if not exists public.polls (
  id                  uuid primary key default app.uuid_v7(),
  chat_id             uuid not null references public.chats (id) on delete cascade,
  message_id          uuid references public.messages (id) on delete cascade,
  created_by          uuid not null references public.profiles (id) on delete cascade,
  question            text not null check (char_length(btrim(question)) between 1 and 300),
  kind                text not null default 'regular' check (kind in ('regular', 'quiz')),
  is_anonymous        boolean not null default true,
  allows_multiple     boolean not null default false,
  correct_option      smallint,
  explanation         text check (explanation is null or char_length(explanation) <= 500),
  closes_at           timestamptz,
  closed_at           timestamptz,
  total_votes         integer not null default 0 check (total_votes >= 0),
  created_at          timestamptz not null default clock_timestamp(),
  constraint polls_correct_option check (kind <> 'quiz' or correct_option is not null)
);

create table if not exists public.poll_options (
  id         uuid primary key default app.uuid_v7(),
  poll_id    uuid not null references public.polls (id) on delete cascade,
  text       text not null check (char_length(btrim(text)) between 1 and 100),
  position   integer not null default 0,
  vote_count integer not null default 0 check (vote_count >= 0)
);

create index if not exists poll_options_idx on public.poll_options (poll_id, position);

create table if not exists public.poll_votes (
  poll_id    uuid not null references public.polls (id) on delete cascade,
  option_id  uuid not null references public.poll_options (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (poll_id, option_id, user_id)
);

create or replace function app.poll_votes_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    update public.poll_options set vote_count = vote_count + 1 where id = new.option_id;
    update public.polls set total_votes = total_votes + 1 where id = new.poll_id;
  elsif tg_op = 'DELETE' then
    update public.poll_options set vote_count = greatest(vote_count - 1, 0) where id = old.option_id;
    update public.polls set total_votes = greatest(total_votes - 1, 0) where id = old.poll_id;
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists poll_votes_recount on public.poll_votes;
create trigger poll_votes_recount
  after insert or delete on public.poll_votes
  for each row execute function app.poll_votes_recount();

create or replace function public.poll_create(
  p_chat_id        uuid,
  p_question       text,
  p_options        text[],
  p_kind           text default 'regular',
  p_is_anonymous   boolean default true,
  p_allows_multiple boolean default false,
  p_correct_option integer default null,
  p_explanation    text default null,
  p_closes_in_minutes integer default null,
  p_client_message_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_poll   uuid;
  v_msg    uuid;
  v_opt    text;
  v_pos    integer := 0;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'you are not in this chat' using errcode = '42501';
  end if;
  if p_options is null or array_length(p_options, 1) < 2 or array_length(p_options, 1) > 12 then
    raise exception 'a poll needs between 2 and 12 options' using errcode = '22023';
  end if;
  if p_kind not in ('regular', 'quiz') then
    raise exception 'poll kind must be regular | quiz' using errcode = '22023';
  end if;
  if p_kind = 'quiz' and not p_allows_multiple
     and (p_correct_option is null or p_correct_option < 0 or p_correct_option >= array_length(p_options, 1)) then
    raise exception 'a quiz needs its correct option' using errcode = '22023';
  end if;

  insert into public.polls (chat_id, created_by, question, kind, is_anonymous, allows_multiple,
                            correct_option, explanation, closes_at)
  values (p_chat_id, v_uid, btrim(p_question), p_kind, coalesce(p_is_anonymous, true),
          coalesce(p_allows_multiple, false),
          case when p_kind = 'quiz' then p_correct_option::smallint else null end,
          nullif(btrim(coalesce(p_explanation, '')), ''),
          case when p_closes_in_minutes is null or p_closes_in_minutes <= 0 then null
               else clock_timestamp() + make_interval(mins => p_closes_in_minutes) end)
  returning id into v_poll;

  foreach v_opt in array p_options loop
    insert into public.poll_options (poll_id, text, position)
    values (v_poll, btrim(v_opt), v_pos);
    v_pos := v_pos + 1;
  end loop;

  -- The poll is also a message, so it lands in the timeline with an unread
  -- badge for everybody else exactly like any other message.
  insert into public.messages (chat_id, sender_id, kind, media, client_message_id)
  values (p_chat_id, v_uid, 'poll', jsonb_build_object('poll_id', v_poll),
          coalesce(p_client_message_id, app.uuid_v7()))
  returning id into v_msg;

  update public.polls set message_id = v_msg where id = v_poll;
  return v_msg;
end;
$$;

comment on function public.poll_create(uuid, text, text[], text, boolean, boolean, integer, text, integer, uuid) is
  'Creates a poll and the message that carries it in one transaction, so a poll is never a message without a vote target.';

create or replace function public.poll_vote(p_poll_id uuid, p_option_ids uuid[])
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_poll public.polls%rowtype;
  v_opt  uuid;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select * into v_poll from public.polls p where p.id = p_poll_id;
  if not found then
    raise exception 'that poll is gone' using errcode = '22023';
  end if;
  if v_poll.closed_at is not null or (v_poll.closes_at is not null and v_poll.closes_at < clock_timestamp()) then
    raise exception 'that poll is closed' using errcode = '22023';
  end if;
  if not app.is_chat_member(v_poll.chat_id, v_uid) then
    raise exception 'you are not in this chat' using errcode = '42501';
  end if;
  if p_option_ids is null or array_length(p_option_ids, 1) is null then
    raise exception 'pick an option' using errcode = '22023';
  end if;
  if array_length(p_option_ids, 1) > 1 and not v_poll.allows_multiple then
    raise exception 'this poll takes one answer' using errcode = '22023';
  end if;

  -- Retracting is the same call: an empty selection is expressed by voting for
  -- exactly the options you want to have selected.
  delete from public.poll_votes v where v.poll_id = p_poll_id and v.user_id = v_uid;

  foreach v_opt in array p_option_ids loop
    if not exists (select 1 from public.poll_options o where o.id = v_opt and o.poll_id = p_poll_id) then
      raise exception 'that option does not belong to this poll' using errcode = '22023';
    end if;
    insert into public.poll_votes (poll_id, option_id, user_id) values (p_poll_id, v_opt, v_uid)
    on conflict do nothing;
  end loop;

  -- A quiz result reveals correctness only to the voter.
  if v_poll.kind = 'quiz' and v_poll.correct_option is not null then
    return exists (
      select 1 from public.poll_options o
       where o.id = any (p_option_ids) and o.position = v_poll.correct_option
    );
  end if;
  return v_poll.kind <> 'quiz';
end;
$$;

create or replace function public.poll_results(p_poll_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_poll public.polls%rowtype;
  v_closed boolean;
begin
  select * into v_poll from public.polls p where p.id = p_poll_id;
  if not found then
    raise exception 'that poll is gone' using errcode = '22023';
  end if;
  if not app.is_chat_member(v_poll.chat_id, v_uid) then
    raise exception 'you are not in this chat' using errcode = '42501';
  end if;
  v_closed := v_poll.closed_at is not null
              or (v_poll.closes_at is not null and v_poll.closes_at < clock_timestamp());

  return jsonb_build_object(
    'id', v_poll.id,
    'question', v_poll.question,
    'kind', v_poll.kind,
    'is_anonymous', v_poll.is_anonymous,
    'allows_multiple', v_poll.allows_multiple,
    'total_votes', v_poll.total_votes,
    'closed', v_closed,
    'closes_at', v_poll.closes_at,
    'explanation', case when v_closed then v_poll.explanation else null end,
    'correct_option', case when v_closed or v_poll.kind <> 'quiz' then v_poll.correct_option else null end,
    'my_options', coalesce((
      select jsonb_agg(v.option_id)
        from public.poll_votes v
       where v.poll_id = p_poll_id and v.user_id = v_uid
    ), '[]'::jsonb),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'text', o.text, 'position', o.position, 'votes', o.vote_count,
               'is_correct', case when (v_closed or v_poll.kind <> 'quiz') and v_poll.correct_option is not null
                                  then o.position = v_poll.correct_option else null end,
               -- Not-anonymous polls expose voters to participants; anonymous
               -- ones expose counts only, which is the whole point.
               'voters', case when v_poll.is_anonymous or (v_poll.kind = 'quiz' and not v_closed) then null
                              else coalesce((
                                select jsonb_agg(jsonb_build_object(
                                         'id', p.id, 'username', p.username,
                                         'name', coalesce(nullif(btrim(p.display_name), ''), p.username)))
                                  from public.poll_votes v2
                                  join public.profiles p on p.id = v2.user_id
                                 where v2.option_id = o.id
                              ), '[]'::jsonb) end
             ) order by o.position)
        from public.poll_options o where o.poll_id = p_poll_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.poll_close(p_poll_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  update public.polls p
     set closed_at = clock_timestamp()
   where p.id = p_poll_id
     and p.created_by = v_uid
     and p.closed_at is null;
  if not found then
    raise exception 'only the poll author may close it' using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Chat folders and archive (Telegram's organising tools).
-- ---------------------------------------------------------------------------
create table if not exists public.chat_folders (
  id         uuid primary key default app.uuid_v7(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  title      text not null check (char_length(btrim(title)) between 1 and 40),
  emoji      text check (emoji is null or char_length(emoji) <= 8),
  position   integer not null default 0,
  -- { "kinds": ["direct","group","channel"], "include_ids": [...], "exclude_ids": [...],
  --   "exclude_muted": true, "exclude_read": false, "community_id": null }
  rules      jsonb not null default '{}'::jsonb,
  is_default boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint chat_folders_rules_shape check (jsonb_typeof(rules) = 'object' and pg_column_size(rules) <= 4096)
);

comment on table public.chat_folders is
  'Telegram-style folders. Rules are evaluated in chat_folders_members() rather than stored as a hand-maintained member list.';

create index if not exists chat_folders_user_idx on public.chat_folders (user_id, position);

create or replace function public.chat_folder_save(
  p_folder_id uuid default null,
  p_title     text default null,
  p_emoji     text default null,
  p_rules     jsonb default null,
  p_position  integer default null
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
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_folder_id is null then
    insert into public.chat_folders (user_id, title, emoji, rules, position)
    values (v_uid, btrim(p_title), nullif(btrim(coalesce(p_emoji, '')), ''), coalesce(p_rules, '{}'::jsonb),
            coalesce(p_position, coalesce((select max(f.position) + 1 from public.chat_folders f where f.user_id = v_uid), 0)))
    returning id into v_id;
    return v_id;
  end if;

  update public.chat_folders f set
    title      = coalesce(nullif(btrim(p_title), ''), f.title),
    emoji      = case when p_emoji is null then f.emoji else nullif(btrim(p_emoji), '') end,
    rules      = coalesce(p_rules, f.rules),
    position   = coalesce(p_position, f.position),
    updated_at = clock_timestamp()
   where f.id = p_folder_id and f.user_id = v_uid;
  if not found then
    raise exception 'that folder is not yours' using errcode = '42501';
  end if;
  return p_folder_id;
end;
$$;

create or replace function public.chat_folder_delete(p_folder_id uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  delete from public.chat_folders f where f.id = p_folder_id and f.user_id = app.current_uid();
$$;

-- Folder membership is derived: a rule change re-shapes the folder instantly.
-- Groups were the one chat kind a client could only assemble by hand (a chat
-- row, then a participant row per member). One RPC makes that atomic, checks
-- eligibility once, and leaves a system notice so the history reads properly.
create or replace function public.create_group_chat(
  p_title      text,
  p_member_ids uuid[],
  p_topic      text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_chat   uuid;
  v_title  text := nullif(left(btrim(coalesce(p_title, '')), 64), '');
  v_member uuid;
  v_added  integer := 0;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'account is not eligible yet' using errcode = '42501';
  end if;

  select count(distinct m) into v_added
    from unnest(coalesce(p_member_ids, '{}'::uuid[])) as m
   where m <> v_uid;
  if v_added = 0 then
    raise exception 'a group needs at least one other member' using errcode = '22023';
  end if;
  if v_added > 499 then
    raise exception 'a group holds at most 500 members' using errcode = '22023';
  end if;

  insert into public.chats (kind, title, created_by, is_public, description)
  values ('group', coalesce(v_title, 'New group'), v_uid, false, left(nullif(btrim(coalesce(p_topic, '')), ''), 512))
  returning id into v_chat;

  insert into public.chat_participants (chat_id, user_id, role)
  values (v_chat, v_uid, 'owner');

  for v_member in
    select distinct m from unnest(coalesce(p_member_ids, '{}'::uuid[])) as m
     where m <> v_uid
  loop
    insert into public.chat_participants (chat_id, user_id, role)
    select v_chat, p.id, 'member'
      from public.profiles p
     where p.id = v_member
       and p.deleted_at is null
       and app.can_view_user(v_uid, p.id)
    on conflict (chat_id, user_id) do nothing;
  end loop;

  insert into public.messages (chat_id, kind, body, source)
  values (v_chat, 'system', 'Group created', 'app');

  return v_chat;
end;
$$;

comment on function public.create_group_chat(text, uuid[], text) is
  'Creates a group, adds the caller as owner and every reachable member, and drops a system notice into the history.';

create or replace function public.chat_folders_with_counts()
returns table (
  id         uuid,
  title      text,
  emoji      text,
  -- `position` cannot be a RETURNS TABLE parameter name (Postgres parses it as
  -- the POSITION() function), so the output column is named for what it is.
  sort_order integer,
  unread     integer,
  chat_count integer
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select f.id,
         f.title,
         f.emoji,
         f.position,
         coalesce((
           select sum(cp.unread_count)::int
             from public.chat_participants cp
             join public.chats c on c.id = cp.chat_id
            where cp.user_id = f.user_id
              and cp.left_at is null
              and cp.unread_count > 0
              and (f.rules -> 'kinds' is null
                   or c.kind::text = any (select jsonb_array_elements_text(f.rules -> 'kinds')))
              and not (coalesce((f.rules ->> 'exclude_muted')::boolean, false)
                       and cp.muted_until is not null and cp.muted_until > clock_timestamp())
              and not (coalesce((f.rules ->> 'exclude_archived')::boolean, false) and cp.archived_at is not null)
              and (f.rules -> 'include_ids' is null
                   or c.id::text in (select jsonb_array_elements_text(f.rules -> 'include_ids')))
              and (f.rules -> 'exclude_ids' is null
                   or c.id::text not in (select jsonb_array_elements_text(f.rules -> 'exclude_ids')))
         ), 0) as unread,
         coalesce((
           select count(*)::int
             from public.chat_participants cp
             join public.chats c on c.id = cp.chat_id
            where cp.user_id = f.user_id
              and cp.left_at is null
              and (f.rules -> 'kinds' is null
                   or c.kind::text = any (select jsonb_array_elements_text(f.rules -> 'kinds')))
              and not (coalesce((f.rules ->> 'exclude_archived')::boolean, false) and cp.archived_at is not null)
              and (f.rules -> 'include_ids' is null
                   or c.id::text in (select jsonb_array_elements_text(f.rules -> 'include_ids')))
              and (f.rules -> 'exclude_ids' is null
                   or c.id::text not in (select jsonb_array_elements_text(f.rules -> 'exclude_ids')))
         ), 0) as chat_count
    from public.chat_folders f
   where f.user_id = app.current_uid()
   order by f.position, f.created_at;
$$;

create or replace function public.set_chat_archived(p_chat_id uuid, p_archived boolean default true)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.chat_participants cp
     set archived_at = case when p_archived then clock_timestamp() else null end,
         updated_at = clock_timestamp()
   where cp.chat_id = p_chat_id and cp.user_id = app.current_uid();
$$;

create or replace function public.set_chat_ttl(p_chat_id uuid, p_seconds integer)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.chats c
     set ttl_seconds = case when p_seconds is null or p_seconds <= 0 then null
                            else least(greatest(p_seconds, 60), 31536000) end,
         updated_at = clock_timestamp()
   where c.id = p_chat_id
     and app.is_chat_admin(p_chat_id, app.current_uid());
$$;

create or replace function public.saved_chat()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select c.id into v_id from public.chats c where c.is_saved and c.created_by = v_uid;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.chats (kind, title, created_by, is_saved)
  values ('direct', null, v_uid, true)
  returning id into v_id;

  insert into public.chat_participants (chat_id, user_id, role)
  values (v_id, v_uid, 'owner');
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Scheduled sends and disappearing messages.
--
-- Both are claim-based, exactly like the browser-push queue: whoever is awake
-- drains the work, so no always-on worker is required for either feature.
-- ---------------------------------------------------------------------------
create table if not exists public.scheduled_messages (
  id            uuid primary key default app.uuid_v7(),
  chat_id       uuid not null references public.chats (id) on delete cascade,
  sender_id     uuid not null references public.profiles (id) on delete cascade,
  kind          public.message_kind not null default 'text',
  body          text check (body is null or char_length(body) <= 8000),
  media         jsonb,
  reply_to_id   uuid references public.messages (id) on delete set null,
  client_message_id uuid not null unique,
  scheduled_for timestamptz not null,
  state         text not null default 'queued' check (state in ('queued', 'sending', 'sent', 'failed', 'cancelled')),
  attempts      smallint not null default 0 check (attempts between 0 and 255),
  last_error    text,
  sent_message_id uuid references public.messages (id) on delete set null,
  claimed_at    timestamptz,
  claimed_by    text,
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp()
);

create index if not exists scheduled_messages_due_idx
  on public.scheduled_messages (scheduled_for) where state = 'queued';

comment on table public.scheduled_messages is
  'Scheduled sends. app.claim_scheduled_messages() leases due rows; any awake client or a cron can drain them.';

create or replace function public.schedule_message(
  p_chat_id     uuid,
  p_body        text,
  p_send_at     timestamptz,
  p_kind        public.message_kind default 'text',
  p_media       jsonb default null,
  p_reply_to_id uuid default null,
  p_client_message_id uuid default null
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
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'you are not in this chat' using errcode = '42501';
  end if;
  if p_send_at is null or p_send_at < clock_timestamp() + interval '30 seconds' then
    raise exception 'pick a time at least 30 seconds from now' using errcode = '22023';
  end if;
  perform app.validate_message_media(p_kind, p_media);

  insert into public.scheduled_messages (chat_id, sender_id, kind, body, media, reply_to_id,
                                         client_message_id, scheduled_for)
  values (p_chat_id, v_uid, p_kind, p_body, p_media, p_reply_to_id,
          coalesce(p_client_message_id, app.uuid_v7()), p_send_at)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.scheduled_messages_list()
returns table (
  id            uuid,
  chat_id       uuid,
  kind          text,
  body          text,
  media         jsonb,
  scheduled_for timestamptz,
  state         text,
  chat_title    text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select s.id, s.chat_id, s.kind::text, s.body, s.media, s.scheduled_for, s.state,
         coalesce(nullif(btrim(c.title), ''), 'Chat')
    from public.scheduled_messages s
    join public.chats c on c.id = s.chat_id
   where s.sender_id = app.current_uid() and s.state in ('queued', 'failed')
   order by s.scheduled_for;
$$;

create or replace function public.cancel_scheduled_message(p_id uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.scheduled_messages s
     set state = 'cancelled', updated_at = clock_timestamp()
   where s.id = p_id and s.sender_id = app.current_uid() and s.state in ('queued', 'failed');
$$;

-- Lease due rows. `p_lease_seconds` bounds how long a claim is honoured if the
-- caller dies mid-send; the row returns to the queue after that.
create or replace function app.claim_scheduled_messages(p_worker text, p_limit integer default 25, p_lease_seconds integer default 60)
returns setof public.scheduled_messages
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  return query
  with due as (
    select s.id
      from public.scheduled_messages s
     where s.state = 'queued'
       and s.scheduled_for <= clock_timestamp()
       and (s.claimed_at is null or s.claimed_at < clock_timestamp() - make_interval(secs => greatest(p_lease_seconds, 5)))
     order by s.scheduled_for
     limit least(greatest(coalesce(p_limit, 25), 1), 100)
     for update skip locked
  )
  update public.scheduled_messages s
     set state = 'sending', claimed_at = clock_timestamp(), claimed_by = p_worker, attempts = s.attempts + 1
    from due
   where s.id = due.id
  returning s.*;
end;
$$;

create or replace function app.send_scheduled_message(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_row public.scheduled_messages%rowtype;
  v_msg uuid;
begin
  select * into v_row from public.scheduled_messages s where s.id = p_id;
  if not found or v_row.state not in ('sending', 'queued') then
    return null;
  end if;

  begin
    insert into public.messages (chat_id, sender_id, kind, body, media, reply_to_id, client_message_id, source)
    values (v_row.chat_id, v_row.sender_id, v_row.kind, v_row.body, v_row.media, v_row.reply_to_id,
            v_row.client_message_id, 'app')
    returning id into v_msg;

    update public.scheduled_messages
       set state = 'sent', sent_message_id = v_msg, updated_at = clock_timestamp()
     where id = p_id;
    return v_msg;
  exception when others then
    update public.scheduled_messages
       set state = case when attempts >= 5 then 'failed' else 'queued' end,
           last_error = left(sqlerrm, 400),
           claimed_at = null,
           updated_at = clock_timestamp()
     where id = p_id;
    return null;
  end;
end;
$$;

comment on function app.claim_scheduled_messages(text, integer, integer) is
  'Leases due scheduled sends (FOR UPDATE SKIP LOCKED). The client that claims a row calls app.send_scheduled_message() on it.';

-- ---------------------------------------------------------------------------
-- 8. Expiry: TTL is stamped on insert, swept by whoever is awake.
-- ---------------------------------------------------------------------------
create or replace function app.stamp_message_expiry()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_ttl integer;
begin
  if new.expires_at is not null then
    return new;
  end if;
  select c.ttl_seconds into v_ttl from public.chats c where c.id = new.chat_id;
  if v_ttl is not null then
    new.expires_at := coalesce(new.created_at, clock_timestamp()) + make_interval(secs => v_ttl);
  end if;
  return new;
end;
$$;

drop trigger if exists messages_stamp_expiry on public.messages;
create trigger messages_stamp_expiry
  before insert on public.messages
  for each row execute function app.stamp_message_expiry();

create or replace function public.sweep_expiring_messages(p_limit integer default 200)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_deleted integer;
begin
  with due as (
    select m.id from public.messages m
     where m.expires_at is not null
       and m.expires_at <= clock_timestamp()
       and m.deleted_at is null
     order by m.expires_at
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)
  )
  delete from public.messages m using due where m.id = due.id;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- Channel post view counting: a subscriber opening a channel marks the posts
-- they actually saw, which is the number a channel owner cares about.
create or replace function public.mark_channel_views(p_chat_id uuid, p_message_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_count integer;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.is_chat_member(p_chat_id, v_uid) then
    raise exception 'you are not in this channel' using errcode = '42501';
  end if;
  with touched as (
    update public.messages m
       set view_count = view_count + 1
     where m.chat_id = p_chat_id
       and m.id = any (p_message_ids)
       and m.sender_id <> v_uid
    returning m.id
  )
  select count(*)::int into v_count from touched;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. RLS + grants.
-- ---------------------------------------------------------------------------
alter table public.message_reactions  enable row level security;
alter table public.message_edits      enable row level security;
alter table public.message_mentions   enable row level security;
alter table public.polls              enable row level security;
alter table public.poll_options       enable row level security;
alter table public.poll_votes         enable row level security;
alter table public.chat_folders       enable row level security;
alter table public.scheduled_messages enable row level security;

drop policy if exists message_reactions_member on public.message_reactions;
create policy message_reactions_member on public.message_reactions
  for select to authenticated
  using (exists (select 1 from public.messages m
                  where m.id = message_id and app.is_chat_member(m.chat_id, (select app.current_uid()))));

drop policy if exists message_edits_member on public.message_edits;
create policy message_edits_member on public.message_edits
  for select to authenticated
  using (exists (select 1 from public.messages m
                  where m.id = message_id and app.is_chat_member(m.chat_id, (select app.current_uid()))));

drop policy if exists message_mentions_self on public.message_mentions;
create policy message_mentions_self on public.message_mentions
  for select to authenticated
  using (user_id = (select app.current_uid())
         or exists (select 1 from public.messages m
                     where m.id = message_id and m.sender_id = (select app.current_uid())));

drop policy if exists polls_member on public.polls;
create policy polls_member on public.polls
  for select to authenticated
  using (app.is_chat_member(chat_id, (select app.current_uid())));

drop policy if exists poll_options_member on public.poll_options;
create policy poll_options_member on public.poll_options
  for select to authenticated
  using (exists (select 1 from public.polls p
                  where p.id = poll_id and app.is_chat_member(p.chat_id, (select app.current_uid()))));

drop policy if exists poll_votes_member on public.poll_votes;
create policy poll_votes_member on public.poll_votes
  for select to authenticated
  using (
    user_id = (select app.current_uid())
    or exists (
      select 1 from public.polls p
       where p.id = poll_id and not p.is_anonymous
         and app.is_chat_member(p.chat_id, (select app.current_uid()))
    )
  );

drop policy if exists chat_folders_own on public.chat_folders;
create policy chat_folders_own on public.chat_folders
  for all to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

drop policy if exists scheduled_messages_own on public.scheduled_messages;
create policy scheduled_messages_own on public.scheduled_messages
  for select to authenticated
  using (sender_id = (select app.current_uid()));

grant select on public.message_reactions, public.message_edits, public.message_mentions,
                public.polls, public.poll_options, public.poll_votes
  to authenticated;
grant select, insert, update, delete on public.chat_folders to authenticated;
grant select, update on public.scheduled_messages to authenticated;
revoke all on public.message_reactions, public.message_edits, public.message_mentions,
              public.polls, public.poll_options, public.poll_votes, public.chat_folders,
              public.scheduled_messages
  from anon;

grant execute on function
  public.create_group_chat(text, uuid[], text),
  public.react_message(uuid, text),
  public.chat_reactions(uuid, uuid[]),
  public.pin_message(uuid, boolean),
  public.chat_pinned(uuid, integer),
  public.forward_message(uuid, uuid[]),
  public.is_chat_admin_public(uuid),
  public.poll_create(uuid, text, text[], text, boolean, boolean, integer, text, integer, uuid),
  public.poll_vote(uuid, uuid[]),
  public.poll_results(uuid),
  public.poll_close(uuid),
  public.chat_folder_save(uuid, text, text, jsonb, integer),
  public.chat_folder_delete(uuid),
  public.chat_folders_with_counts(),
  public.set_chat_archived(uuid, boolean),
  public.set_chat_ttl(uuid, integer),
  public.saved_chat(),
  public.schedule_message(uuid, text, timestamptz, public.message_kind, jsonb, uuid, uuid),
  public.scheduled_messages_list(),
  public.cancel_scheduled_message(uuid),
  public.sweep_expiring_messages(integer),
  public.mark_channel_views(uuid, uuid[])
to authenticated;

-- The sender is claimed by the app (any awake client) or by a cron; both run as
-- an authenticated/service caller, never as a client-supplied row.
grant execute on function app.claim_scheduled_messages(text, integer, integer),
                          app.send_scheduled_message(uuid)
to authenticated, service_role;

comment on function public.set_chat_ttl(uuid, integer) is
  'Disappearing messages: per-chat TTL, applied at insert time (app.stamp_message_expiry) and swept by sweep_expiring_messages().';

commit;
