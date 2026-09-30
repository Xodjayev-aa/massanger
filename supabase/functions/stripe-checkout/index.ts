/**
 * stripe-checkout — the only way real money enters MessengerX.
 *
 * Stars, the `tag.custom` unlock and the supporter subscription are all bought
 * through Card Checkout. The function is a two-action API:
 *
 *   status → `{ configured, mode }`, answered before any configuration gate so
 *            the app can hide the top-up button on a deployment without keys
 *   create → resolve the product server-side → mint a Checkout Session → write
 *            the `created` payment row → return the hosted page URL
 *
 * The client never sends a price. `sku` is looked up in `star_products`, and the
 * amount, the currency, the stars granted and the entitlements all come from
 * that row — a client that tampered with the request could only pick a different
 * listed product. The user id travels in the session metadata, which is what the
 * webhook trusts when it settles.
 *
 * `sync` is the reconciliation path for a deployment whose webhook cannot be
 * reached (local development, or an endpoint that was down): the app polls this
 * action with the session id, the function asks Stripe what happened, and a paid
 * session is settled through exactly the same idempotent RPC the webhook uses.
 */

import { type Env, readEnv } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import {
  bearerToken,
  clientIp,
  corsHeaders,
  expectString,
  ok,
  readJsonBody,
  withEnvelope,
} from '../_shared/http.ts';
import { type AdminClient, adminClient, requireUser, rpc, userClient } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { HttpError } from '../_shared/types.ts';
import { createCheckoutSession, getCheckoutSession, type StripeSession } from '../_shared/stripe.ts';

const FUNCTION_NAME = 'stripe-checkout';
const MAX_BODY = 4 * 1024;

/** Products a person may buy with a card. `boost` is deliberately absent. */
const PURCHASABLE = new Set(['stars', 'subscription', 'tag_mint']);

type RequestBody = {
  action?: 'status' | 'create' | 'sync';
  /** create: a listed `star_products.sku`. */
  sku?: string | null;
  /** create: where Stripe returns the browser. Must be an allowed origin. */
  successUrl?: string | null;
  cancelUrl?: string | null;
  /** create: client-chosen uuid so a double-tap cannot mint two sessions. */
  requestId?: string | null;
  /** sync: the Checkout Session to reconcile. */
  sessionId?: string | null;
};

const isConfigured = (env: Env): boolean =>
  env.stripeSecretKey !== null && env.stripeWebhookSecret !== null;

/** Live vs test, derived from the key itself — useful and not a secret. */
const mode = (env: Env): 'live' | 'test' | null =>
  env.stripeSecretKey === null ? null : env.stripeSecretKey.startsWith('sk_live_') ? 'live' : 'test';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Checkout has to come back somewhere. Only origins this deployment already
 * trusts are accepted, which keeps a stolen session from turning our payment
 * page into somebody's open redirect.
 */
function assertReturnUrl(env: Env, raw: string, field: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HttpError('bad_request', `${field} must be an absolute URL`);
  }
  const allowed = new Set(env.stripeReturnOrigins.filter((origin) => origin !== '*'));
  if (env.stripeReturnOrigins.includes('*')) {
    for (const origin of env.allowedOrigins) if (origin !== '*') allowed.add(origin);
  }
  if (allowed.size > 0 && !allowed.has(url.origin)) {
    throw new HttpError('forbidden', `${field} points at an origin this deployment does not allow`);
  }
  if (env.environment !== 'development' && env.environment !== 'local' && url.protocol !== 'https:') {
    throw new HttpError('bad_request', `${field} must use HTTPS`);
  }
  return url.toString();
}

/**
 * Deep-link the app opens after paying. It is built from the first configured
 * return origin — never from the request — so a caller cannot point the payment
 * page at a host of their choosing.
 */
const appReturn = (env: Env, path: string, status: string): string => {
  const base = env.stripeReturnOrigins[0] ?? env.allowedOrigins.find((origin) => origin !== '*') ?? '';
  return `${base.replace(/\/+$/, '')}${path}?checkout=${status}`;
};

type ProductRow = {
  sku: string;
  kind: string;
  title: string;
  description: string | null;
  price_cents: number;
  currency: string;
  stars: number;
  entitlements: Record<string, unknown> | null;
  is_active: boolean;
};

async function loadProduct(client: AdminClient, sku: string): Promise<ProductRow> {
  const { data, error } = await client
    .from('star_products')
    .select('sku, kind, title, description, price_cents, currency, stars, entitlements, is_active')
    .eq('sku', sku)
    .maybeSingle();
  if (error) throw new HttpError('upstream_error', 'could not read the product catalog');
  const product = data as ProductRow | null;
  if (!product || !product.is_active) {
    throw new HttpError('bad_request', 'that product does not exist');
  }
  if (!PURCHASABLE.has(product.kind)) {
    throw new HttpError('bad_request', 'that product cannot be bought with a card');
  }
  if (product.price_cents <= 0) {
    // A free product is a grant, not a payment; refusing keeps the ledger clean.
    throw new HttpError('bad_request', 'that product has no price');
  }
  return product;
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

    const body = await readJsonBody<RequestBody>(req, MAX_BODY);
    const action = body.action ?? 'status';

    // Answered first: "can this deployment take money?" must work everywhere.
    if (action === 'status') {
      return ok({ configured: isConfigured(env), mode: mode(env), functions: 'supabase-edge' }, cors);
    }

    const token = bearerToken(req);
    const caller = await requireUser(env, token);
    const client = userClient(env, token!);

    if (!isConfigured(env)) {
      throw new HttpError('misconfigured', 'payments are not configured on this deployment', {
        status: 500,
      });
    }

    enforce(`stripe-${action}:uid`, caller.uid, action === 'sync' ? 60 : 10, 60_000);
    enforce('stripe:ip', clientIp(req) ?? 'unknown', 60);

    if (action === 'create') {
      const sku = expectString(body.sku, 'sku', { min: 3, max: 48 })!;
      if (!/^[a-z0-9._-]{3,48}$/.test(sku)) {
        throw new HttpError('bad_request', 'sku must look like a product identifier');
      }
      const requestId = body.requestId == null ? null : String(body.requestId);
      if (requestId !== null && !UUID_RE.test(requestId)) {
        throw new HttpError('bad_request', 'requestId must be a uuid');
      }

      const product = await loadProduct(adminClient(env), sku);
      const successUrl = body.successUrl
        ? assertReturnUrl(env, String(body.successUrl), 'successUrl')
        : appReturn(env, '/wallet', 'success');
      const cancelUrl = body.cancelUrl
        ? assertReturnUrl(env, String(body.cancelUrl), 'cancelUrl')
        : appReturn(env, '/store', 'cancelled');

      const session = await createCheckoutSession({
        secretKey: env.stripeSecretKey!,
        sku: product.sku,
        name: product.title,
        description: product.description,
        amountCents: product.price_cents,
        currency: product.currency,
        userId: caller.uid,
        successUrl,
        cancelUrl,
        // Retrying the same request reuses the same Stripe session rather than
        // charging twice; a fresh purchase must send a fresh requestId.
        idempotencyKey: requestId ? `checkout:${caller.uid}:${requestId}` : null,
      });

      // The `created` row is written after Stripe answers because the session id
      // is the payment row's natural key. Settlement does not depend on it: the
      // webhook upserts by session id and stamps the same row.
      let paymentId: string | null = null;
      if (session.url) {
        try {
          // Service role, because writing a payment row is not a client
          // privilege: `payment_create_pending` is revoked from every user
          // role, and the uid it receives is the authenticated caller's.
          paymentId = await rpc<string>(adminClient(env), 'payment_create_pending', {
            p_user_id: caller.uid,
            p_sku: product.sku,
            p_session_id: session.id,
            p_amount_cents: product.price_cents,
            p_metadata: { session_url: session.url, mode: mode(env) },
          });
        } catch (error) {
          // A missing pending row is recoverable (the webhook inserts it); an
          // unusable checkout page is not, so only the latter fails the call.
          log.warn('pending payment row was not written', {
            message: (error as Error).message,
            session: session.id,
          });
        }
      }

      log.info('checkout session minted', {
        uid: caller.uid,
        sku: product.sku,
        session: session.id,
        mode: mode(env),
      });

      return ok({
        configured: true,
        mode: mode(env),
        paymentId,
        sessionId: session.id,
        url: session.url,
        amountCents: product.price_cents,
        currency: product.currency,
        stars: product.stars,
      }, cors);
    }

    if (action === 'sync') {
      const sessionId = expectString(body.sessionId, 'sessionId', { min: 8, max: 200 })!;
      // Only the person who owns the payment row may reconcile it.
      const { data, error } = await client
        .from('payments')
        .select('id, status, sku, amount_cents')
        .eq('provider_session_id', sessionId)
        .maybeSingle();
      if (error) throw new HttpError('upstream_error', 'could not read the payment');
      if (!data) throw new HttpError('forbidden', 'that session does not belong to you');

      const session = await getCheckoutSession({ secretKey: env.stripeSecretKey!, sessionId });
      if (session.status === 'paid') {
        // The very same RPC the webhook calls, with the very same shape of
        // event — including its idempotency on event and session id.
        const settled = await rpc<Record<string, unknown>>(
          adminClient(env),
          'payment_settle',
          {
            p_event: {
              // Prefixed, so a reconciliation can never collide with (or be
              // mistaken for) a real Stripe event id.
              id: `sync_${session.id}`,
              type: 'checkout.session.completed',
              data: {
                object: stripeSessionToEventObject(session, {
                  user_id: caller.uid,
                  sku: data.sku as string,
                }),
              },
            },
          },
        );
        return ok({ reconciled: true, sessionId: session.id, settlement: settled }, cors);
      }

      return ok({
        reconciled: false,
        sessionId: session.id,
        status: session.status ?? 'unknown',
      }, cors);
    }

    throw new HttpError('bad_request', "action must be 'status', 'create' or 'sync'");
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins));
  return wrapped(request);
}

/**
 * Reshapes a retrieved session into the subset of Stripe's event payload that
 * `payment_settle` reads. Amount and metadata always come from Stripe.
 */
export function stripeSessionToEventObject(
  session: StripeSession,
  fallback: { user_id: string; sku: string },
): Record<string, unknown> {
  return {
    id: session.id,
    object: 'checkout.session',
    payment_status: 'paid',
    amount_total: session.amount_total,
    currency: session.currency,
    payment_intent: session.payment_intent,
    client_reference_id: fallback.user_id,
    // Stripe's own metadata wins; the fallback only covers a session that was
    // created outside this function.
    metadata: { user_id: fallback.user_id, sku: fallback.sku, ...(session.metadata ?? {}) },
  };
}

Deno.serve(handle);
