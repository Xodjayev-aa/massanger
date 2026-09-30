-- 00027 — refunds and disputes.
--
-- Money that came in can go back out, and when it does the value that was
-- granted for it has to come off the books too. This is the half of the payment
-- pipeline most implementations skip: `checkout.session.completed` credits, and
-- nothing ever debits a chargeback, so a disputed purchase leaves the buyer with
-- the stars and the platform with the loss.
--
-- Like `payment_settle`, this is service_role-only and idempotent on the Stripe
-- event id, so a redelivered `charge.refunded` cannot claw back twice.

-- ---------------------------------------------------------------------------
-- 1. What a refund takes back.
-- ---------------------------------------------------------------------------
create or replace function public.payment_refund(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event_id  text := p_event ->> 'id';
  v_type      text := p_event ->> 'type';
  v_object    jsonb := coalesce(p_event -> 'data' -> 'object', '{}'::jsonb);
  v_intent    text := nullif(v_object ->> 'payment_intent', '');
  v_charge    text := case when v_object ->> 'object' = 'charge'
                           then nullif(v_object ->> 'id', '')
                           else nullif(v_object ->> 'charge', '') end;
  v_meta      jsonb := coalesce(v_object -> 'metadata', '{}'::jsonb);
  v_payment   public.payments%rowtype;
  v_product   public.star_products%rowtype;
  v_balance   bigint := 0;
  v_take      bigint := 0;
  v_shortfall bigint := 0;
  v_mints     integer := 0;
begin
  if v_event_id is null or v_type is null then
    raise exception 'not a Stripe event' using errcode = '22023';
  end if;

  insert into public.stripe_events (id, type, payload)
  values (v_event_id, v_type, p_event)
  on conflict (id) do nothing;
  if not found then
    return jsonb_build_object('duplicate', true, 'event', v_event_id);
  end if;

  if v_type not in ('charge.refunded', 'charge.dispute.created') then
    update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;
    return jsonb_build_object('ignored', true, 'type', v_type);
  end if;

  -- The charge tells us the PaymentIntent; the intent is what we stored as
  -- provider_payment_id. Metadata is the fallback for a session created outside
  -- this deployment (a manual charge, or the Stripe dashboard).
  select * into v_payment
    from public.payments p
   where (v_intent is not null and p.provider_payment_id = v_intent)
      or (v_charge is not null and p.provider_payment_id = v_charge)
      or (v_meta ->> 'payment_id' is not null and p.id = (v_meta ->> 'payment_id')::uuid)
      or (v_meta ->> 'session_id' is not null and p.provider_session_id = v_meta ->> 'session_id')
   order by p.paid_at desc nulls last
   limit 1;

  if not found then
    -- A refund for something we never recorded: acknowledge rather than fail so
    -- Stripe stops retrying. The raw event stays in `stripe_events`, which is
    -- the operator's trail (docs/runbook.md) — no invented user to notify.
    update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;
    return jsonb_build_object('matched', false, 'event', v_event_id, 'payment_intent', v_intent);
  end if;

  if v_payment.status = 'refunded' then
    update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;
    return jsonb_build_object('duplicate', true, 'payment', v_payment.id);
  end if;

  select * into v_product from public.star_products p where p.sku = v_payment.sku;

  update public.payments p
     set status = 'refunded',
         metadata = p.metadata || jsonb_build_object(
           'refund', jsonb_build_object('event', v_event_id, 'type', v_type,
                                        'amount_cents', coalesce((v_object ->> 'amount_refunded')::int,
                                                                 (v_object ->> 'amount')::int)),
           'refunded_at', clock_timestamp()),
         updated_at = clock_timestamp()
   where p.id = v_payment.id;

  -- Stars first. A balance that has already been spent cannot go negative, so
  -- whatever could not be taken is recorded instead of silently forgotten.
  select w.balance into v_balance from public.star_wallets w where w.user_id = v_payment.user_id;
  v_balance := coalesce(v_balance, 0);
  if v_payment.stars_granted > 0 then
    v_take := least(v_payment.stars_granted::bigint, v_balance);
    v_shortfall := v_payment.stars_granted - v_take;
    if v_take > 0 then
      perform app.stars_debit(v_payment.user_id, v_take, 'refund', 'payment', v_payment.id::text,
                              jsonb_build_object('sku', v_payment.sku, 'event', v_event_id,
                                                 'shortfall', v_shortfall));
    end if;
  end if;

  -- Then the entitlements the purchase created.
  if v_product.sku is not null and coalesce((v_product.entitlements ->> 'tag_mint')::int, 0) > 0 then
    v_mints := (v_product.entitlements ->> 'tag_mint')::int;
    update public.user_entitlements e
       set remaining = greatest(0, e.remaining - v_mints), updated_at = clock_timestamp()
     where e.user_id = v_payment.user_id and e.entitlement = 'tag_mint';
  end if;

  if v_product.kind = 'subscription' then
    update public.user_entitlements e
       set remaining = 0, expires_at = clock_timestamp(), updated_at = clock_timestamp()
     where e.user_id = v_payment.user_id and e.entitlement = 'supporter';
    delete from public.user_cosmetics uc
     using public.cosmetics c
     where c.id = uc.cosmetic_id and c.slug = 'badge.supporter'
       and uc.user_id = v_payment.user_id and uc.source = 'subscription';
  end if;

  insert into public.notifications (user_id, kind, payload)
  values (v_payment.user_id, 'stars',
          jsonb_build_object('refunded', true, 'sku', v_payment.sku,
                             'stars_reclaimed', v_take, 'shortfall', v_shortfall,
                             'amount_cents', v_payment.amount_cents));

  update public.stripe_events set processed_at = clock_timestamp() where id = v_event_id;

  return jsonb_build_object('ok', true, 'payment', v_payment.id, 'status', 'refunded',
                            'stars_reclaimed', v_take, 'shortfall', v_shortfall,
                            'mints_revoked', v_mints);
end;
$$;

comment on function public.payment_refund(jsonb) is
  'Reverses a refunded or disputed payment: marks the row, claws back unspent stars, revokes the entitlements it granted. Idempotent on the event id.';

-- ---------------------------------------------------------------------------
-- 2. Grants: service_role only, exactly like settlement.
-- ---------------------------------------------------------------------------
revoke execute on function public.payment_refund(jsonb) from public, anon, authenticated;
grant execute on function public.payment_refund(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. The operator's view of a refund: which payments have been reversed, and
--    whether anything could not be reclaimed. Read-only, own rows only.
-- ---------------------------------------------------------------------------
create or replace function public.payment_refund_list(p_limit integer default 30)
returns table (
  id            uuid,
  sku           text,
  amount_cents  integer,
  currency      text,
  stars_granted integer,
  refunded_at   timestamptz,
  refund_detail jsonb
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select p.id, p.sku, p.amount_cents, p.currency, p.stars_granted,
         nullif(p.metadata ->> 'refunded_at', '')::timestamptz,
         coalesce(p.metadata -> 'refund', '{}'::jsonb)
    from public.payments p
   where p.user_id = app.current_uid() and p.status = 'refunded'
   order by p.updated_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

grant execute on function public.payment_refund_list(integer) to authenticated;

comment on function public.payment_refund_list(integer) is
  'A buyer''s own reversed payments, with what was reclaimed — the wallet screen shows this so a chargeback is never a silent balance change.';

commit;
