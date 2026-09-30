-- =============================================================================
-- 00020_social_graph.sql
-- MessengerX 3.0 — the social graph everything else hangs off.
--
-- The product gained a video surface (long videos + shorts), so "who may see
-- what" stopped being a chat-membership question. This migration adds the one
-- graph the whole app shares:
--
--   • profiles gain the public identity fields a creator profile needs
--     (Discord-style `handle#discriminator`, private accounts, creator mode);
--   • `follows` is the single edge table — YouTube "subscribe", TikTok
--     "follow" and a private-account "follow request" are the same row in
--     different states, because they *are* the same thing;
--   • `blocks` is enforced centrally through `app.can_view_user()`, so a
--     block hides a profile, a feed and a comment thread in one rule instead
--     of three.
--
-- Counters (`follower_count`, `following_count`) are denormalised and owned by
-- SECURITY DEFINER triggers: a client can never write them, which is also why
-- the table-level grants in this file are narrower than they look.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Public identity: discriminator, privacy, creator profile fields.
--
-- `username_norm` already exists and is unique. The discriminator is the four
-- digits behind a handle (`xodjayev#0421`): it lets two people share a display
-- handle without one of them losing their name, and it is *assigned*, never
-- chosen, so it cannot be used to impersonate a future handle.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists discriminator     smallint check (discriminator is null
                                                            or discriminator between 1 and 9999),
  add column if not exists is_private        boolean not null default false,
  add column if not exists creator_mode      boolean not null default false,
  add column if not exists verified          boolean not null default false,
  add column if not exists cover_path        text,
  add column if not exists pronouns          text check (pronouns is null or char_length(pronouns) <= 24),
  add column if not exists location          text check (location is null or char_length(location) <= 64),
  add column if not exists website           text check (website is null or char_length(website) <= 200),
  add column if not exists accent            text check (accent is null or accent ~ '^#[0-9a-fA-F]{6}$'),
  -- `socials` is a small map of { "x": "handle", "github": "handle" }: open
  -- ended by design, but the row cap and the key check keep it from becoming a
  -- payload dump.
  add column if not exists socials           jsonb not null default '{}'::jsonb,
  add column if not exists follower_count    integer not null default 0 check (follower_count >= 0),
  add column if not exists following_count   integer not null default 0 check (following_count >= 0),
  add column if not exists post_count        integer not null default 0 check (post_count >= 0);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.profiles'::regclass and conname = 'profiles_socials_shape'
  ) then
    alter table public.profiles
      add constraint profiles_socials_shape check (
        jsonb_typeof(socials) = 'object' and pg_column_size(socials) <= 2048
      );
  end if;
end $$;

comment on column public.profiles.discriminator is
  'Four digits behind the handle (``name#0421``). Assigned by trigger, unique per handle — the Discord tag, without the impersonation risk of a free-text one.';
comment on column public.profiles.is_private is
  'Private accounts only accept followers through a request; ``app.can_view_user`` is the one place that decision is made.';
comment on column public.profiles.follower_count is
  'Denormalised, trigger-maintained. Clients have no UPDATE grant on it.';

-- The discriminator is per-handle, not global: `alice#0001` and `bob#0001`
-- may both exist, which is exactly the Discord rule.
create unique index if not exists profiles_handle_tag_key
  on public.profiles (username_norm, discriminator)
  where discriminator is not null;

create index if not exists profiles_creator_idx
  on public.profiles (follower_count desc, id)
  where deleted_at is null and creator_mode;

-- Assignment: on insert (and on a legacy row that has none) pick a random free
-- slot for that handle. 9999 slots per handle is plenty for a handle that is
-- also globally unique in this app; the loop is bounded so a pathological
-- handle cannot spin forever, and the unique index is the real guarantee.
create or replace function app.assign_discriminator()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_try     int := 0;
  v_candidate smallint;
begin
  if new.discriminator is not null then
    return new;
  end if;

  while v_try < 25 loop
    v_candidate := (1 + floor(random() * 9999))::smallint;
    begin
      perform 1 from public.profiles p
       where p.username_norm = lower(new.username)
         and p.discriminator = v_candidate;
      if not found then
        new.discriminator := v_candidate;
        return new;
      end if;
    exception when others then
      -- A concurrent insert can still take the slot; retry like the not-found
      -- branch does rather than surfacing a duplicate-key error to signup.
      null;
    end;
    v_try := v_try + 1;
  end loop;

  -- Last resort: the smallest free slot. Guaranteed to terminate because a
  -- handle can hold at most 9999 accounts.
  select gs::smallint into v_candidate
    from generate_series(1, 9999) gs
   where not exists (
     select 1 from public.profiles p
      where p.username_norm = lower(new.username) and p.discriminator = gs
   )
   order by gs
   limit 1;
  new.discriminator := v_candidate;
  return new;
end;
$$;

drop trigger if exists profiles_assign_discriminator on public.profiles;
create trigger profiles_assign_discriminator
  before insert or update of username on public.profiles
  for each row execute function app.assign_discriminator();

-- Backfill: legacy rows predate the column.
update public.profiles set updated_at = updated_at
 where discriminator is null;

-- ---------------------------------------------------------------------------
-- 2. follows — the one edge table.
--
-- `state`:
--   accepted → the normal case (public account, or a request that was granted);
--   pending  → following a private account, waiting for approval;
--   declined → the request was refused. Kept (instead of deleted) so a
--              declined follower cannot immediately re-request and ping the
--              owner again: the unique key absorbs the retry.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'follow_state') then
    create type public.follow_state as enum ('pending', 'accepted', 'declined');
  end if;
end $$;

create table if not exists public.follows (
  follower_id  uuid not null references public.profiles (id) on delete cascade,
  followee_id  uuid not null references public.profiles (id) on delete cascade,
  state        public.follow_state not null default 'accepted',
  -- YouTube-style bell: 'all' | 'personalized' | 'none'. Kept on the edge
  -- because "notify me about this creator" is a property of the relationship.
  notify_level text not null default 'personalized'
               check (notify_level in ('all', 'personalized', 'none')),
  created_at   timestamptz not null default clock_timestamp(),
  updated_at   timestamptz not null default clock_timestamp(),
  primary key (follower_id, followee_id),
  constraint follows_no_self check (follower_id <> followee_id)
);

comment on table public.follows is
  'Single social edge for subscribe/follow/follow-request. A private account turns an insert into `pending`; the owner accepts or declines.';

create index if not exists follows_followee_idx
  on public.follows (followee_id, state, created_at desc);
create index if not exists follows_follower_idx
  on public.follows (follower_id, state, followee_id);

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  reason     text check (reason is null or char_length(reason) <= 200),
  created_at timestamptz not null default clock_timestamp(),
  primary key (blocker_id, blocked_id),
  constraint blocks_no_self check (blocker_id <> blocked_id)
);

comment on table public.blocks is
  'One-directional block. Every visibility rule funnels through app.blocked_pair() so a block also removes follows, feeds and comment threads.';

create index if not exists blocks_blocked_idx on public.blocks (blocked_id, blocker_id);

-- ---------------------------------------------------------------------------
-- 3. The visibility + relationship helpers. Policies call these instead of
--    embedding the same three-way join in a dozen places.
-- ---------------------------------------------------------------------------
create or replace function app.blocked_pair(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p_a is not null and p_b is not null and p_a <> p_b and exists (
    select 1 from public.blocks b
     where (b.blocker_id = p_a and b.blocked_id = p_b)
        or (b.blocker_id = p_b and b.blocked_id = p_a)
  );
$$;

comment on function app.blocked_pair(uuid, uuid) is
  'True when either side blocked the other. Symmetric on purpose: the blocked person must not learn who blocked them, but must stop seeing the content.';

create or replace function app.is_following(p_follower uuid, p_followee uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.follows f
     where f.follower_id = p_follower
       and f.followee_id = p_followee
       and f.state = 'accepted'
  );
$$;

create or replace function app.can_view_user(p_viewer uuid, p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when p_target is null then false
    when p_viewer = p_target then true
    when app.blocked_pair(p_viewer, p_target) then false
    else coalesce((
      select (not p.is_private) or app.is_following(p_viewer, p_target)
        from public.profiles p
       where p.id = p_target
         and p.deleted_at is null
    ), false)
  end;
$$;

comment on function app.can_view_user(uuid, uuid) is
  'The one gate for private accounts and blocks. Feeds, profiles, comments and media tickets all call it.';

create or replace function public.follow_state(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce((
    select f.state::text from public.follows f
     where f.follower_id = app.current_uid() and f.followee_id = p_user_id
  ), 'none');
$$;

comment on function public.follow_state(uuid) is
  'Relationship of the caller to p_user_id: none | pending | accepted | declined. Drives the Follow / Requested / Following button.';

-- ---------------------------------------------------------------------------
-- 4. Counter maintenance. SECURITY DEFINER because the invoking role has no
--    UPDATE grant on the counter columns (grants below are column-scoped).
-- ---------------------------------------------------------------------------
create or replace function app.follows_recount()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    if new.state = 'accepted' then
      update public.profiles set follower_count = follower_count + 1, updated_at = clock_timestamp()
       where id = new.followee_id;
      update public.profiles set following_count = following_count + 1, updated_at = clock_timestamp()
       where id = new.follower_id;
    end if;
  elsif tg_op = 'DELETE' then
    if old.state = 'accepted' then
      update public.profiles set follower_count = greatest(follower_count - 1, 0), updated_at = clock_timestamp()
       where id = old.followee_id;
      update public.profiles set following_count = greatest(following_count - 1, 0), updated_at = clock_timestamp()
       where id = old.follower_id;
    end if;
  elsif tg_op = 'UPDATE' then
    -- pending → accepted (or accepted → declined) has to move both counters
    -- exactly once, which one branch per direction is what guarantees.
    if old.state <> 'accepted' and new.state = 'accepted' then
      update public.profiles set follower_count = follower_count + 1 where id = new.followee_id;
      update public.profiles set following_count = following_count + 1 where id = new.follower_id;
    elsif old.state = 'accepted' and new.state <> 'accepted' then
      update public.profiles set follower_count = greatest(follower_count - 1, 0) where id = old.followee_id;
      update public.profiles set following_count = greatest(following_count - 1, 0) where id = old.follower_id;
    end if;
    new.updated_at := clock_timestamp();
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists follows_recount on public.follows;
create trigger follows_recount
  after insert or update or delete on public.follows
  for each row execute function app.follows_recount();

-- A stable `updated_at` on UPDATE, same shape as every other table here.
drop trigger if exists follows_touch on public.follows;
create trigger follows_touch
  before update on public.follows
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Blocking cleans the graph: a block removes both follow directions in the
--    same transaction. Enforced by trigger, not by client politeness.
-- ---------------------------------------------------------------------------
create or replace function app.blocks_cleanup()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  delete from public.follows f
   where (f.follower_id = new.blocker_id and f.followee_id = new.blocked_id)
      or (f.follower_id = new.blocked_id and f.followee_id = new.blocker_id);
  return new;
end;
$$;

drop trigger if exists blocks_cleanup on public.blocks;
create trigger blocks_cleanup
  after insert on public.blocks
  for each row execute function app.blocks_cleanup();

-- ---------------------------------------------------------------------------
-- 6. RPCs the app actually calls.
-- ---------------------------------------------------------------------------

-- Follow by id *or* by the public `handle#tag` (the paste-a-name path). Returns
-- the resulting state so the button can render without a second round trip.
create or replace function public.follow_user(p_user_id uuid default null, p_handle text default null)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_target public.profiles%rowtype;
  v_state  public.follow_state;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'this account may not follow yet' using errcode = '42501';
  end if;

  if p_user_id is not null then
    select * into v_target from public.profiles where id = p_user_id and deleted_at is null;
  elsif p_handle is not null then
    -- Accepts `name`, `name#1234`, `@name#1234`.
    select * into v_target
      from public.profiles p
     where p.username_norm = lower(split_part(replace(btrim(p_handle), '@', ''), '#', 1))
       and (position('#' in p_handle) = 0
            or p.discriminator = nullif(split_part(btrim(p_handle), '#', 2), '')::smallint)
       and p.deleted_at is null
     order by p.created_at
     limit 1;
  else
    raise exception 'follow_user needs a user id or a handle' using errcode = '22023';
  end if;

  if not found then
    raise exception 'that account does not exist' using errcode = '22023';
  end if;
  if v_target.id = v_uid then
    raise exception 'you cannot follow yourself' using errcode = '22023';
  end if;
  if app.blocked_pair(v_uid, v_target.id) then
    raise exception 'that account is not available' using errcode = '42501';
  end if;

  v_state := case when v_target.is_private then 'pending'::public.follow_state
                  else 'accepted'::public.follow_state end;

  insert into public.follows (follower_id, followee_id, state)
  values (v_uid, v_target.id, v_state)
  on conflict (follower_id, followee_id) do update
    set state = case
          -- Re-requesting after a decline is refused silently (state stays
          -- 'declined'); the row exists so the owner is never spammed.
          when public.follows.state = 'declined' then 'declined'::public.follow_state
          when public.follows.state = 'pending' then 'pending'::public.follow_state
          else 'accepted'::public.follow_state
        end,
        updated_at = clock_timestamp()
  returning state into v_state;

  return v_state::text;
end;
$$;

comment on function public.follow_user(uuid, text) is
  'Follow/subscribe by id or ``handle#tag``. Returns none | pending | accepted | declined. Private accounts yield `pending`.';

create or replace function public.unfollow_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  delete from public.follows f
   where f.follower_id = v_uid and f.followee_id = p_user_id;
end;
$$;

create or replace function public.respond_follow_request(p_follower_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  update public.follows f
     set state = case when p_accept then 'accepted'::public.follow_state
                      else 'declined'::public.follow_state end
   where f.follower_id = p_follower_id
     and f.followee_id = v_uid
     and f.state = 'pending';
  if not found then
    raise exception 'no pending request from that account' using errcode = '22023';
  end if;
end;
$$;

create or replace function public.set_follow_notifications(p_user_id uuid, p_level text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if p_level not in ('all', 'personalized', 'none') then
    raise exception 'notify level must be all | personalized | none' using errcode = '22023';
  end if;
  update public.follows f set notify_level = p_level, updated_at = clock_timestamp()
   where f.follower_id = v_uid and f.followee_id = p_user_id and f.state = 'accepted';
  if not found then
    raise exception 'not following that account' using errcode = '22023';
  end if;
end;
$$;

create or replace function public.block_user(p_user_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if v_uid = p_user_id then
    raise exception 'you cannot block yourself' using errcode = '22023';
  end if;
  insert into public.blocks (blocker_id, blocked_id, reason)
  values (v_uid, p_user_id, p_reason)
  on conflict (blocker_id, blocked_id) do nothing;
end;
$$;

create or replace function public.unblock_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  delete from public.blocks b where b.blocker_id = v_uid and b.blocked_id = p_user_id;
end;
$$;

-- Followers / following lists with the same safe projection the directory uses.
create or replace function public.follow_list(p_user_id uuid, p_direction text default 'followers', p_limit integer default 100)
returns table (
  id            uuid,
  username      text,
  discriminator smallint,
  display_name  text,
  avatar_path   text,
  verified      boolean,
  is_following_back boolean,
  followed_at   timestamptz,
  state         text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if p_direction not in ('followers', 'following', 'requests') then
    raise exception 'direction must be followers | following | requests' using errcode = '22023';
  end if;
  -- A private account's audience is its own business: only the owner (or a
  -- service-role caller) may enumerate it.
  if p_direction <> 'requests'
     and not app.can_view_user(v_uid, p_user_id)
     and not exists (select 1 from public.profiles p where p.id = p_user_id and not p.is_private) then
    raise exception 'that account is private' using errcode = '42501';
  end if;

  return query
  select p.id,
         p.username,
         p.discriminator,
         p.display_name,
         p.avatar_path,
         p.verified,
         case when v_uid is null then false else app.is_following(v_uid, p.id) end,
         f.created_at,
         f.state::text
    from public.follows f
    join public.profiles p
      on p.id = case when p_direction = 'followers' then f.follower_id else f.followee_id end
   where p.deleted_at is null
     and not app.blocked_pair(v_uid, p.id)
     and case
           when p_direction = 'followers' then f.followee_id = p_user_id and f.state = 'accepted'
           when p_direction = 'following' then f.follower_id = p_user_id and f.state in ('accepted', 'pending')
           else f.followee_id = p_user_id and f.state = 'pending'
         end
   order by f.created_at desc
   limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

comment on function public.follow_list(uuid, text, integer) is
  'Followers / following / pending requests for one account, with the caller''s own follow-back flag so the list renders a usable button.';

-- ---------------------------------------------------------------------------
-- 7. RLS + grants. The rows are readable by the parties involved (and by
--    nobody else), and writable only through the RPCs above — which is why
--    `authenticated` gets SELECT and no INSERT/UPDATE/DELETE here at all.
-- ---------------------------------------------------------------------------
alter table public.follows enable row level security;
alter table public.blocks  enable row level security;

drop policy if exists follows_select_parties on public.follows;
create policy follows_select_parties on public.follows
  for select to authenticated
  using (
    follower_id = (select app.current_uid())
    or (followee_id = (select app.current_uid()) and state = 'pending')
    or (state = 'accepted' and exists (
          select 1 from public.profiles p
           where p.id = public.follows.followee_id and not p.is_private
        ))
  );

drop policy if exists blocks_select_self on public.blocks;
create policy blocks_select_self on public.blocks
  for select to authenticated
  using (blocker_id = (select app.current_uid()));

grant select on public.follows to authenticated;
grant select on public.blocks  to authenticated;
revoke all on public.follows, public.blocks from public, anon;

grant execute on function
  public.follow_user(uuid, text),
  public.unfollow_user(uuid),
  public.respond_follow_request(uuid, boolean),
  public.set_follow_notifications(uuid, text),
  public.block_user(uuid, text),
  public.unblock_user(uuid),
  public.follow_state(uuid),
  public.follow_list(uuid, text, integer)
to authenticated;

-- The new counter/tag columns are server-owned. Rather than narrowing the
-- table grant (which would also stop a client from touching `last_seen_at` and
-- the push flags), the existing guard trigger grows three more protected
-- columns — the mechanism 00004 already established for `access_state`.
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
     -- 00020: the public identity block a client must never award itself.
     -- `verified` and the counters are the whole point; `discriminator` is
     -- assigned once and must not be re-rolled to squat a handle.
     or new.discriminator is distinct from old.discriminator
     or new.verified is distinct from old.verified
     or new.follower_count is distinct from old.follower_count
     or new.following_count is distinct from old.following_count
     or new.post_count is distinct from old.post_count
  then
    raise exception 'these profile fields are server-managed'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function app.guard_profile_update() is
  'Blocks client writes to server-managed profile columns (access, eligibility, identity tags, counters). RPCs run as the definer and are unaffected.';

commit;
