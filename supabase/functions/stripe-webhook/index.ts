/**
 * stripe-webhook — Stripe's word is the only thing that moves money.
 *
 * The function is deliberately dumb, and that is the security model: it
 * verifies the signature, then hands the *raw event* to `payment_settle`, which
 * is idempotent on both the event id and the Checkout Session id. Everything
 * that decides value (which product, how many stars, which entitlement) lives in
 * the database, next to the money tables, not in TypeScript.
 *
 *   verify  → HMAC over `t.payload` with STRIPE_WEBHOOK_SECRET, 300s tolerance,
 *             constant-time compare, so a replayed or forged POST is a 400
 *   settle  → checkout.session.completed → stars + entitlements, once
 *   fail    → checkout.session.expired / async_payment_failed → row marked failed
 *   refund  → charge.refunded → stars clawed back, entitlements revoked
 *
 * `verify_jwt` is off for this function (see supabase/config.toml) because Stripe
 * has no Supabase session — the signature *is* the authentication. Nothing else
 * in this file trusts the request body.
 */

import { type Env, readEnv } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import { clientIp, corsHeaders, fail, ok, withEnvelope } from '../_shared/http.ts';
import { adminClient, rpc } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { HttpError } from '../_shared/types.ts';
import { verifyStripeSignature } from '../_shared/stripe.ts';

const FUNCTION_NAME = 'stripe-webhook';
/** Stripe caps a webhook payload well below this; anything larger is not Stripe. */
const MAX_BODY = 512 * 1024;

type StripeEvent = {
  id?: string;
  type?: string;
  data?: { object?: Record<string, unknown> };
};

type Handled = {
  handled: boolean;
  outcome?: unknown;
  type?: string;
};

/**
 * Maps an event onto the one database path that owns it. Unknown types are
 * acknowledged (200) rather than retried: Stripe redelivers anything that is not
 * 2xx, and a type this deployment does not handle is not a failure.
 */
async function dispatch(env: Env, event: StripeEvent): Promise<Handled> {
  const client = adminClient(env);
  const type = event.type ?? '';
  const object = event.data?.object ?? {};
  const sessionId = typeof object.id === 'string' ? object.id : null;

  switch (type) {
    case 'checkout.session.completed':
    case 'checkout.session.async_payment_succeeded':
      return { handled: true, type, outcome: await rpc(client, 'payment_settle', { p_event: event }) };

    case 'checkout.session.expired':
    case 'checkout.session.async_payment_failed':
      if (sessionId) {
        await rpc(client, 'payment_mark_failed', {
          p_session_id: sessionId,
          p_reason: type === 'checkout.session.expired' ? 'expired' : 'payment failed',
        });
      }
      return { handled: true, type };

    case 'charge.refunded':
    case 'charge.dispute.created':
      return { handled: true, type, outcome: await rpc(client, 'payment_refund', { p_event: event }) };

    default:
      return { handled: false, type };
  }
}

function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  // Bound here so the handler keeps a plain `Promise<Response>` signature for
  // `Deno.serve`, while every throw still becomes an envelope.
  const wrapped = withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') {
      throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);
    }
    if (env.stripeWebhookSecret === null) {
      throw new HttpError('misconfigured', 'payments are not configured on this deployment', {
        status: 500,
      });
    }

    // A payment endpoint must not be a load amplifier either; the limit is far
    // above Stripe's delivery rate for one account.
    enforce('stripe-webhook:ip', clientIp(req) ?? 'unknown', 600, 60_000);

    const raw = await req.text();
    if (raw.length > MAX_BODY) {
      throw new HttpError('payload_too_large', 'body too large to be a Stripe event');
    }

    const verdict = await verifyStripeSignature({
      payload: raw,
      header: req.headers.get('stripe-signature'),
      secret: env.stripeWebhookSecret,
    });
    if (!verdict.ok) {
      // 400, not 401: the signature is the authentication, and telling Stripe
      // "do not retry this" is exactly right for a forged or stale delivery.
      log.warn('rejected a webhook', { reason: verdict.reason });
      return fail('unauthorized', `signature rejected: ${verdict.reason}`, cors, { status: 400 });
    }

    let event: StripeEvent;
    try {
      event = JSON.parse(raw) as StripeEvent;
    } catch {
      throw new HttpError('bad_request', 'body must be valid JSON');
    }
    if (!event.id || !event.type) {
      throw new HttpError('bad_request', 'not a Stripe event');
    }

    const result = await dispatch(env, event);
    log.info('webhook processed', {
      event: event.id,
      type: event.type,
      handled: result.handled,
    });
    return ok({
      received: true,
      event: event.id,
      type: event.type,
      handled: result.handled,
      outcome: result.outcome ?? null,
    }, cors);
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins));
  return wrapped(request);
}

Deno.serve(handle);
