-- =============================================================================
-- 00025_stars_and_tags.sql
-- MessengerX 3.0 — the Stars wallet, the tag marketplace and Stripe checkout.
--
-- The monetisation model is deliberately small and auditable:
--
--   money in       Stripe Checkout ($2.49 for a custom tag credit, or a Stars
--                  pack) → `stripe-webhook` edge function → `payment_settle()`;
--   money sideways Stars move between people (tips, gifts, unlocks) and are
--                  *never* writable by a client — only by SECURITY DEFINER
--                  functions, and the ones that create value are executable by
--                  `service_role` alone;
--   money out      creator earnings accrue to the wallet; payouts are an
--                  explicit operator runbook step (payout_requests), not a
--                  pretend button that mints money.
--
-- Every balance is derived from an append-only ledger, so the number in the
-- wallet can always be re-computed from history — which is what makes this a
-- ledger rather than a counter somebody can patch.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Wallet + ledger.
-- ---------------------------------------------------------------------------
create table if not exists public.star_wallets (
  user_id       uuid primary key references public.profiles (id) on delete cascade,
  balance       bigint not null default 0 check (balance >= 0),
  lifetime_in   bigint not null default 0 check (lifetime_in >= 0),
  lifetime_out  bigint not null default 0 check (lifetime_out >= 0),
  updated_at    timestamptz not null default clock_timestamp()
);

comment on table public.star_wallets is
  'Cached balance, maintained only by the ledger trigger. Never written by a client: the RLS section grants SELECT and nothing else.';

create table if not exists public.star_ledger (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  delta      bigint not null check (delta <> 0),
  reason     text not null check (reason in (
               'purchase', 'tip_in', 'tip_out', 'gift_in', 'gift_out', 'tag_mint',
               'tag_purchase', 'cosmetic_purchase', 'subscription', 'boost',
               'unlock', 'refund', 'payout', 'adjustment')),
  ref_type   text check (ref_type is null or char_length(ref_type) <= 32),
  ref_id     text check (ref_id is null or char_length(ref_id) <= 128),
  metadata   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp()
);

comment on table public.star_ledger is
  'Append-only Stars ledger. `ref_type`/`ref_id` point at the thing that caused the movement, so a disputed balance can be reconstructed line by line.';

create index if not exists star_ledger_user_idx on public.star_ledger (user_id, created_at desc);
create index if not exists star_ledger_ref_idx on public.star_ledger (ref_type, ref_id);

create or replace function app.star_ledger_apply()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.star_wallets (user_id, balance, lifetime_in, lifetime_out)
  values (new.user_id,
          greatest(new.delta, 0),
          greatest(new.delta, 0),
          greatest(-new.delta, 0))
  on conflict (user_id) do update
    set balance      = public.star_wallets.balance + new.delta,
        lifetime_in  = public.star_wallets.lifetime_in + greatest(new.delta, 0),
        lifetime_out = public.star_wallets.lifetime_out + greatest(-new.delta, 0),
        updated_at   = clock_timestamp();

  -- A debit that would drive the balance negative is a bug, not a business
  -- case: raise here so the whole transaction (including whatever was being
  -- bought) rolls back instead of leaving a half-applied purchase.
  if (select w.balance from public.star_wallets w where w.user_id = new.user_id) < 0 then
    raise exception 'insufficient stars' using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists star_ledger_apply on public.star_ledger;
create trigger star_ledger_apply
  after insert on public.star_ledger
  for each row execute function app.star_ledger_apply();

-- ---------------------------------------------------------------------------
-- 2. Catalogue: Stars packs, the $2.49 tag mint, cosmetics and gifts.
--    Prices are data, not constants in code, so a change is a one-row update.
-- ---------------------------------------------------------------------------
create table if not exists public.star_products (
  sku          text primary key check (sku ~ '^[a-z0-9._-]{3,48}$'),
  kind         text not null check (kind in ('stars', 'tag_mint', 'boost', 'subscription', 'supporter')),
  title        text not null,
  description  text,
  price_cents  integer not null check (price_cents >= 0),
  currency     text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  stars        integer not null default 0 check (stars >= 0),
  entitlements jsonb not null default '{}'::jsonb,
  is_active    boolean not null default true,
  position     integer not null default 100,
  created_at   timestamptz not null default clock_timestamp()
);

comment on table public.star_products is
  'What money can buy. `tag_mint` is the $2.49 custom-tag credit; `stars` packs are the tipping currency.';

insert into public.star_products (sku, kind, title, description, price_cents, stars, entitlements, position) values
  ('tag.custom',      'tag_mint',    'Custom profile tag',   'Mint one custom tag like [GRAND] with your own colours, glow and emoji.', 249, 0,   '{"tag_mint": 1}'::jsonb, 10),
  ('stars.100',       'stars',       '100 Stars',            'Tip creators, unlock tags, send gifts.',                                  149, 100, '{}'::jsonb, 20),
  ('stars.500',       'stars',       '500 Stars',            'Best value for regular tipping.',                                         699, 500, '{}'::jsonb, 30),
  ('stars.1200',      'stars',       '1200 Stars',           'For the people who fund the creators they love.',                        1499, 1200,'{}'::jsonb, 40),
  ('supporter.month', 'subscription','Supporter',            'A supporter badge, animated name effect and 200 Stars every month.',      499, 200, '{"role": "supporter", "monthly_stars": 200}'::jsonb, 50)
on conflict (sku) do nothing;

create table if not exists public.cosmetics (
  id           uuid primary key default app.uuid_v7(),
  slug         text not null unique check (slug ~ '^[a-z0-9._-]{3,48}$'),
  kind         text not null check (kind in ('badge', 'frame', 'effect', 'theme', 'tag_style', 'sound')),
  name         text not null check (char_length(btrim(name)) between 1 and 60),
  description  text,
  rarity       text not null default 'common' check (rarity in ('common', 'rare', 'epic', 'legendary', 'limited')),
  price_stars  integer not null default 0 check (price_stars >= 0),
  -- Purely presentational data the client renders: gradient stops, glow colour,
  -- animation key, badge glyph. Server-side it is opaque JSON, which is why a
  -- new visual style never needs a migration.
  style        jsonb not null default '{}'::jsonb,
  is_active    boolean not null default true,
  position     integer not null default 100,
  created_at   timestamptz not null default clock_timestamp(),
  constraint cosmetics_style_shape check (jsonb_typeof(style) = 'object' and pg_column_size(style) <= 8192)
);

create index if not exists cosmetics_catalog_idx on public.cosmetics (kind, position) where is_active;

insert into public.cosmetics (slug, kind, name, description, rarity, price_stars, style, position) values
  ('tag.ember',    'tag_style', 'Ember',    'Warm orange gradient with a soft glow.',        'common',    0,   '{"gradient": ["#ff8a00", "#e52e71"], "glow": "#ff8a00", "text": "#ffffff"}'::jsonb, 10),
  ('tag.midnight', 'tag_style', 'Midnight', 'Deep blue with a cyan rim.',                    'common',    0,   '{"gradient": ["#0f2027", "#2c5364"], "glow": "#2c5364", "text": "#e8f6ff"}'::jsonb, 20),
  ('tag.grand',    'tag_style', 'Grand',    'Gold on black — the [GRAND] look.',             'rare',      75,  '{"gradient": ["#000000", "#3a2a00"], "glow": "#ffd700", "text": "#ffd700", "border": true}'::jsonb, 30),
  ('tag.gg',       'tag_style', 'GG',       'Electric violet, animated shimmer.',            'rare',      75,  '{"gradient": ["#7f00ff", "#e100ff"], "glow": "#b026ff", "text": "#ffffff", "shimmer": true}'::jsonb, 40),
  ('tag.admin',    'tag_style', 'Admin',    'Restrained red — reserved for staff.',          'limited',   0,   '{"gradient": ["#3b0d0d", "#7a1f1f"], "glow": "#ff4d4d", "text": "#ffdede"}'::jsonb, 50),
  ('badge.early',  'badge',     'Early bird','Joined in the first thousand.',                'limited',   0,   '{"glyph": "🐣", "color": "#f5c451"}'::jsonb, 60),
  ('badge.creator','badge',     'Creator',  'Has published to MessengerX.',                  'common',    0,   '{"glyph": "🎬", "color": "#ff5f5f"}'::jsonb, 70),
  ('badge.supporter','badge',   'Supporter','Backed the platform with Stars.',               'epic',      0,   '{"glyph": "💎", "color": "#5ad1ff"}'::jsonb, 80),
  ('frame.aurora', 'frame',     'Aurora',   'Animated ring around the avatar.',              'epic',      150, '{"ring": ["#00c6ff", "#0072ff", "#7b2ff7"], "animated": true}'::jsonb, 90),
  ('effect.confetti','effect',  'Confetti', 'Fires on gift and milestone messages.',         'rare',      120, '{"particles": "confetti", "trigger": "gift"}'::jsonb, 100)
on conflict (slug) do nothing;

create table if not exists public.user_cosmetics (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  cosmetic_id uuid not null references public.cosmetics (id) on delete cascade,
  source      text not null default 'purchase' check (source in ('purchase', 'gift', 'grant', 'subscription')),
  equipped    boolean not null default false,
  acquired_at timestamptz not null default clock_timestamp(),
  primary key (user_id, cosmetic_id)
);

create index if not exists user_cosmetics_equipped_idx
  on public.user_cosmetics (user_id) where equipped;

-- Custom tags: the $2.49 product ---------------------------------------------
create table if not exists public.profile_tags (
  id          uuid primary key default app.uuid_v7(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  text        text not null check (char_length(btrim(text)) between 1 and 20),
  -- Text between the brackets, without them; kept separately so a rename is a
  -- single update and the renderer never has to strip characters.
  style_id    uuid references public.cosmetics (id) on delete set null,
  style       jsonb not null default '{}'::jsonb,
  emoji       text check (emoji is null or char_length(emoji) <= 8),
  slot        smallint not null default 0 check (slot between 0 and 4),
  is_active   boolean not null default true,
  price_paid_cents integer not null default 0 check (price_paid_cents >= 0),
  created_at  timestamptz not null default clock_timestamp(),
  expires_at  timestamptz,
  constraint profile_tags_style_shape check (jsonb_typeof(style) = 'object' and pg_column_size(style) <= 4096),
  constraint profile_tags_unique_slot check (true)
);

comment on table public.profile_tags is
  'User-created profile tags ("[GRAND]", "[GG]"). Minted once per purchase — either a Stripe tag credit ($2.49) or the Stars equivalent.';

create unique index if not exists profile_tags_user_slot_key
  on public.profile_tags (user_id, slot) where is_active;
create index if not exists profile_tags_user_idx on public.profile_tags (user_id, slot);

-- Entitlements bought with real money that are not Stars yet.
create table if not exists public.user_entitlements (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  entitlement text not null check (entitlement in ('tag_mint', 'supporter', 'boost', 'verified_review')),
  remaining   integer not null default 0 check (remaining >= 0),
  expires_at  timestamptz,
  updated_at  timestamptz not null default clock_timestamp(),
  primary key (user_id, entitlement)
);

-- ---------------------------------------------------------------------------
-- 3. Payments: Stripe sessions and webhook events, idempotent by construction.
-- ---------------------------------------------------------------------------
create table if not exists public.payments (
  id                 uuid primary key default app.uuid_v7(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  provider           text not null default 'stripe' check (provider in ('stripe', 'stars')),
  sku                text not null references public.star_products (sku),
  provider_session_id text unique,
  provider_payment_id text,
  amount_cents       integer not null check (amount_cents >= 0),
  currency           text not null default 'usd',
  status             text not null default 'created'
                     check (status in ('created', 'paid', 'failed', 'refunded', 'expired')),
  stars_granted      integer not null default 0 check (stars_granted >= 0),
  metadata           jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default clock_timestamp(),
  paid_at            timestamptz,
  updated_at         timestamptz not null default clock_timestamp()
);

create index if not exists payments_user_idx on public.payments (user_id, created_at desc);

comment on table public.payments is
  'One row per Checkout attempt. The webhook settles by session id, so a retried Stripe event updates the same row instead of paying twice.';

create table if not exists public.stripe_events (
  id           text primary key,          -- Stripe event id: the idempotency key
  type         text not null,
  payload      jsonb not null,
  received_at  timestamptz not null default clock_timestamp(),
  processed_at timestamptz,
  error        text
);

comment on table public.stripe_events is
  'Raw Stripe webhook deliveries. Kept even when processing fails so a replay is possible without asking Stripe again.';

-- Gifts and tips --------------------------------------------------------------
create table if not exists public.gifts (
  id           uuid primary key default app.uuid_v7(),
  sender_id    uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  stars        integer not null check (stars > 0),
  kind         text not null default 'gift' check (kind in ('gift', 'tip', 'super_thanks', 'unlock')),
  video_id     uuid references public.videos (id) on delete set null,
  short_id     uuid references public.shorts (id) on delete set null,
  chat_id      uuid references public.chats (id) on delete set null,
  message_id   uuid references public.messages (id) on delete set null,
  note         text check (note is null or char_length(note) <= 200),
  is_anonymous boolean not null default false,
  created_at   timestamptz not null default clock_timestamp(),
  constraint gifts_not_self check (sender_id <> recipient_id)
);

create index if not exists gifts_recipient_idx on public.gifts (recipient_id, created_at desc);
create index if not exists gifts_surface_idx on public.gifts (video_id, created_at desc);

comment on table public.gifts is
  'Stars sent to a creator or a friend, optionally attached to a video, short or chat. 100% reaches the recipient; the platform takes no cut.';

create table if not exists public.payout_requests (
  id          uuid primary key default app.uuid_v7(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  stars       integer not null check (stars > 0),
  method      text not null default 'manual' check (method in ('manual')),
  details     text check (details is null or char_length(details) <= 500),
  state       text not null default 'requested' check (state in ('requested', 'approved', 'paid', 'rejected')),
  operator_note text,
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp()
);

comment on table public.payout_requests is
  'Cash-out requests, settled by the operator (docs/runbook.md). Deliberately not automated: an automatic payout rail would need a payment licence, and pretending otherwise would be dishonest.';

-- ---------------------------------------------------------------------------
-- 4. The only functions allowed to move value.
--    `app.stars_credit`/`app.stars_debit` are executable by service_role only;
--    `public.*` wrappers enforce "pay from your own wallet" for clients.
-- ---------------------------------------------------------------------------
create or replace function app.stars_credit(
  p_user_id  uuid,
  p_amount   bigint,
  p_reason   text,
  p_ref_type text default null,
  p_ref_id   text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_balance bigint;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'a credit must be positive' using errcode = '22023';
  end if;
  insert into public.star_ledger (user_id, delta, reason, ref_type, ref_id, metadata)
  values (p_user_id, p_amount, p_reason, p_ref_type, p_ref_id, coalesce(p_metadata, '{}'::jsonb));
  select w.balance into v_balance from public.star_wallets w where w.user_id = p_user_id;
  return coalesce(v_balance, 0);
end;
$$;

create or replace function app.stars_debit(
  p_user_id  uuid,
  p_amount   bigint,
  p_reason   text,
  p_ref_type text default null,
  p_ref_id   text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_balance bigint;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'a debit must be positive' using errcode = '22023';
  end if;
  select w.balance into v_balance from public.star_wallets w where w.user_id = p_user_id;
  if coalesce(v_balance, 0) < p_amount then
    raise exception 'not enough stars' using errcode = '22023';
  end if;
  insert into public.star_ledger (user_id, delta, reason, ref_type, ref_id, metadata)
  values (p_user_id, -p_amount, p_reason, p_ref_type, p_ref_id, coalesce(p_metadata, '{}'::jsonb));
  select w.balance into v_balance from public.star_wallets w where w.user_id = p_user_id;
  return coalesce(v_balance, 0);
end;
$$;

comment on function app.stars_debit(uuid, bigint, text, text, text, jsonb) is
  'The single debit path. Raises on insufficient balance so the buyer''s transaction rolls back whole rather than half-applying.';

-- ---------------------------------------------------------------------------
-- 5. Client-facing RPCs.
-- ---------------------------------------------------------------------------
create or replace function public.wallet_summary()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'balance', coalesce((select w.balance from public.star_wallets w where w.user_id = app.current_uid()), 0),
    'lifetime_in', coalesce((select w.lifetime_in from public.star_wallets w where w.user_id = app.current_uid()), 0),
    'lifetime_out', coalesce((select w.lifetime_out from public.star_wallets w where w.user_id = app.current_uid()), 0),
    'earned_from_gifts', coalesce((
      select sum(g.stars) from public.gifts g
       where g.recipient_id = app.current_uid() and g.sender_id <> app.current_uid()), 0),
    'sent_as_gifts', coalesce((
      select sum(g.stars) from public.gifts g
       where g.sender_id = app.current_uid() and g.recipient_id <> app.current_uid()), 0),
    'tag_credits', coalesce((
      select e.remaining from public.user_entitlements e
       where e.user_id = app.current_uid() and e.entitlement = 'tag_mint'), 0)
  );
$$;

create or replace function public.star_ledger_list(p_limit integer default 50)
returns table (
  id         bigint,
  delta      bigint,
  reason     text,
  ref_type   text,
  ref_id     text,
  metadata   jsonb,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select l.id, l.delta, l.reason, l.ref_type, l.ref_id, l.metadata, l.created_at
    from public.star_ledger l
   where l.user_id = app.current_uid()
   order by l.created_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

create or replace function public.store_catalog()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'stars', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.position)
        from (select sku, kind, title, description, price_cents, currency, stars, position
                from public.star_products where is_active and kind in ('stars', 'subscription')) p
    ), '[]'::jsonb),
    'tag_mint', coalesce((
      select to_jsonb(p) from (
        select sku, title, description, price_cents, currency from public.star_products
         where sku = 'tag.custom' and is_active) p
    ), 'null'::jsonb),
    'tag_styles', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.position)
        from (select id, slug, name, description, rarity, price_stars, style, position
                from public.cosmetics where kind = 'tag_style' and is_active) c
    ), '[]'::jsonb),
    'cosmetics', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.kind, c.position)
        from (select id, slug, kind, name, description, rarity, price_stars, style, position
                from public.cosmetics where kind <> 'tag_style' and is_active) c
    ), '[]'::jsonb),
    'mine', coalesce((
      select jsonb_agg(jsonb_build_object('cosmetic_id', uc.cosmetic_id, 'equipped', uc.equipped, 'source', uc.source))
        from public.user_cosmetics uc where uc.user_id = app.current_uid()
    ), '[]'::jsonb)
  );
$$;

comment on function public.store_catalog() is
  'Everything the store screen renders in one call: packs, the tag mint product, tag styles, cosmetics and what the caller already owns.';

create or replace function public.cosmetic_buy(p_slug text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid  uuid := app.current_uid();
  v_item public.cosmetics%rowtype;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select * into v_item from public.cosmetics c where c.slug = p_slug and c.is_active;
  if not found then
    raise exception 'that item does not exist' using errcode = '22023';
  end if;
  if exists (select 1 from public.user_cosmetics uc
              where uc.user_id = v_uid and uc.cosmetic_id = v_item.id) then
    return v_item.id;   -- already owned: idempotent, not an error
  end if;

  if v_item.price_stars > 0 then
    perform app.stars_debit(v_uid, v_item.price_stars, 'cosmetic_purchase', 'cosmetic', v_item.slug);
  end if;
  insert into public.user_cosmetics (user_id, cosmetic_id, source)
  values (v_uid, v_item.id, 'purchase')
  on conflict do nothing;
  return v_item.id;
end;
$$;

create or replace function public.cosmetic_equip(p_cosmetic_id uuid, p_equipped boolean default true)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_kind text;
begin
  select c.kind into v_kind
    from public.cosmetics c
    join public.user_cosmetics uc on uc.cosmetic_id = c.id and uc.user_id = v_uid
   where c.id = p_cosmetic_id;
  if v_kind is null then
    raise exception 'you do not own that item' using errcode = '42501';
  end if;

  -- One equipped item per kind: equipping a new frame replaces the old one
  -- rather than stacking two rings on one avatar.
  if p_equipped then
    update public.user_cosmetics uc
       set equipped = false
     where uc.user_id = v_uid
       and uc.equipped
       and uc.cosmetic_id in (select c.id from public.cosmetics c where c.kind = v_kind);
  end if;
  update public.user_cosmetics uc set equipped = p_equipped
   where uc.user_id = v_uid and uc.cosmetic_id = p_cosmetic_id;
end;
$$;

-- Custom tags -----------------------------------------------------------------
create or replace function public.mint_tag(
  p_text     text,
  p_style    jsonb default '{}'::jsonb,
  p_style_id uuid default null,
  p_emoji    text default null,
  p_slot     integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid     uuid := app.current_uid();
  v_clean   text;
  v_credits integer;
  v_price   integer;
  v_id      uuid;
  v_taken   integer;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not app.access_ok(v_uid) then
    raise exception 'this account may not mint tags yet' using errcode = '42501';
  end if;

  -- Sanitise, then trim: bracketing and emoji are the user's habit, not part of
  -- the tag, and the renderer must never receive a stray space.
  v_clean := btrim(regexp_replace(upper(btrim(coalesce(p_text, ''))), '[^A-Z0-9 _-]', '', 'g'));
  if char_length(v_clean) < 1 or char_length(v_clean) > 16 then
    raise exception 'a tag is 1-16 characters of A-Z, 0-9, space, - or _' using errcode = '22023';
  end if;
  if p_slot is null or p_slot < 0 or p_slot > 4 then
    raise exception 'a profile holds up to five tags' using errcode = '22023';
  end if;

  select count(*) into v_taken from public.profile_tags t
   where t.user_id = v_uid and t.is_active;
  if v_taken >= 5 then
    raise exception 'remove a tag before minting another' using errcode = '22023';
  end if;

  -- Payment order: a Stripe tag credit first (the $2.49 product), then Stars.
  select e.remaining into v_credits from public.user_entitlements e
   where e.user_id = v_uid and e.entitlement = 'tag_mint';

  if coalesce(v_credits, 0) > 0 then
    update public.user_entitlements e
       set remaining = e.remaining - 1, updated_at = clock_timestamp()
     where e.user_id = v_uid and e.entitlement = 'tag_mint';
    select p.price_cents into v_price from public.star_products p where p.sku = 'tag.custom';
  else
    select coalesce(p.price_cents, 0) into v_price from public.star_products p where p.sku = 'tag.custom';
    -- No credit: the same product can be paid in Stars at 20 Stars per dollar,
    -- which is the rate the Stars packs use.
    v_price := coalesce(v_price, 249);
    perform app.stars_debit(v_uid, (v_price * 20 / 100)::bigint, 'tag_mint', 'tag', v_clean);
  end if;

  insert into public.profile_tags (user_id, text, style_id, style, emoji, slot, price_paid_cents)
  values (v_uid, v_clean,
          p_style_id,
          coalesce((
            select c.style from public.cosmetics c
             where c.id = p_style_id and c.kind = 'tag_style'
          ), coalesce(p_style, '{}'::jsonb)),
          nullif(btrim(coalesce(p_emoji, '')), ''), p_slot, coalesce(v_price, 0))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.mint_tag(text, jsonb, uuid, text, integer) is
  'Mint a custom tag: consumes a paid tag credit ($2.49 via Stripe) or the Stars equivalent. Server-side cleanup + length limits, so the badge renderer can trust the text.';

create or replace function public.tag_update(
  p_tag_id uuid,
  p_text   text default null,
  p_style  jsonb default null,
  p_style_id uuid default null,
  p_emoji  text default null,
  p_slot   integer default null,
  p_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid   uuid := app.current_uid();
  v_clean text;
begin
  if p_text is not null then
    v_clean := btrim(regexp_replace(upper(btrim(p_text)), '[^A-Z0-9 _-]', '', 'g'));
    if char_length(v_clean) < 1 or char_length(v_clean) > 16 then
      raise exception 'a tag is 1-16 characters of A-Z, 0-9, space, - or _' using errcode = '22023';
    end if;
  end if;

  update public.profile_tags t set
    text      = coalesce(v_clean, t.text),
    style_id  = coalesce(p_style_id, t.style_id),
    style     = coalesce(p_style, t.style),
    emoji     = case when p_emoji is null then t.emoji else nullif(btrim(p_emoji), '') end,
    slot      = coalesce(p_slot, t.slot),
    is_active = coalesce(p_active, t.is_active)
   where t.id = p_tag_id and t.user_id = v_uid;
  if not found then
    raise exception 'that tag is not yours' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.tag_delete(p_tag_id uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  delete from public.profile_tags t where t.id = p_tag_id and t.user_id = app.current_uid();
$$;

-- The public projection the badge renderer consumes: identity + tags + badges.
create or replace function public.profile_identity(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_identity jsonb;
begin
  if not app.can_view_user(app.current_uid(), p_user_id) then
    return null;
  end if;

  select to_jsonb(x) into v_identity from (
    select p.id, p.username, p.discriminator, p.display_name, p.avatar_path, p.cover_path,
           p.verified, p.is_private, p.creator_mode, p.bio, p.pronouns, p.location, p.website,
           p.accent, p.socials, p.follower_count, p.following_count, p.post_count, p.created_at,
           app.is_following(app.current_uid(), p.id) as followed_by_me
      from public.profiles p
     where p.id = p_user_id and p.deleted_at is null
  ) x;

  if v_identity is null then
    return null;
  end if;

  return v_identity || jsonb_build_object(
    'tags', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'text', t.text, 'emoji', t.emoji,
                                          'style', t.style, 'slot', t.slot) order by t.slot)
        from public.profile_tags t
       where t.user_id = p_user_id and t.is_active
         and (t.expires_at is null or t.expires_at > clock_timestamp())
    ), '[]'::jsonb),
    'badges', coalesce((
      select jsonb_agg(jsonb_build_object('slug', c.slug, 'name', c.name, 'style', c.style, 'rarity', c.rarity)
                        order by c.position)
        from public.user_cosmetics uc
        join public.cosmetics c on c.id = uc.cosmetic_id
       where uc.user_id = p_user_id and c.kind in ('badge', 'frame', 'effect')
         and (uc.source = 'grant' or uc.equipped or c.price_stars = 0)
    ), '[]'::jsonb)
  );
end;
$$;

comment on function public.profile_identity(uuid) is
  'One call for the profile header and the badge renderer: handle#tag, tags, badges and the follow relationship.';

-- Gifts -----------------------------------------------------------------------
create or replace function public.gift_send(
  p_recipient_id uuid,
  p_stars        integer,
  p_kind         text default 'gift',
  p_video_id     uuid default null,
  p_short_id     uuid default null,
  p_chat_id      uuid default null,
  p_message_id   uuid default null,
  p_note         text default null,
  p_anonymous    boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
  v_recipient_name text;
begin
  if v_uid is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_stars is null or p_stars <= 0 or p_stars > 100000 then
    raise exception 'a gift is between 1 and 100000 Stars' using errcode = '22023';
  end if;
  if p_recipient_id = v_uid then
    raise exception 'you cannot gift yourself' using errcode = '22023';
  end if;
  if p_kind not in ('gift', 'tip', 'super_thanks', 'unlock') then
    raise exception 'unknown gift kind %', p_kind using errcode = '22023';
  end if;
  if app.blocked_pair(v_uid, p_recipient_id) then
    raise exception 'that account is not available' using errcode = '42501';
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), p.username) into v_recipient_name
    from public.profiles p where p.id = p_recipient_id;
  if v_recipient_name is null then
    raise exception 'that account does not exist' using errcode = '22023';
  end if;

  perform app.stars_debit(v_uid, p_stars, case when p_kind = 'tip' then 'tip_out' else 'gift_out' end,
                         'gift', p_recipient_id::text);
  perform app.stars_credit(p_recipient_id, p_stars, case when p_kind = 'tip' then 'tip_in' else 'gift_in' end,
                           'gift', v_uid::text);

  insert into public.gifts (sender_id, recipient_id, stars, kind, video_id, short_id, chat_id,
                            message_id, note, is_anonymous)
  values (v_uid, p_recipient_id, p_stars, p_kind, p_video_id, p_short_id, p_chat_id,
          p_message_id, nullif(btrim(coalesce(p_note, '')), ''), coalesce(p_anonymous, false))
  returning id into v_id;

  -- The recipient hears about it; the surface author hears about it too when
  -- the gift was attached to a video or short.
  insert into public.notifications (user_id, kind, actor_id, video_id, short_id, payload)
  values (p_recipient_id, 'gift',
          case when coalesce(p_anonymous, false) then null else v_uid end,
          p_video_id, p_short_id,
          jsonb_build_object('stars', p_stars, 'kind', p_kind, 'note', left(coalesce(p_note, ''), 140)));

  if p_video_id is not null then
    insert into public.notifications (user_id, kind, actor_id, video_id, payload)
    select v.author_id, 'stars',
           case when coalesce(p_anonymous, false) then null else v_uid end,
           v.id, jsonb_build_object('stars', p_stars, 'kind', p_kind)
      from public.videos v
     where v.id = p_video_id and v.author_id <> p_recipient_id;
  elsif p_short_id is not null then
    insert into public.notifications (user_id, kind, actor_id, short_id, payload)
    select s.author_id, 'stars',
           case when coalesce(p_anonymous, false) then null else v_uid end,
           s.id, jsonb_build_object('stars', p_stars, 'kind', p_kind)
      from public.shorts s
     where s.id = p_short_id and s.author_id <> p_recipient_id;
  end if;

  return v_id;
end;
$$;

comment on function public.gift_send(uuid, integer, text, uuid, uuid, uuid, uuid, text, boolean) is
  'Sends Stars from the caller''s wallet to another account and records the gift. Debit and credit are one transaction: a partial gift is impossible.';

create or replace function public.gifts_received(p_limit integer default 50)
returns table (
  id           uuid,
  stars        integer,
  kind         text,
  note         text,
  is_anonymous boolean,
  created_at   timestamptz,
  sender_name  text,
  sender_username text,
  sender_avatar text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select g.id, g.stars, g.kind, g.note, g.is_anonymous, g.created_at,
         case when g.is_anonymous then 'Anonymous'
              else coalesce(nullif(btrim(p.display_name), ''), p.username) end,
         case when g.is_anonymous then null else p.username end,
         case when g.is_anonymous then null else p.avatar_path end
    from public.gifts g
    left join public.profiles p on p.id = g.sender_id
   where g.recipient_id = app.current_uid()
   order by g.created_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

create or replace function public.payout_request(p_stars integer, p_details text default null)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_uid uuid := app.current_uid();
  v_id  uuid;
begin
  if p_stars is null or p_stars < 1000 then
    raise exception 'the minimum payout is 1000 Stars' using errcode = '22023';
  end if;
  perform app.stars_debit(v_uid, p_stars, 'payout', 'payout', null);
  insert into public.payout_requests (user_id, stars, details)
  values (v_uid, p_stars, nullif(btrim(coalesce(p_details, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.payout_requests_list()
returns table (
  id         uuid,
  stars      integer,
  state      text,
  details    text,
  operator_note text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select r.id, r.stars, r.state, r.details, r.operator_note, r.created_at
    from public.payout_requests r
   where r.user_id = app.current_uid()
   order by r.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- 6. Service-role settlement: what the Stripe webhook and the bots call.
-- ---------------------------------------------------------------------------
create or replace function public.payment_create_pending(
  p_user_id  uuid,
  p_sku      text,
  p_session_id text,
  p_amount_cents integer default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_product public.star_products%rowtype;
  v_id uuid;
begin
  select * into v_product from public.star_products p where p.sku = p_sku and p.is_active;
  if not found then
    raise exception 'unknown or inactive product %', p_sku using errcode = '22023';
  end if;
  insert into public.payments (user_id, provider, sku, provider_session_id, amount_cents, currency, status, metadata)
  values (p_user_id, 'stripe', p_sku, p_session_id,
          coalesce(p_amount_cents, v_product.price_cents), v_product.currency, 'created',
          coalesce(p_metadata, '{}'::jsonb))
  on conflict (provider_session_id) do update
    set updated_at = clock_timestamp()
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.payment_create_pending(uuid, text, text, integer, jsonb) is
  'Called by the stripe-checkout edge function when a session is minted. Idempotent on the session id.';

create or replace function public.payment_settle(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event_id text := p_event ->> 'id';
  v_type     text := p_event ->> 'type';
  v_session  jsonb := coalesce(p_event -> 'data' -> 'object', '{}'::jsonb);
  v_session_id text := v_session ->> 'id';
  v_payment_id text := v_session ->> 'payment_intent';
  v_meta     jsonb := coalesce(v_session -> 'metadata', '{}'::jsonb);
  v_sku      text := v_meta ->> 'sku';
  v_user     uuid := nullif(v_meta ->> 'user_id', '')::uuid;
  v_amount   integer := coalesce((v_session ->> 'amount_total')::integer, 0);
  v_product  public.star_products%rowtype;
  v_payment  public.payments%rowtype;
  v_granted  integer := 0;
begin
  if v_event_id is null or v_type is null then
    raise exception 'not a Stripe event' using errcode = '22023';
  end if;

  insert into public.stripe_events (id, type, payload)
  values (v_event_id, v_type, p_event)
  on conflict (id) do nothing;
  if not found then
    -- Already delivered: report the previous outcome instead of paying twice.
    return jsonb_build_object('duplicate', true, 'event', v_event_id);
  end if;

  if v_type <> 'checkout.session.completed' then
    update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;
    return jsonb_build_object('ignored', true, 'type', v_type);
  end if;

  if v_user is null or v_sku is null then
    raise exception 'the session is missing its metadata' using errcode = '22023';
  end if;

  select * into v_product from public.star_products p where p.sku = v_sku;
  if not found then
    raise exception 'unknown product %', v_sku using errcode = '22023';
  end if;

  select * into v_payment from public.payments p where p.provider_session_id = v_session_id;
  if found and v_payment.status = 'paid' then
    update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;
    return jsonb_build_object('duplicate', true, 'payment', v_payment.id);
  end if;

  insert into public.payments (user_id, provider, sku, provider_session_id, provider_payment_id,
                               amount_cents, currency, status, paid_at, metadata)
  values (v_user, 'stripe', v_sku, v_session_id, v_payment_id,
          coalesce(nullif(v_amount, 0), v_product.price_cents), v_product.currency, 'paid',
          clock_timestamp(), v_meta)
  on conflict (provider_session_id) do update
    set status = 'paid', provider_payment_id = excluded.provider_payment_id,
        paid_at = coalesce(public.payments.paid_at, clock_timestamp()),
        amount_cents = excluded.amount_cents,
        updated_at = clock_timestamp()
  returning * into v_payment;

  -- Value lands here, exactly once per paid row.
  if v_product.stars > 0 then
    perform app.stars_credit(v_user, v_product.stars, 'purchase', 'payment', v_payment.id::text,
                             jsonb_build_object('sku', v_sku));
    v_granted := v_product.stars;
  end if;

  if coalesce((v_product.entitlements ->> 'tag_mint')::int, 0) > 0 then
    insert into public.user_entitlements (user_id, entitlement, remaining)
    values (v_user, 'tag_mint', (v_product.entitlements ->> 'tag_mint')::int)
    on conflict (user_id, entitlement) do update
      set remaining = public.user_entitlements.remaining + (v_product.entitlements ->> 'tag_mint')::int,
          updated_at = clock_timestamp();
  end if;

  if v_product.kind = 'subscription' then
    insert into public.user_entitlements (user_id, entitlement, remaining, expires_at)
    values (v_user, 'supporter', 1, clock_timestamp() + interval '31 days')
    on conflict (user_id, entitlement) do update
      set remaining = 1, expires_at = clock_timestamp() + interval '31 days', updated_at = clock_timestamp();

    -- The supporter badge is granted for the duration instead of sold twice.
    insert into public.user_cosmetics (user_id, cosmetic_id, source)
    select v_user, c.id, 'subscription' from public.cosmetics c where c.slug = 'badge.supporter'
    on conflict (user_id, cosmetic_id) do update set source = 'subscription';
  end if;

  update public.payments set stars_granted = v_granted, updated_at = clock_timestamp()
   where id = v_payment.id;

  insert into public.notifications (user_id, kind, payload)
  values (v_user, 'stars',
          jsonb_build_object('purchased', true, 'sku', v_sku, 'stars', v_granted,
                             'amount_cents', v_payment.amount_cents));

  update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;

  return jsonb_build_object('ok', true, 'payment', v_payment.id, 'stars_granted', v_granted,
                            'entitlements', v_product.entitlements);
end;
$$;

comment on function public.payment_settle(jsonb) is
  'Idempotent Stripe settlement: event id and session id are both keys, so a redelivered webhook can never double-credit.';

create or replace function public.payment_mark_failed(p_session_id text, p_reason text default null)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.payments p
     set status = 'failed', metadata = p.metadata || jsonb_build_object('error', left(coalesce(p_reason, ''), 300)),
         updated_at = clock_timestamp()
   where p.provider_session_id = p_session_id and p.status <> 'paid';
$$;

create or replace function public.payment_list(p_limit integer default 30)
returns table (
  id           uuid,
  sku          text,
  status       text,
  amount_cents integer,
  currency     text,
  stars_granted integer,
  created_at   timestamptz,
  paid_at      timestamptz
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.id, p.sku, p.status, p.amount_cents, p.currency, p.stars_granted, p.created_at, p.paid_at
    from public.payments p
   where p.user_id = app.current_uid()
   order by p.created_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

create or replace function public.payment_attach_session(p_payment_id uuid, p_session_id text)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  update public.payments p
     set provider_session_id = p_session_id, updated_at = clock_timestamp()
   where p.id = p_payment_id and p.user_id = app.current_uid() and p.status = 'created';
$$;

-- ---------------------------------------------------------------------------
-- 7. RLS + grants. Nothing here is client-writable: reads only, RPCs for the
--    rest, and `app.stars_*` / `payment_settle` for the service role.
-- ---------------------------------------------------------------------------
alter table public.star_wallets        enable row level security;
alter table public.star_ledger         enable row level security;
alter table public.star_products       enable row level security;
alter table public.cosmetics           enable row level security;
alter table public.user_cosmetics      enable row level security;
alter table public.profile_tags        enable row level security;
alter table public.user_entitlements   enable row level security;
alter table public.payments            enable row level security;
alter table public.stripe_events       enable row level security;
alter table public.gifts               enable row level security;
alter table public.payout_requests     enable row level security;

drop policy if exists star_wallets_own on public.star_wallets;
create policy star_wallets_own on public.star_wallets
  for select to authenticated using (user_id = (select app.current_uid()));

drop policy if exists star_ledger_own on public.star_ledger;
create policy star_ledger_own on public.star_ledger
  for select to authenticated using (user_id = (select app.current_uid()));

drop policy if exists star_products_read on public.star_products;
create policy star_products_read on public.star_products
  for select to authenticated using (is_active);

drop policy if exists cosmetics_read on public.cosmetics;
create policy cosmetics_read on public.cosmetics
  for select to authenticated using (is_active);

drop policy if exists user_cosmetics_own on public.user_cosmetics;
create policy user_cosmetics_own on public.user_cosmetics
  for select to authenticated using (user_id = (select app.current_uid()));

drop policy if exists profile_tags_read on public.profile_tags;
create policy profile_tags_read on public.profile_tags
  for select to authenticated using (true);

drop policy if exists user_entitlements_own on public.user_entitlements;
create policy user_entitlements_own on public.user_entitlements
  for select to authenticated using (user_id = (select app.current_uid()));

drop policy if exists payments_own on public.payments;
create policy payments_own on public.payments
  for select to authenticated using (user_id = (select app.current_uid()));

drop policy if exists gifts_parties on public.gifts;
create policy gifts_parties on public.gifts
  for select to authenticated
  using (sender_id = (select app.current_uid()) or recipient_id = (select app.current_uid()));

drop policy if exists payout_requests_own on public.payout_requests;
create policy payout_requests_own on public.payout_requests
  for select to authenticated using (user_id = (select app.current_uid()));

grant select on public.star_wallets, public.star_ledger, public.star_products, public.cosmetics,
                public.user_cosmetics, public.profile_tags, public.user_entitlements,
                public.payments, public.gifts, public.payout_requests
  to authenticated;
-- The Stripe webhook / settlement worker writes payments, stripe_events and
-- entitlements through the service key, so it needs the table grants too.
grant all on public.star_wallets, public.star_ledger, public.star_products, public.cosmetics,
             public.user_cosmetics, public.profile_tags, public.user_entitlements,
             public.payments, public.stripe_events, public.gifts, public.payout_requests
  to service_role;
revoke all on public.star_wallets, public.star_ledger, public.star_products, public.cosmetics,
              public.user_cosmetics, public.profile_tags, public.user_entitlements,
              public.payments, public.stripe_events, public.gifts, public.payout_requests
  from anon;
-- The wallet and the ledger are the two tables a client must never touch, even
-- by accident: no INSERT/UPDATE/DELETE grant exists for any client role.
revoke all on public.star_wallets, public.star_ledger from public, anon, authenticated;
grant select on public.star_wallets, public.star_ledger to authenticated;
revoke all on public.stripe_events from public, anon, authenticated;

grant execute on function
  public.wallet_summary(),
  public.star_ledger_list(integer),
  public.store_catalog(),
  public.cosmetic_buy(text),
  public.cosmetic_equip(uuid, boolean),
  public.mint_tag(text, jsonb, uuid, text, integer),
  public.tag_update(uuid, text, jsonb, uuid, text, integer, boolean),
  public.tag_delete(uuid),
  public.profile_identity(uuid),
  public.gift_send(uuid, integer, text, uuid, uuid, uuid, uuid, text, boolean),
  public.gifts_received(integer),
  public.payout_request(integer, text),
  public.payout_requests_list(),
  public.payment_list(integer),
  public.payment_attach_session(uuid, text)
to authenticated;

-- Value-creating functions: service_role only. Revoked from every client role
-- on purpose, because these are the functions that make money appear.
revoke execute on function app.stars_credit(uuid, bigint, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function app.stars_debit(uuid, bigint, text, text, text, jsonb)  from public, anon, authenticated;
revoke execute on function public.payment_settle(jsonb) from public, anon, authenticated;
revoke execute on function public.payment_create_pending(uuid, text, text, integer, jsonb) from public, anon, authenticated;
revoke execute on function public.payment_mark_failed(text, text) from public, anon, authenticated;

grant execute on function app.stars_credit(uuid, bigint, text, text, text, jsonb) to service_role;
grant execute on function app.stars_debit(uuid, bigint, text, text, text, jsonb)  to service_role;
grant execute on function public.payment_settle(jsonb) to service_role;
grant execute on function public.payment_create_pending(uuid, text, text, integer, jsonb) to service_role;
grant execute on function public.payment_mark_failed(text, text) to service_role;

comment on function public.wallet_summary() is
  'Balance + lifetime in/out + gift earnings + remaining tag credits, for the wallet screen.';

commit;
