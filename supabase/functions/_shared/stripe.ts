/**
 * Stripe: the two things this codebase needs, without the SDK.
 *
 * Edge functions run on Deno; pulling `stripe-node` in for one HTTP POST and one
 * HMAC check would add a dependency, a bundling step and a version to track for
 * no gain. What is here is exactly the surface the payment pipeline uses:
 *
 *   • `verifyStripeSignature` — constant-time verification of the
 *     `Stripe-Signature` header (t + v1), with a replay window.
 *   • `createCheckoutSession` — a form-encoded POST to `/v1/checkout/sessions`.
 *
 * Both are pure enough to unit-test with an injected `fetch`.
 */

import { hmacSign, timingSafeEqual } from './crypto.ts';
import { HttpError } from './types.ts';

export const STRIPE_API = 'https://api.stripe.com/v1';

/** How far in the past a webhook timestamp may be before it is a replay. */
export const DEFAULT_TOLERANCE_SECONDS = 300;

type SignatureHeader = { t: number | null; v1: string[] };

function parseSignatureHeader(header: string): SignatureHeader {
  const parts = header.split(',');
  const v1: string[] = [];
  let t: number | null = null;
  for (const part of parts) {
    const [key, value] = part.split('=');
    if (key === 't' && value) {
      const parsed = Number.parseInt(value, 10);
      if (Number.isFinite(parsed)) t = parsed;
    } else if (key === 'v1' && value) {
      v1.push(value.trim());
    }
  }
  return { t, v1 };
}

/**
 * Verifies a Stripe webhook signature. Returns why it failed rather than a bare
 * boolean so the caller can log something useful without leaking the secret.
 */
export async function verifyStripeSignature(options: {
  payload: string;
  header: string | null;
  secret: string;
  now?: number;
  toleranceSeconds?: number;
}): Promise<{ ok: true } | { ok: false; reason: string }> {
  const { payload, header, secret } = options;
  if (!header) return { ok: false, reason: 'missing Stripe-Signature header' };
  if (!secret) return { ok: false, reason: 'no webhook secret configured' };

  const { t, v1 } = parseSignatureHeader(header);
  if (t === null) return { ok: false, reason: 'signature has no timestamp' };
  if (v1.length === 0) return { ok: false, reason: 'signature has no v1 digest' };

  const now = options.now ?? Math.floor(Date.now() / 1000);
  const tolerance = options.toleranceSeconds ?? DEFAULT_TOLERANCE_SECONDS;
  // Guard against a future-dated header as well as a stale one.
  if (Math.abs(now - t) > tolerance) {
    return { ok: false, reason: `timestamp outside the ${tolerance}s tolerance` };
  }

  const expected = await hmacSign(secret, `${t}.${payload}`);
  const matched = v1.some((candidate) => timingSafeEqual(candidate, expected));
  return matched ? { ok: true } : { ok: false, reason: 'no v1 digest matched' };
}

/** Flattens nested params into Stripe's `a[b][0][c]=v` form encoding. */
export function stripeForm(params: Record<string, unknown>): string {
  const out = new URLSearchParams();
  const walk = (value: unknown, prefix: string): void => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) {
      value.forEach((entry, index) => walk(entry, `${prefix}[${index}]`));
      return;
    }
    if (typeof value === 'object') {
      for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
        walk(entry, prefix === '' ? key : `${prefix}[${key}]`);
      }
      return;
    }
    out.append(prefix, typeof value === 'boolean' ? String(value) : String(value));
  };
  for (const [key, value] of Object.entries(params)) walk(value, key);
  return out.toString();
}

export type StripeSession = {
  id: string;
  url: string | null;
  amount_total: number | null;
  currency: string | null;
  payment_intent: string | null;
  metadata: Record<string, string> | null;
  status?: string;
};

/**
 * Fetches one Checkout Session. This is the reconciliation path: when a webhook
 * cannot be delivered (a local stack, or an endpoint that was down past Stripe's
 * retry window) the app can ask Stripe directly rather than leaving a payment
 * stuck at `created`.
 */
export async function getCheckoutSession(options: {
  secretKey: string;
  sessionId: string;
  fetchImpl?: typeof fetch;
}): Promise<StripeSession> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const response = await fetchImpl(
    `${STRIPE_API}/checkout/sessions/${encodeURIComponent(options.sessionId)}`,
    { headers: { authorization: `Bearer ${options.secretKey}`, 'stripe-version': '2024-06-20' } },
  );
  const text = await response.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = text ? JSON.parse(text) as Record<string, unknown> : {};
  } catch {
    throw new HttpError('upstream_error', 'Stripe returned a non-JSON response', { status: 502 });
  }
  if (!response.ok) {
    const message = (parsed.error as { message?: string } | undefined)?.message ?? `HTTP ${response.status}`;
    throw new HttpError('upstream_error', `Stripe rejected the lookup: ${message}`, { status: 502 });
  }
  return {
    id: String(parsed.id ?? options.sessionId),
    url: typeof parsed.url === 'string' ? parsed.url : null,
    amount_total: typeof parsed.amount_total === 'number' ? parsed.amount_total : null,
    currency: typeof parsed.currency === 'string' ? parsed.currency : null,
    payment_intent: typeof parsed.payment_intent === 'string' ? parsed.payment_intent : null,
    metadata: (parsed.metadata as Record<string, string> | undefined) ?? null,
    status: typeof parsed.payment_status === 'string' ? parsed.payment_status : undefined,
  };
}

export type CreateSessionOptions = {
  secretKey: string;
  /** `star_products` row, already resolved by the caller. */
  sku: string;
  name: string;
  description?: string | null;
  amountCents: number;
  currency: string;
  /** Our payment row id, echoed back in metadata so settlement can find it. */
  paymentId?: string | null;
  userId: string;
  successUrl: string;
  cancelUrl: string;
  /** Injected in tests. */
  fetchImpl?: typeof fetch;
  /** Stripe occasionally needs a retry key to avoid double-charging. */
  idempotencyKey?: string | null;
};

/**
 * Creates a Checkout Session for one product and one user. The user id and sku
 * travel in metadata because that is what the webhook trusts — never anything
 * the browser sent.
 */
export async function createCheckoutSession(options: CreateSessionOptions): Promise<StripeSession> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const body = stripeForm({
    mode: 'payment',
    success_url: options.successUrl,
    cancel_url: options.cancelUrl,
    client_reference_id: options.userId,
    // Card only: the product is digital and priced in USD, and leaving the
    // wallet list implicit would surface payment methods this app cannot
    // reconcile.
    'payment_method_types[0]': 'card',
    'line_items[0][quantity]': 1,
    'line_items[0][price_data][currency]': options.currency.toLowerCase(),
    'line_items[0][price_data][product_data][name]': options.name,
    ...(options.description
      ? { 'line_items[0][price_data][product_data][description]': options.description }
      : {}),
    'line_items[0][price_data][unit_amount]': options.amountCents,
    metadata: {
      user_id: options.userId,
      sku: options.sku,
      ...(options.paymentId ? { payment_id: options.paymentId } : {}),
    },
  });

  const headers: Record<string, string> = {
    authorization: `Bearer ${options.secretKey}`,
    'content-type': 'application/x-www-form-urlencoded',
    'stripe-version': '2024-06-20',
  };
  if (options.idempotencyKey) headers['idempotency-key'] = options.idempotencyKey;

  let response: Response;
  try {
    response = await fetchImpl(`${STRIPE_API}/checkout/sessions`, { method: 'POST', headers, body });
  } catch (error) {
    throw new HttpError('upstream_error', `Stripe is unreachable: ${String(error)}`, { status: 502 });
  }

  const text = await response.text();
  let parsed: Record<string, unknown>;
  try {
    parsed = text ? JSON.parse(text) as Record<string, unknown> : {};
  } catch {
    throw new HttpError('upstream_error', 'Stripe returned a non-JSON response', { status: 502 });
  }

  if (!response.ok) {
    const message = (parsed.error as { message?: string } | undefined)?.message ?? `HTTP ${response.status}`;
    // 402/400 are the caller's problem (bad price, card declined later);
    // everything else is ours, and Stripe's own message is safe to log.
    throw new HttpError(response.status === 400 ? 'bad_request' : 'upstream_error',
      `Stripe rejected the session: ${message}`, { status: 502 });
  }

  const id = parsed.id;
  if (typeof id !== 'string') {
    throw new HttpError('upstream_error', 'Stripe returned a session without an id', { status: 502 });
  }
  return {
    id,
    url: typeof parsed.url === 'string' ? parsed.url : null,
    amount_total: typeof parsed.amount_total === 'number' ? parsed.amount_total : null,
    currency: typeof parsed.currency === 'string' ? parsed.currency : null,
    payment_intent: typeof parsed.payment_intent === 'string' ? parsed.payment_intent : null,
    metadata: (parsed.metadata as Record<string, string> | undefined) ?? null,
    status: typeof parsed.status === 'string' ? parsed.status : undefined,
  };
}
