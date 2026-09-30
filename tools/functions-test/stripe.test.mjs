import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { hmacSign } from '../../supabase/functions/_shared/crypto.ts';
import {
  createCheckoutSession,
  getCheckoutSession,
  stripeForm,
  verifyStripeSignature,
} from '../../supabase/functions/_shared/stripe.ts';

const SECRET = 'whsec_test_0123456789abcdef';

/** Builds a signature header the way Stripe does: `t=…,v1=HMAC(t.payload)`. */
async function signature(payload, { secret = SECRET, timestamp = Math.floor(Date.now() / 1000) } = {}) {
  const digest = await hmacSign(secret, `${timestamp}.${payload}`);
  return `t=${timestamp},v1=${digest}`;
}

const okResponse = (body, init = {}) =>
  new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' }, ...init });

describe('stripe webhook signatures', () => {
  it('accepts a fresh signature over the exact payload', async () => {
    const payload = JSON.stringify({ id: 'evt_1', type: 'checkout.session.completed' });
    const verdict = await verifyStripeSignature({ payload, header: await signature(payload), secret: SECRET });
    assert.deepEqual(verdict, { ok: true });
  });

  it('rejects a payload that changed after signing', async () => {
    const payload = JSON.stringify({ id: 'evt_1', type: 'checkout.session.completed' });
    const header = await signature(payload);
    const tampered = JSON.stringify({ id: 'evt_1', type: 'checkout.session.completed', amount_total: 0 });
    const verdict = await verifyStripeSignature({ payload: tampered, header, secret: SECRET });
    assert.equal(verdict.ok, false);
    assert.match(verdict.reason, /no v1 digest matched/);
  });

  it('rejects a replay outside the tolerance window, in both directions', async () => {
    const payload = '{"id":"evt_2"}';
    for (const offset of [-3600, 3600]) {
      const header = await signature(payload, { timestamp: Math.floor(Date.now() / 1000) + offset });
      const verdict = await verifyStripeSignature({ payload, header, secret: SECRET });
      assert.equal(verdict.ok, false);
      assert.match(verdict.reason, /tolerance/);
    }
  });

  it('rejects a signature made with a different secret', async () => {
    const payload = '{"id":"evt_3"}';
    const header = await signature(payload, { secret: 'whsec_other' });
    const verdict = await verifyStripeSignature({ payload, header, secret: SECRET });
    assert.equal(verdict.ok, false);
  });

  it('explains a malformed header instead of throwing', async () => {
    for (const header of [null, '', 't=123', 'v1=abc', 'nonsense']) {
      const verdict = await verifyStripeSignature({ payload: '{}', header, secret: SECRET });
      assert.equal(verdict.ok, false);
      assert.equal(typeof verdict.reason, 'string');
    }
  });

  it('accepts Stripe’s rotation format: several v1 digests, one of them ours', async () => {
    const payload = '{"id":"evt_4"}';
    const good = await hmacSign(SECRET, `${Math.floor(Date.now() / 1000)}.${payload}`);
    const header = `t=${Math.floor(Date.now() / 1000)},v1=deadbeef,v1=${good}`;
    assert.deepEqual(await verifyStripeSignature({ payload, header, secret: SECRET }), { ok: true });
  });
});

describe('stripe request encoding', () => {
  it('flattens nested objects and arrays into Stripe’s bracket form', () => {
    const encoded = stripeForm({
      mode: 'payment',
      'payment_method_types[0]': 'card',
      metadata: { user_id: 'u1', sku: 'tag.custom' },
      line_items: [{ quantity: 1, price_data: { unit_amount: 249, currency: 'usd' } }],
      empty: undefined,
    });
    const params = new URLSearchParams(encoded);
    assert.equal(params.get('mode'), 'payment');
    assert.equal(params.get('payment_method_types[0]'), 'card');
    assert.equal(params.get('metadata[user_id]'), 'u1');
    assert.equal(params.get('metadata[sku]'), 'tag.custom');
    assert.equal(params.get('line_items[0][quantity]'), '1');
    assert.equal(params.get('line_items[0][price_data][unit_amount]'), '249');
    assert.equal(params.get('empty'), null);
  });

  it('posts a card-only session priced from the server-side product', async () => {
    let captured = null;
    const fetchImpl = async (url, init) => {
      captured = { url, init, body: new URLSearchParams(init.body) };
      return okResponse({ id: 'cs_test_1', url: 'https://checkout.stripe.com/c/pay/cs_test_1' });
    };

    const session = await createCheckoutSession({
      secretKey: 'sk_test_x',
      sku: 'tag.custom',
      name: 'Custom profile tag',
      description: 'One mintable tag',
      amountCents: 249,
      currency: 'usd',
      userId: 'user-1',
      successUrl: 'https://app.example.com/wallet?checkout=success',
      cancelUrl: 'https://app.example.com/store?checkout=cancelled',
      idempotencyKey: 'checkout:user-1:req-1',
      fetchImpl,
    });

    assert.equal(captured.url, 'https://api.stripe.com/v1/checkout/sessions');
    assert.equal(captured.init.method, 'POST');
    assert.equal(captured.init.headers.authorization, 'Bearer sk_test_x');
    assert.equal(captured.init.headers['idempotency-key'], 'checkout:user-1:req-1');
    assert.equal(captured.body.get('mode'), 'payment');
    assert.equal(captured.body.get('payment_method_types[0]'), 'card');
    assert.equal(captured.body.get('line_items[0][price_data][unit_amount]'), '249');
    assert.equal(captured.body.get('line_items[0][price_data][product_data][name]'), 'Custom profile tag');
    assert.equal(captured.body.get('metadata[user_id]'), 'user-1');
    assert.equal(captured.body.get('metadata[sku]'), 'tag.custom');
    assert.equal(captured.body.get('client_reference_id'), 'user-1');
    assert.equal(session.id, 'cs_test_1');
    assert.equal(session.url, 'https://checkout.stripe.com/c/pay/cs_test_1');
  });

  it('turns a Stripe rejection into an error, not a broken session', async () => {
    const fetchImpl = async () =>
      new Response(JSON.stringify({ error: { message: 'No such price' } }), {
        status: 400,
        headers: { 'content-type': 'application/json' },
      });
    await assert.rejects(
      () =>
        createCheckoutSession({
          secretKey: 'sk_test_x',
          sku: 'tag.custom',
          name: 'x',
          amountCents: 249,
          currency: 'usd',
          userId: 'u',
          successUrl: 'https://a.example.com/',
          cancelUrl: 'https://a.example.com/',
          fetchImpl,
        }),
      /No such price/,
    );
  });

  it('refuses a session response without an id', async () => {
    const fetchImpl = async () => okResponse({ url: 'https://checkout.stripe.com/x' });
    await assert.rejects(
      () =>
        createCheckoutSession({
          secretKey: 'sk_test_x',
          sku: 'tag.custom',
          name: 'x',
          amountCents: 249,
          currency: 'usd',
          userId: 'u',
          successUrl: 'https://a.example.com/',
          cancelUrl: 'https://a.example.com/',
          fetchImpl,
        }),
      /without an id/,
    );
  });
});

describe('stripe reconciliation lookups', () => {
  it('reads the payment status from a retrieved session', async () => {
    const fetchImpl = async (url, init) => {
      assert.match(url, /\/checkout\/sessions\/cs_test_9$/);
      assert.equal(init.headers.authorization, 'Bearer sk_test_x');
      return okResponse({
        id: 'cs_test_9',
        payment_status: 'paid',
        amount_total: 249,
        currency: 'usd',
        payment_intent: 'pi_9',
        metadata: { user_id: 'u1', sku: 'tag.custom' },
      });
    };
    const session = await getCheckoutSession({ secretKey: 'sk_test_x', sessionId: 'cs_test_9', fetchImpl });
    assert.equal(session.status, 'paid');
    assert.equal(session.payment_intent, 'pi_9');
    assert.equal(session.metadata.sku, 'tag.custom');
  });

  it('escapes the session id in the lookup path', async () => {
    let path = '';
    const fetchImpl = async (url) => {
      path = String(url);
      return okResponse({ id: 'x' });
    };
    await getCheckoutSession({ secretKey: 'sk_test_x', sessionId: 'cs/../evil', fetchImpl });
    assert.ok(!path.includes('../'), `unexpected path ${path}`);
  });
});
