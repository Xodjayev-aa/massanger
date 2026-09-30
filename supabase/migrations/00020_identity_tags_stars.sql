-- =============================================================================
-- 00020_identity_tags_stars.sql
-- MessengerX Super-App — identity (username#discriminator), profile tags,
-- the Telegram-Stars-style ledger, Stripe-backed payments, the $0 feature
-- switches and the notification inbox.
--
-- Design rules this file follows:
--   * every balance is derived from an append-only ledger (`star_ledger`) and a
--     cached column that only `app.stars_apply()` writes — no client, no edge
--     function and no trigger updates `profiles.star_balance` directly;
--   * "free by default": `payments.mode = 'beta_free'` plus a daily star grant
--     means tags, tips and badges work on a $0 deployment before a single
--     Stripe key exists. Turning payments on is a settings change, not a code
--     change;
--   * nothing secret is ever stored in `platform_settings` (prices, quotas and
--     feature flags only — keys live in the function environment);
--   * handles are `name#1234`: usernames may repeat, the pair is unique, and
--     changing either is server-side only (30-day rate limit).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Small helpers used by the guards below.
--
-- `app.privileged` is a transaction-local marker a SECURITY DEFINER RPC sets
-- before it writes a column a client must never write directly (the handle, the
-- discriminator). A client cannot set it: PostgREST exposes only functions, and
-- no function sets it without an explicit authorisation check first.
-- ---------------------------------------------------------------------------
create or replace function app.mark_privileged()
returns void
language sql
volatile
set search_path = pg_catalog, public
as $$
  select set_config('app.privileged', 'on', true);
$$;

/*
 * "Did the *caller* present a service-role key?"
 *
 * Claim-only on purpose. `app.is_service_role()` and `app.is_request_service()`
 * also look at `current_user`, which is the *table owner* inside every SECURITY
 * DEFINER function — so either of them is silently true in exactly the place an
 * authorship check needs to be strict (00021's comment_delete/comment_pin were
 * written that way first and a third party could delete and pin other people's
 * comments). A client cannot forge this claim: PostgREST sets it from the
 * verified token.
 */
create or replace function app.is_service_call()
returns boolean
language sql
stable
set search_path = pg_catalog, public
as $$
  select coalesce(
           app.jwt_claim('role'),
           nullif(current_setting('request.jwt.claim.role', true), ''),
           ''
         ) in ('service_role', 'supabase_admin');
$$;

create or replace function app.is_privileged()
returns boolean
language sql
stable
set search_path = pg_catalog, public
as $$
  select coalesce(current_setting('app.privileged', true), '') = 'on';
$$;

-- ---------------------------------------------------------------------------
-- 1. platform_settings — the operator's switches, readable by the client when
-- they are marked public (the app needs the star price and the daily quota to
-- render them; it never needs a secret).
-- ---------------------------------------------------------------------------
create table if not exists public.platform_settings (
  key        text primary key check (char_length(key) between 3 and 64),
  value      jsonb not null,
  is_public  boolean not null default false,
  note       text,
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.platform_settings is
  'Operator switches and tunables (prices, quotas, feature flags). Never a secret: keys stay in the edge-function environment.';

insert into public.platform_settings (key, value, is_public, note) values
  ('app.name',                 '"MessengerX"',            true,  'Product name shown in the UI.'),
  ('app.tagline',              '"Watch. Share. Talk."',   true,  'One line under the logo on sign-in.'),
  ('payments.mode',            '"beta_free"',             true,  'beta_free | live. beta_free hands out daily stars so every feature is testable for $0.'),
  ('payments.stripe_enabled',  'false',                   true,  'true once STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET are set.'),
  ('stars.price_cents',        '249',                     true,  'Stripe price for one star pack, in cents (2.49 USD).'),
  ('stars.pack_size',          '100',                     true,  'Stars granted by one pack.'),
  ('stars.daily_grant',        '25',                      true,  'Free stars per account per 24 h (0 disables).'),
  ('stars.daily_tip_budget',   '500',                     true,  'Most stars one account may tip per 24 h.'),
  ('stars.tag_create_cost',    '40',                      true,  'Stars burned to mint a custom tag.'),
  ('stars.tag_price_min',      '10',                      true,  'Cheapest marketplace tag.'),
  ('stars.tag_price_max',      '1000',                    true,  'Most expensive marketplace tag.'),
  ('stars.creator_share_pct',  '50',                      true,  'Percent of a tag sale the tag creator earns.'),
  ('tags.slots_free',          '1',                       true,  'Tag slots on the free tier.'),
  ('tags.slots_plus',          '3',                       true,  'Tag slots once 100 stars have been purchased.'),
  ('tags.slots_elite',         '5',                       true,  'Tag slots once 500 stars have been purchased.'),
  ('tiers.plus_stars',         '100',                     true,  'Lifetime purchased stars for the Plus tier.'),
  ('tiers.elite_stars',        '500',                     true,  'Lifetime purchased stars for the Elite tier.'),
  ('realtime.presence_window', '5',                       true,  'Minutes after `last_seen_at` a user still counts as online.'),
  ('bots.max_per_user',        '5',                       true,  'Bots one account may own.'),
  ('bots.events_per_minute',   '60',                      true,  'Runtime budget per bot, enforced by the runtime.'),
  ('ai_voice.daily_chars',     '4000',                    true,  'Free on-device voice-over characters per day.'),
  ('search.min_chars',         '2',                       true,  'Shortest query the search bar will run.')
on conflict (key) do nothing;

-- Reads for policies and RPCs. `stable` so Postgres can inline it in a query.
create or replace function app.setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select s.value from public.platform_settings s where s.key = p_key;
$$;

create or replace function app.setting_int(p_key text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when app.setting(p_key) is null then p_default
    when jsonb_typeof(app.setting(p_key)) = 'number' then (app.setting(p_key))::text::integer
    when jsonb_typeof(app.setting(p_key)) = 'string' then nullif(app.setting(p_key) #>> '{}', '')::integer
    else p_default
  end;
$$;

create or replace function app.setting_bool(p_key text, p_default boolean)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when app.setting(p_key) is null then p_default
    when jsonb_typeof(app.setting(p_key)) = 'boolean' then (app.setting(p_key))::text::boolean
    when jsonb_typeof(app.setting(p_key)) = 'string' then nullif(app.setting(p_key) #>> '{}', '')::boolean
    else p_default
  end;
$$;

-- The client's view of the switches: public keys only.
create or replace function public.platform_config()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb)
  from public.platform_settings s
  where s.is_public;
$$;

comment on function public.platform_config() is
  'Public feature switches and prices (never secrets). The app renders the star price, tier thresholds and quotas from this one call.';

-- ---------------------------------------------------------------------------
-- 2. Tags — Discord-style badges. `tags` is the catalogue (everyone may read
-- it), `user_tags` is ownership, `profiles.tag_id` is the badge currently worn.
-- ---------------------------------------------------------------------------
create table if not exists public.tags (
  id          uuid primary key default app.uuid_v7(),
  slug        text not null unique check (slug ~ '^[a-z0-9_]{2,12}$'),
  label       text not null check (char_length(label) between 1 and 14),
  emoji       text check (emoji is null or char_length(emoji) <= 8),
  color       text not null default '#3B82F6' check (color ~ '^#[0-9a-fA-F]{6}$'),
  price_stars integer not null default 0 check (price_stars between 0 and 5000),
  min_tier    text not null default 'free' check (min_tier in ('free', 'plus', 'elite')),
  is_public   boolean not null default true,
  is_official boolean not null default false,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default clock_timestamp()
);

comment on table public.tags is
  'Profile tag catalogue. A tag is one short word rendered as [LABEL] next to a handle everywhere the app draws a name.';

create table if not exists public.user_tags (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  tag_id     uuid not null references public.tags (id) on delete cascade,
  source     text not null default 'purchase' check (source in ('purchase', 'grant', 'creator', 'stripe')),
  price_paid integer not null default 0 check (price_paid >= 0),
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id, tag_id)
);

comment on table public.user_tags is
  'Tag ownership. `profiles.tag_id` may only be set to a tag the user owns — enforced by app.guard_profile_update(), not by the client.';

create index if not exists user_tags_tag_idx on public.user_tags (tag_id);

-- ---------------------------------------------------------------------------
-- 3. profiles — the handle pair, the badge, the star cache and the lifecycle
-- marks the new UI needs (onboarding).
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists discriminator     text not null default '0000',
  add column if not exists account_kind      text not null default 'user',
  add column if not exists tag_id            uuid references public.tags (id) on delete set null,
  add column if not exists star_balance      integer not null default 0,
  add column if not exists lifetime_stars    integer not null default 0,
  add column if not exists notify_prefs      jsonb not null default '{}'::jsonb,
  add column if not exists onboarded_at      timestamptz,
  add column if not exists handle_changed_at timestamptz;

alter table public.profiles drop constraint if exists profiles_discriminator_shape;
alter table public.profiles add constraint profiles_discriminator_shape
  check (discriminator ~ '^[0-9]{4}$');

alter table public.profiles drop constraint if exists profiles_account_kind_shape;
alter table public.profiles add constraint profiles_account_kind_shape
  check (account_kind in ('user', 'bot'));

alter table public.profiles drop constraint if exists profiles_stars_nonneg;
alter table public.profiles add constraint profiles_stars_nonneg
  check (star_balance >= 0 and lifetime_stars >= 0);

alter table public.profiles drop constraint if exists profiles_notify_prefs_shape;
alter table public.profiles add constraint profiles_notify_prefs_shape
  check (jsonb_typeof(notify_prefs) = 'object');

create unique index if not exists profiles_handle_uidx
  on public.profiles (username_norm, discriminator)
  where deleted_at is null;

-- Backfill for accounts that existed before this migration: deterministic,
-- collision-free numbering in creation order, so a re-run is a no-op and the
-- 00019-era fixtures keep working.
do $$
declare
  v_pending integer;
begin
  select count(*) into v_pending from public.profiles where discriminator = '0000';
  if v_pending = 0 then
    return;
  end if;
  with numbered as (
    select id, row_number() over (order by created_at, id) as rn
    from public.profiles
  )
  update public.profiles p
     set discriminator = lpad(((n.rn - 1) % 10000)::text, 4, '0')
    from numbered n
   where n.id = p.id
     and p.discriminator = '0000';
end
$$;

-- The next free four-digit suffix for a username. Volatile on purpose: two
-- accounts created in the same transaction must not be handed the same number.
create or replace function app.next_discriminator(p_username_norm text)
returns text
language plpgsql
volatile
set search_path = pg_catalog, public
as $$
declare
  v_start     integer := floor(random() * 10000)::int;
  v_candidate text;
  i           integer;
begin
  for i in 0..9999 loop
    v_candidate := lpad(((v_start + i) % 10000)::text, 4, '0');
    if not exists (
      select 1
      from public.profiles p
      where p.username_norm = lower(p_username_norm)
        and p.discriminator = v_candidate
        and p.deleted_at is null
    ) then
      return v_candidate;
    end if;
  end loop;
  raise exception 'no discriminator available for %', p_username_norm using errcode = '23505';
end;
$$;

-- Handle assignment on sign-up. This is the 00015 definition (username
-- uniqueness kept, `google_email` only ever set for a real Google provider,
-- access always active since 00013 retired the unprovable age gate) plus the
-- `#discriminator` the new UI renders next to every name.
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_base     text;
  v_username text;
begin
  v_base := left(
    app.username_from_text(coalesce(
      new.raw_user_meta_data ->> 'preferred_username',
      new.raw_user_meta_data ->> 'user_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      split_part(coalesce(new.email, ''), '@', 1),
      regexp_replace(coalesce(new.phone, ''), '[^0-9]', '', 'g')
    )), 24
  );
  if char_length(v_base) < 3 then
    v_base := 'user' || substr(md5(new.id::text), 1, 6);
  end if;

  v_username := v_base;
  -- Usernames stay globally unique: `@handle` has to identify exactly one
  -- account for mentions, search and share links to be trustworthy. The
  -- discriminator is the Discord-style *display* half of the identity.
  while exists (select 1 from public.profiles p where p.username_norm = lower(v_username)) loop
    v_username := left(v_base, 24) || '_' || substr(md5(clock_timestamp()::text || random()::text), 1, 5);
  end loop;

  insert into public.profiles (
    id, username, discriminator, display_name, phone_e164, google_email, access_state
  ) values (
    new.id,
    v_username,
    app.next_discriminator(lower(v_username)),
    left(coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'preferred_username',
      v_base
    ), 64),
    nullif(new.phone, ''),
    case when new.raw_app_meta_data ->> 'provider' = 'google' then nullif(new.email, '') else null end,
    'active'
  );

  insert into public.telegram_accounts (user_id, auth_state)
  values (new.id, 'unlinked') on conflict (user_id) do nothing;
  return new;
end;
$$;

-- Column guard: server-managed fields stay server-managed. The 00004 list is
-- kept verbatim; the new columns are appended with the same intent, except the
-- two a user legitimately owns (display_name, bio, avatar, notify_prefs,
-- onboarded_at) and `tag_id`, which is writable only for a tag the user owns.
create or replace function app.guard_profile_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  v_privileged boolean := app.is_privileged() or app.is_service_role();
begin
  if v_privileged then
    return new;
  end if;

  if new.id is distinct from old.id
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
     -- new in 00020
     or new.star_balance is distinct from old.star_balance
     or new.lifetime_stars is distinct from old.lifetime_stars
     or new.account_kind is distinct from old.account_kind
     or new.handle_changed_at is distinct from old.handle_changed_at
     or new.discriminator is distinct from old.discriminator
     or new.username is distinct from old.username
  then
    raise exception 'these profile fields are server-managed'
      using errcode = '42501';
  end if;

  if new.tag_id is distinct from old.tag_id and new.tag_id is not null
     and not exists (
       select 1 from public.user_tags ut
       where ut.user_id = old.id and ut.tag_id = new.tag_id
     )
  then
    raise exception 'that tag is not in your collection'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

-- Renaming yourself: bounded, reserved names refused, discriminator re-rolled.
create or replace function public.set_username(p_username text)
returns table (username text, discriminator text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid       uuid := app.current_uid();
  v_clean     text := lower(btrim(coalesce(p_username, '')));
  v_disc      text;
  v_last      timestamptz;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if v_clean !~ '^[a-z0-9_.]{3,32}$' then
    raise exception 'Usernames are 3-32 characters: letters, digits, dot and underscore.'
      using errcode = '22023';
  end if;

  if not app.access_ok(v_uid) then
    raise exception 'This account cannot change its username right now.'
      using errcode = '42501';
  end if;

  select p.handle_changed_at into v_last from public.profiles p where p.id = v_uid;
  if v_last is not null and v_last > clock_timestamp() - interval '30 days' then
    raise exception 'A username can only change once every 30 days.'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.username_norm = v_clean and p.id <> v_uid and p.deleted_at is null
  ) then
    raise exception 'That username is taken.' using errcode = '22023';
  end if;

  if v_clean in ('admin', 'administrator', 'support', 'messengerx', 'system', 'root',
                 'moderator', 'official', 'staff', 'help', 'api', 'www')
     and not exists (select 1 from public.profiles p where p.id = v_uid and p.account_kind = 'bot')
  then
    raise exception 'That username is reserved.' using errcode = '22023';
  end if;

  perform app.mark_privileged();
  v_disc := app.next_discriminator(v_clean);

  update public.profiles p
     set username = v_clean,
         discriminator = v_disc,
         handle_changed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   where p.id = v_uid;

  return query select v_clean, v_disc;
end;
$$;

comment on function public.set_username(text) is
  'Renames the caller and re-rolls the #discriminator. Rate-limited to once every 30 days.';

-- ---------------------------------------------------------------------------
-- 4. The public directory, now with the handle pair and the active badge.
--
-- Column order matters for `create or replace view`: the 00005 columns stay
-- exactly where they were, everything new is appended.
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
       (p.last_seen_at > clock_timestamp() - (app.setting_int('realtime.presence_window', 5) || ' minutes')::interval) as is_online,
       p.last_seen_at,
       p.discriminator,
       p.account_kind,
       p.tag_id,
       t.slug  as tag_slug,
       t.label as tag_label,
       t.color as tag_color,
       t.emoji as tag_emoji,
       (p.tag_id is not null) as has_tag
from public.profiles p
left join public.tags t on t.id = p.tag_id
where p.deleted_at is null;

comment on view public.directory is
  'Safe public projection of profiles: handle pair, active badge, presence. No email, phone or eligibility data.';

-- ---------------------------------------------------------------------------
-- 5. Stars. One writer, one ledger, one cache.
-- ---------------------------------------------------------------------------
create table if not exists public.star_ledger (
  id              uuid primary key default app.uuid_v7(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  delta           integer not null check (delta <> 0),
  reason          text not null check (reason in (
                    'purchase', 'daily_grant', 'bonus', 'tip_out', 'tip_in',
                    'tag_create', 'tag_buy', 'tag_sale', 'refund', 'bot_reward')),
  ref_type        text check (ref_type is null or ref_type in (
                    'payment', 'tag', 'video', 'short', 'comment', 'user', 'bot', 'system')),
  ref_id          uuid,
  metadata        jsonb,
  balance_after   integer not null check (balance_after >= 0),
  idempotency_key text,
  created_at      timestamptz not null default clock_timestamp()
);

comment on table public.star_ledger is
  'Append-only star movements. profiles.star_balance is a cache of sum(delta) and is written only by app.stars_apply().';

create unique index if not exists star_ledger_idem_uidx
  on public.star_ledger (user_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists star_ledger_user_idx
  on public.star_ledger (user_id, created_at desc);

create index if not exists star_ledger_reason_idx
  on public.star_ledger (user_id, reason, created_at desc);

-- The only writer. Locks the profile row first (so two concurrent calls cannot
-- interleave), then honours the idempotency key, then appends and caches.
create or replace function app.stars_apply(
  p_user_id         uuid,
  p_delta           integer,
  p_reason          text,
  p_ref_type        text default null,
  p_ref_id          uuid default null,
  p_metadata        jsonb default null,
  p_idempotency_key text default null
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_balance integer;
  v_seen    integer;
begin
  if p_delta = 0 then
    raise exception 'a star movement must change the balance' using errcode = '22023';
  end if;

  select p.star_balance into v_balance
  from public.profiles p
  where p.id = p_user_id
  for update;

  if v_balance is null then
    raise exception 'unknown account %', p_user_id using errcode = '23503';
  end if;

  if p_idempotency_key is not null then
    select l.balance_after into v_seen
    from public.star_ledger l
    where l.user_id = p_user_id and l.idempotency_key = p_idempotency_key;
    if found then
      return v_seen;
    end if;
  end if;

  if v_balance + p_delta < 0 then
    raise exception 'Not enough stars: you have % and this needs %.', v_balance, -p_delta
      using errcode = '22023';
  end if;

  v_balance := v_balance + p_delta;

  insert into public.star_ledger (
    user_id, delta, reason, ref_type, ref_id, metadata, balance_after, idempotency_key
  ) values (
    p_user_id, p_delta, p_reason, p_ref_type, p_ref_id, p_metadata, v_balance, p_idempotency_key
  );

  update public.profiles p
     set star_balance = v_balance,
         -- Tier progress counts stars that were *bought* (or granted as a
         -- bonus), never stars that were earned by selling content: selling is
         -- income, not support.
         lifetime_stars = p.lifetime_stars
           + case when p_delta > 0 and p_reason in ('purchase', 'bonus') then p_delta else 0 end,
         updated_at = clock_timestamp()
   where p.id = p_user_id;

  return v_balance;
end;
$$;

comment on function app.stars_apply(uuid, integer, text, text, uuid, jsonb, text) is
  'The single writer of the star balance: locks the account, honours idempotency, appends the ledger row and moves the cache.';

create or replace function app.star_tier(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case
    when coalesce(p.lifetime_stars, 0) >= app.setting_int('tiers.elite_stars', 500) then 'elite'
    when coalesce(p.lifetime_stars, 0) >= app.setting_int('tiers.plus_stars', 100) then 'plus'
    else 'free'
  end
  from public.profiles p
  where p.id = p_user_id;
$$;

create or replace function app.tag_slots(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select case app.star_tier(p_user_id)
    when 'elite' then app.setting_int('tags.slots_elite', 5)
    when 'plus'  then app.setting_int('tags.slots_plus', 3)
    else app.setting_int('tags.slots_free', 1)
  end;
$$;

-- One call for the whole star header in the UI.
create or replace function public.star_wallet()
returns table (
  balance        integer,
  lifetime_stars integer,
  tier           text,
  slots          integer,
  slots_used     integer,
  daily_grant    integer,
  can_claim      boolean,
  next_claim_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_last timestamptz;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select max(l.created_at) into v_last
  from public.star_ledger l
  where l.user_id = v_uid and l.reason = 'daily_grant';

  return query
  select p.star_balance,
         p.lifetime_stars,
         app.star_tier(v_uid),
         app.tag_slots(v_uid),
         (select count(*)::int from public.user_tags ut where ut.user_id = v_uid),
         app.setting_int('stars.daily_grant', 25),
         app.setting_int('stars.daily_grant', 25) > 0
           and (v_last is null or v_last < clock_timestamp() - interval '24 hours'),
         case when v_last is null then clock_timestamp() else v_last + interval '24 hours' end
  from public.profiles p
  where p.id = v_uid;
end;
$$;

create or replace function public.star_history(p_limit integer default 50)
returns table (
  id            uuid,
  delta         integer,
  reason        text,
  ref_type      text,
  ref_id        uuid,
  metadata      jsonb,
  balance_after integer,
  created_at    timestamptz
)
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  select l.id, l.delta, l.reason, l.ref_type, l.ref_id, l.metadata, l.balance_after, l.created_at
  from public.star_ledger l
  where l.user_id = app.current_uid()
  order by l.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

-- Free daily grant: the reason a $0 deployment still has a working economy.
create or replace function public.star_claim_daily()
returns table (granted integer, balance integer, next_claim_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_amount  integer := app.setting_int('stars.daily_grant', 25);
  v_last    timestamptz;
  v_balance integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if v_amount <= 0 then
    raise exception 'Daily stars are switched off on this deployment.' using errcode = '22023';
  end if;

  select max(l.created_at) into v_last
  from public.star_ledger l
  where l.user_id = v_uid and l.reason = 'daily_grant';

  if v_last is not null and v_last > clock_timestamp() - interval '24 hours' then
    raise exception 'Already claimed. Come back in % hours.',
      ceil(extract(epoch from (v_last + interval '24 hours' - clock_timestamp())) / 3600)
      using errcode = '22023';
  end if;

  v_balance := app.stars_apply(
    v_uid, v_amount, 'daily_grant', 'system', null,
    jsonb_build_object('source', 'daily'), null
  );

  return query select v_amount, v_balance, clock_timestamp() + interval '24 hours';
end;
$$;

-- Tips: free to give (bounded by a daily budget), immediately visible to the
-- receiver. The two ledger rows are one transaction: either both exist or
-- neither does.
create or replace function public.star_tip(
  p_to            uuid,
  p_content_kind  text,
  p_content_id    uuid,
  p_stars         integer,
  p_note          text default null
)
returns table (balance integer, sent integer, creator_total bigint)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_budget integer := app.setting_int('stars.daily_tip_budget', 500);
  v_spent  integer;
  v_balance integer;
  v_ok     boolean := false;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_to is null or p_to = v_uid then
    raise exception 'You cannot tip yourself.' using errcode = '22023';
  end if;

  if p_stars is null or p_stars < 1 or p_stars > 5000 then
    raise exception 'Tips are between 1 and 5000 stars.' using errcode = '22023';
  end if;

  select coalesce(sum(-l.delta), 0)::int into v_spent
  from public.star_ledger l
  where l.user_id = v_uid
    and l.reason = 'tip_out'
    and l.created_at > clock_timestamp() - interval '24 hours';

  if v_spent + p_stars > v_budget then
    raise exception 'Daily tip budget reached (% of % stars used).', v_spent, v_budget
      using errcode = '22023';
  end if;

  -- The content must exist and be visible to the giver; a tip is never a
  -- blind transfer to an arbitrary uuid.
  if p_content_kind = 'video' then
    select exists (
      select 1 from public.videos v
      where v.id = p_content_id and v.author_id = p_to and v.deleted_at is null
    ) into v_ok;
  elsif p_content_kind = 'short' then
    select exists (
      select 1 from public.shorts s where s.id = p_content_id and s.author_id = p_to
    ) into v_ok;
  elsif p_content_kind = 'comment' then
    select exists (
      select 1 from public.content_comments c where c.id = p_content_id and c.author_id = p_to
    ) into v_ok;
  elsif p_content_kind = 'user' then
    v_ok := exists (select 1 from public.profiles p where p.id = p_to and p.deleted_at is null);
    p_content_id := null;
  end if;

  if not coalesce(v_ok, false) then
    raise exception 'That content is not available for tipping.' using errcode = '22023';
  end if;

  v_balance := app.stars_apply(
    v_uid, -p_stars, 'tip_out', p_content_kind, p_content_id,
    jsonb_strip_nulls(jsonb_build_object('to', p_to, 'note', nullif(btrim(coalesce(p_note, '')), ''))),
    null
  );

  perform app.stars_apply(
    p_to, p_stars, 'tip_in', p_content_kind, p_content_id,
    jsonb_strip_nulls(jsonb_build_object('from', v_uid, 'note', nullif(btrim(coalesce(p_note, '')), ''))),
    null
  );

  perform app.notify(p_to, 'tip', v_uid, p_content_kind, p_content_id,
    'sent you ' || p_stars || ' stars');

  return query
  select v_balance,
         p_stars,
         (select coalesce(sum(l.delta), 0)::bigint
          from public.star_ledger l
          where l.user_id = p_to and l.reason in ('tip_in', 'tag_sale'));
end;
$$;

-- Tag flows -----------------------------------------------------------------
create or replace function public.tag_catalogue()
returns table (
  id           uuid,
  slug         text,
  label        text,
  emoji        text,
  color        text,
  price_stars  integer,
  min_tier     text,
  is_official  boolean,
  created_by   uuid,
  creator_name text,
  owned        boolean,
  equipped     boolean,
  affordable   boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select t.id,
         t.slug,
         t.label,
         t.emoji,
         t.color,
         t.price_stars,
         t.min_tier,
         t.is_official,
         t.created_by,
         coalesce(nullif(d.display_name, ''), d.username),
         (ut.user_id is not null),
         (p.tag_id = t.id),
         (coalesce(p.star_balance, 0) >= t.price_stars)
  from public.tags t
  left join public.directory d on d.id = t.created_by
  left join public.profiles p on p.id = app.current_uid()
  left join public.user_tags ut on ut.tag_id = t.id and ut.user_id = app.current_uid()
  where t.is_public or t.created_by = app.current_uid()
  order by t.is_official desc, t.price_stars asc, t.label asc;
$$;

create or replace function public.tag_create(
  p_slug  text,
  p_label text,
  p_color text default '#3B82F6',
  p_emoji text default null,
  p_price integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_cost integer := app.setting_int('stars.tag_create_cost', 40);
  v_slug text := lower(btrim(coalesce(p_slug, '')));
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not app.sender_may_post(v_uid) then
    raise exception 'This account cannot create tags right now.' using errcode = '42501';
  end if;

  if v_slug !~ '^[a-z0-9_]{2,12}$' then
    raise exception 'Tag handles are 2-12 characters: a-z, 0-9 and underscore.' using errcode = '22023';
  end if;

  if char_length(btrim(coalesce(p_label, ''))) not between 1 and 14 then
    raise exception 'Tag labels are 1-14 characters.' using errcode = '22023';
  end if;

  if coalesce(p_color, '') !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'Tag colours are hex, like #F59E0B.' using errcode = '22023';
  end if;

  if exists (select 1 from public.tags t where t.slug = v_slug) then
    raise exception 'That tag handle is taken.' using errcode = '22023';
  end if;

  if p_price is not null and (p_price < 0 or p_price > app.setting_int('stars.tag_price_max', 1000)) then
    raise exception 'A tag price must be between 0 and %.', app.setting_int('stars.tag_price_max', 1000)
      using errcode = '22023';
  end if;

  -- Burn the creation cost first: if the balance is short, nothing is created.
  if v_cost > 0 then
    perform app.stars_apply(v_uid, -v_cost, 'tag_create', 'tag', null,
      jsonb_build_object('slug', v_slug), null);
  end if;

  insert into public.tags (slug, label, emoji, color, price_stars, min_tier, is_public, created_by)
  values (
    v_slug,
    btrim(p_label),
    nullif(btrim(coalesce(p_emoji, '')), ''),
    upper(p_color),
    greatest(coalesce(p_price, 0), 0),
    'free',
    true,
    v_uid
  )
  returning id into v_id;

  insert into public.user_tags (user_id, tag_id, source, price_paid)
  values (v_uid, v_id, 'creator', v_cost)
  on conflict do nothing;

  return v_id;
end;
$$;

create or replace function public.tag_buy(p_tag_id uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid    uuid := app.current_uid();
  v_tag    public.tags%rowtype;
  v_share  integer := app.setting_int('stars.creator_share_pct', 50);
  v_balance integer;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_tag from public.tags t where t.id = p_tag_id;
  if not found then
    raise exception 'Unknown tag.' using errcode = '22023';
  end if;

  if not v_tag.is_public and v_tag.created_by is distinct from v_uid then
    raise exception 'That tag is private.' using errcode = '42501';
  end if;

  if exists (select 1 from public.user_tags ut where ut.user_id = v_uid and ut.tag_id = p_tag_id) then
    return 0;  -- already owned; buying twice is a no-op, not an error
  end if;

  if app.star_tier(v_uid) = 'free' and v_tag.min_tier <> 'free' then
    raise exception 'That tag needs the % tier.', v_tag.min_tier using errcode = '22023';
  end if;

  if v_tag.price_stars > 0 then
    v_balance := app.stars_apply(v_uid, -v_tag.price_stars, 'tag_buy', 'tag', v_tag.id,
      jsonb_build_object('slug', v_tag.slug), 'tag_buy:' || v_uid::text || ':' || v_tag.id::text);
  end if;

  insert into public.user_tags (user_id, tag_id, source, price_paid)
  values (v_uid, p_tag_id, 'purchase', v_tag.price_stars)
  on conflict do nothing;

  -- The tag's creator earns a cut — this is what makes the marketplace move.
  if v_tag.created_by is not null and v_tag.created_by <> v_uid and v_tag.price_stars > 0 and v_share > 0 then
    perform app.stars_apply(
      v_tag.created_by,
      greatest((v_tag.price_stars * v_share) / 100, 1),
      'tag_sale', 'tag', v_tag.id,
      jsonb_build_object('buyer', v_uid, 'price', v_tag.price_stars),
      'tag_sale:' || v_uid::text || ':' || v_tag.id::text
    );
    perform app.notify(v_tag.created_by, 'tag', v_uid, 'tag', v_tag.id,
      'bought your [' || upper(v_tag.label) || '] tag');
  end if;

  return v_tag.price_stars;
end;
$$;

create or replace function public.tag_equip(p_tag_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_tag_id is not null and not exists (
    select 1 from public.user_tags ut where ut.user_id = v_uid and ut.tag_id = p_tag_id
  ) then
    raise exception 'That tag is not in your collection.' using errcode = '42501';
  end if;

  perform app.mark_privileged();
  update public.profiles p
     set tag_id = p_tag_id, updated_at = clock_timestamp()
   where p.id = v_uid;
end;
$$;

create or replace function public.tag_mine()
returns table (
  tag_id      uuid,
  slug        text,
  label       text,
  emoji       text,
  color       text,
  source      text,
  price_paid  integer,
  acquired_at timestamptz,
  equipped    boolean,
  times_worn  bigint
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select t.id, t.slug, t.label, t.emoji, t.color, ut.source, ut.price_paid, ut.created_at,
         (p.tag_id = t.id),
         (select count(*) from public.star_ledger l
           where l.ref_type = 'tag' and l.ref_id = t.id and l.reason = 'tag_sale')
  from public.user_tags ut
  join public.tags t on t.id = ut.tag_id
  join public.profiles p on p.id = ut.user_id
  where ut.user_id = app.current_uid()
  order by ut.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- 6. Payments. A row is created by the checkout function (service role),
-- settled by the webhook (service role) and readable by its owner — nothing
-- else. `fulfill_payment` is idempotent, so a retried webhook cannot pay twice.
-- ---------------------------------------------------------------------------
create table if not exists public.payments (
  id                   uuid primary key default app.uuid_v7(),
  user_id              uuid not null references public.profiles (id) on delete cascade,
  provider             text not null default 'stripe' check (provider in ('stripe', 'stars', 'manual', 'promo')),
  kind                 text not null check (kind in ('stars', 'tag')),
  status               text not null default 'created' check (status in ('created', 'pending', 'paid', 'failed', 'refunded')),
  amount_cents         integer check (amount_cents is null or amount_cents between 0 and 10000000),
  currency             text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  stars                integer check (stars is null or stars between 0 and 1000000),
  tag_id               uuid references public.tags (id) on delete set null,
  provider_session_id  text unique,
  provider_payment_intent text,
  receipt_url          text,
  metadata             jsonb,
  created_at           timestamptz not null default clock_timestamp(),
  paid_at              timestamptz,
  updated_at           timestamptz not null default clock_timestamp(),
  constraint payments_shape check (
    (kind = 'stars' and stars is not null and tag_id is null)
    or (kind = 'tag' and tag_id is not null and coalesce(stars, 0) = 0)
  )
);

comment on table public.payments is
  'Payment intents. Written only by the stripe-checkout / stripe-webhook functions through the service role; a client may read its own rows and nothing else.';

create index if not exists payments_user_idx on public.payments (user_id, created_at desc);
create index if not exists payments_status_idx on public.payments (status) where status in ('created', 'pending');

create or replace function public.payment_attach_session(
  p_payment_id uuid,
  p_session_id text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not (app.is_service_call() or app.is_privileged()) then
    raise exception 'service role required' using errcode = '42501';
  end if;

  update public.payments
     set provider_session_id = p_session_id,
         status = 'pending',
         updated_at = clock_timestamp()
   where id = p_payment_id
     and status = 'created';
end;
$$;

create or replace function public.fulfill_payment(
  p_session_id     text,
  p_payment_intent text default null,
  p_receipt_url    text default null,
  p_metadata       jsonb default null
)
returns table (payment_id uuid, user_id uuid, kind text, stars integer, tag_id uuid, already_paid boolean)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_payment public.payments%rowtype;
begin
  if not (app.is_service_call() or app.is_privileged()) then
    raise exception 'service role required' using errcode = '42501';
  end if;

  select * into v_payment
  from public.payments
  where provider_session_id = p_session_id
  for update;

  if not found then
    raise exception 'unknown payment session %', p_session_id using errcode = '22023';
  end if;

  if v_payment.status = 'paid' then
    return query select v_payment.id, v_payment.user_id, v_payment.kind, v_payment.stars, v_payment.tag_id, true;
    return;
  end if;

  update public.payments
     set status = 'paid',
         paid_at = clock_timestamp(),
         updated_at = clock_timestamp(),
         provider_payment_intent = coalesce(p_payment_intent, provider_payment_intent),
         receipt_url = coalesce(p_receipt_url, receipt_url),
         metadata = coalesce(metadata, '{}'::jsonb) || coalesce(p_metadata, '{}'::jsonb)
   where id = v_payment.id;

  if v_payment.kind = 'stars' then
    perform app.stars_apply(
      v_payment.user_id,
      v_payment.stars,
      'purchase',
      'payment',
      v_payment.id,
      jsonb_build_object('provider', v_payment.provider, 'amount_cents', v_payment.amount_cents),
      'payment:' || v_payment.id::text
    );
  elsif v_payment.kind = 'tag' and v_payment.tag_id is not null then
    insert into public.user_tags (user_id, tag_id, source, price_paid)
    values (v_payment.user_id, v_payment.tag_id, 'stripe', 0)
    on conflict do nothing;

    perform app.mark_privileged();
    update public.profiles
       set tag_id = v_payment.tag_id, updated_at = clock_timestamp()
     where id = v_payment.user_id;
  end if;

  perform app.notify(v_payment.user_id, 'system', null, 'payment', v_payment.id,
    case when v_payment.kind = 'stars'
         then 'Star pack added: +' || v_payment.stars || ' stars'
         else 'Tag unlocked' end);

  return query select v_payment.id, v_payment.user_id, v_payment.kind, v_payment.stars, v_payment.tag_id, false;
end;
$$;

comment on function public.fulfill_payment(text, text, text, jsonb) is
  'Settles a payment once. Safe to call from a retried webhook: a paid row returns already_paid = true and no stars move twice.';

create or replace function public.payments_mine(p_limit integer default 25)
returns table (
  id          uuid,
  kind        text,
  status      text,
  amount_cents integer,
  currency    text,
  stars       integer,
  tag_id      uuid,
  created_at  timestamptz,
  paid_at     timestamptz
)
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  select p.id, p.kind, p.status, p.amount_cents, p.currency, p.stars, p.tag_id, p.created_at, p.paid_at
  from public.payments p
  where p.user_id = app.current_uid()
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit, 25), 1), 100);
$$;

-- ---------------------------------------------------------------------------
-- 7. Notifications — the inbox behind the Messages tab badge.
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id           uuid primary key default app.uuid_v7(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  kind         text not null check (kind in (
                 'follow', 'like', 'comment', 'reply', 'comment_like',
                 'tip', 'tag', 'mention', 'system', 'live', 'bot')),
  actor_id     uuid references public.profiles (id) on delete set null,
  subject_kind text check (subject_kind is null or subject_kind in (
                 'video', 'short', 'comment', 'user', 'chat', 'message', 'tag', 'payment', 'bot')),
  subject_id   uuid,
  body         text check (body is null or char_length(body) <= 400),
  is_read      boolean not null default false,
  created_at   timestamptz not null default clock_timestamp()
);

comment on table public.notifications is
  'Social inbox. Written by app.notify() from triggers and RPCs, read by the owner, published to supabase_realtime so the Messages badge moves without a poll.';

create index if not exists notifications_user_idx
  on public.notifications (user_id, created_at desc);

create index if not exists notifications_unread_idx
  on public.notifications (user_id) where is_read = false;

-- Central writer: never notifies the actor about their own action, and honours
-- the per-user social toggle.
create or replace function app.notify(
  p_user_id      uuid,
  p_kind         text,
  p_actor_id     uuid default null,
  p_subject_kind text default null,
  p_subject_id   uuid default null,
  p_body         text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_user_id is null then
    return;
  end if;

  if p_actor_id is not null and p_actor_id = p_user_id then
    return;
  end if;

  if not coalesce(
    (select (p.notify_prefs ->> 'social')::boolean from public.profiles p where p.id = p_user_id),
    true
  ) then
    return;
  end if;

  insert into public.notifications (user_id, kind, actor_id, subject_kind, subject_id, body)
  values (p_user_id, p_kind, p_actor_id, p_subject_kind, p_subject_id, left(p_body, 400));
end;
$$;

create or replace function public.notifications_list(
  p_before_id uuid default null,
  p_limit     integer default 30
)
returns table (
  id            uuid,
  kind          text,
  actor_id      uuid,
  actor_name    text,
  actor_username text,
  actor_discriminator text,
  actor_avatar_path text,
  actor_tag_label text,
  actor_tag_color text,
  subject_kind  text,
  subject_id    uuid,
  body          text,
  is_read       boolean,
  created_at    timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select n.id,
         n.kind,
         n.actor_id,
         coalesce(nullif(d.display_name, ''), d.username, 'MessengerX'),
         d.username,
         d.discriminator,
         d.avatar_path,
         d.tag_label,
         d.tag_color,
         n.subject_kind,
         n.subject_id,
         n.body,
         n.is_read,
         n.created_at
  from public.notifications n
  left join public.directory d on d.id = n.actor_id
  where n.user_id = app.current_uid()
    and (p_before_id is null or n.id < p_before_id)
  order by n.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

create or replace function public.notifications_unread()
returns integer
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select count(*)::int
  from public.notifications n
  where n.user_id = app.current_uid() and n.is_read = false;
$$;

create or replace function public.notifications_mark_read(p_ids uuid[] default null)
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
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.notifications n
     set is_read = true
   where n.user_id = v_uid
     and n.is_read = false
     and (p_ids is null or n.id = any (p_ids));

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Realtime: the notification badge and the star balance are the two things
-- that must move without a refresh.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      execute 'create publication supabase_realtime';
    exception when others then
      raise notice 'could not create supabase_realtime publication: %', sqlerrm;
      return;
    end;
  end if;

  foreach t in array array['public.notifications'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = split_part(t, '.', 1)
        and tablename = split_part(t, '.', 2)
    ) then
      begin
        execute format('alter publication supabase_realtime add table %s', t);
      exception when others then
        raise notice 'could not add % to supabase_realtime: %', t, sqlerrm;
      end;
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants and RLS.
-- ---------------------------------------------------------------------------
-- 00009's blanket grant only covered the tables that existed then; Supabase's
-- hosted default privileges do not exist on a bare Postgres (CI), so restate it.
grant all on public.platform_settings, public.tags, public.user_tags, public.star_ledger,
  public.payments, public.notifications to service_role;

grant select on public.tags, public.user_tags, public.star_ledger, public.payments, public.notifications
  to authenticated;
grant update, delete on public.notifications to authenticated;
grant select on public.platform_settings to authenticated;

revoke all on public.platform_settings from anon, authenticated;
grant select on public.platform_settings to authenticated;

alter table public.tags            enable row level security;
alter table public.user_tags       enable row level security;
alter table public.star_ledger     enable row level security;
alter table public.payments        enable row level security;
alter table public.notifications   enable row level security;
alter table public.platform_settings enable row level security;

-- Catalogue: readable by everyone, written only through the RPCs above.
drop policy if exists tags_select_public on public.tags;
create policy tags_select_public on public.tags
  for select to authenticated, anon
  using (is_public or created_by = (select app.current_uid()));

drop policy if exists user_tags_select_own on public.user_tags;
create policy user_tags_select_own on public.user_tags
  for select to authenticated
  using (user_id = (select app.current_uid()));

-- The ledger is a bank statement: owner-readable, nobody-writable.
drop policy if exists star_ledger_select_own on public.star_ledger;
create policy star_ledger_select_own on public.star_ledger
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists payments_select_own on public.payments;
create policy payments_select_own on public.payments
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select to authenticated
  using (user_id = (select app.current_uid()));

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update to authenticated
  using (user_id = (select app.current_uid()))
  with check (user_id = (select app.current_uid()));

drop policy if exists notifications_delete_own on public.notifications;
create policy notifications_delete_own on public.notifications
  for delete to authenticated
  using (user_id = (select app.current_uid()));

-- Platform settings: the flags are public on purpose; the table itself is not
-- writable by a client at all.
drop policy if exists platform_settings_select_public on public.platform_settings;
create policy platform_settings_select_public on public.platform_settings
  for select to authenticated
  using (is_public);

-- Function grants ------------------------------------------------------------
grant execute on function
  public.platform_config(),
  public.set_username(text),
  public.star_wallet(),
  public.star_history(integer),
  public.star_claim_daily(),
  public.star_tip(uuid, text, uuid, integer, text),
  public.tag_catalogue(),
  public.tag_create(text, text, text, text, integer),
  public.tag_buy(uuid),
  public.tag_equip(uuid),
  public.tag_mine(),
  public.payments_mine(integer),
  public.notifications_list(uuid, integer),
  public.notifications_unread(),
  public.notifications_mark_read(uuid[])
  to authenticated;

-- The star ledger's single writer, the notification writer and the internal
-- helpers are not a client API: `app.stars_apply` is SECURITY DEFINER and takes
-- a user id, so leaving it callable would let any signed-in client mint stars.
/*
 * `app.is_privileged()` and the settings readers are called from column guards
 * and views, which execute as the *invoking* role — they must stay callable.
 * The writers below are the opposite: `app.stars_apply` is SECURITY DEFINER and
 * takes a user id, so a client that could call it could mint itself stars.
 */
revoke all on function
  app.stars_apply(uuid, integer, text, text, uuid, jsonb, text),
  app.notify(uuid, text, uuid, text, uuid, text),
  app.mark_privileged(),
  app.next_discriminator(text),
  app.star_tier(uuid),
  app.tag_slots(uuid)
  from public, anon, authenticated;

grant execute on function
  app.stars_apply(uuid, integer, text, text, uuid, jsonb, text),
  app.notify(uuid, text, uuid, text, uuid, text),
  app.mark_privileged(),
  app.next_discriminator(text),
  app.star_tier(uuid),
  app.tag_slots(uuid),
  app.is_privileged(),
  app.is_service_call(),
  app.setting(text),
  app.setting_int(text, integer),
  app.setting_bool(text, boolean)
  to service_role;

-- Money settlement and session plumbing are for the functions, never a browser.
revoke all on function public.fulfill_payment(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.payment_attach_session(uuid, text) from public, anon, authenticated;
grant execute on function public.fulfill_payment(text, text, text, jsonb) to service_role;
grant execute on function public.payment_attach_session(uuid, text) to service_role;

-- The seed migration ships one official tag so a fresh install has something to
-- render next to a handle before any user mints one.
insert into public.tags (slug, label, emoji, color, price_stars, min_tier, is_public, is_official)
values
  ('early', 'EARLY', null, '#22C55E', 0, 'free', true, true),
  ('verified', 'VERIFIED', null, '#3B82F6', 0, 'free', true, true),
  ('founder', 'FOUNDER', null, '#F59E0B', 0, 'plus', true, true),
  ('grand', 'GRAND', null, '#A855F7', 0, 'elite', true, true)
on conflict (slug) do nothing;

commit;
