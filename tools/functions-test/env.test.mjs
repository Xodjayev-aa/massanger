import assert from 'node:assert/strict';
import { after, describe, it } from 'node:test';

import { readEnv } from '../../supabase/functions/_shared/env.ts';

const production = {
  MESSENGERX_ENV: 'production',
  SUPABASE_URL: 'https://project.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'service-role-test-only',
  SUPABASE_ANON_KEY: 'public-test-key',
  SEAL_KEY: 'a0'.repeat(32),
  BRIDGE_TOKEN: 'a'.repeat(40),
  BRIDGE_HMAC_SECRET: 'b'.repeat(40),
  ALLOWED_ORIGINS: 'https://officialmessengerx.vercel.app',
};

const previousDeno = globalThis.Deno;
let current = production;
globalThis.Deno = { env: { get: (key) => current[key] } };
after(() => { globalThis.Deno = previousDeno; });

describe('production edge function configuration', () => {
  it('accepts an exact HTTPS web origin and sealed link credentials', () => {
    current = production;
    const env = readEnv();
    assert.deepEqual(env.allowedOrigins, ['https://officialmessengerx.vercel.app']);
    assert.equal(env.sealKey, production.SEAL_KEY);
  });

  it('refuses the insecure development CORS default and arbitrary wildcard origins', () => {
    for (const allowed of [undefined, '*', 'http://example.com', 'https://example.com/path']) {
      current = { ...production, ALLOWED_ORIGINS: allowed };
      assert.throws(readEnv, /ALLOWED_ORIGINS/);
    }
  });

  it('refuses plaintext Telegram codes and an unsigned bridge in production', () => {
    for (const secret of ['SEAL_KEY', 'BRIDGE_TOKEN', 'BRIDGE_HMAC_SECRET']) {
      current = { ...production, [secret]: undefined };
      assert.throws(readEnv, /SEAL_KEY, BRIDGE_TOKEN and BRIDGE_HMAC_SECRET/);
    }
    current = { ...production, BRIDGE_TOKEN: 'guessable' };
    assert.throws(readEnv, /BRIDGE_TOKEN/);
  });

  it('refuses a plaintext production Supabase API origin', () => {
    current = { ...production, SUPABASE_URL: 'http://127.0.0.1:54321' };
    assert.throws(readEnv, /HTTPS/);
  });

  it('fails closed on misspelled environments and hardens hosted staging', () => {
    current = { ...production, MESSENGERX_ENV: 'prod' };
    assert.throws(readEnv, /MESSENGERX_ENV/);
    current = { ...production, MESSENGERX_ENV: 'staging', SEAL_KEY: undefined };
    assert.throws(readEnv, /staging requires SEAL_KEY/);
  });

  it('allows explicit local development without hosted secrets', () => {
    current = {
      MESSENGERX_ENV: 'development',
      SUPABASE_SERVICE_ROLE_KEY: 'local-service-key',
      SUPABASE_ANON_KEY: 'local-anon-key',
    };
    assert.equal(readEnv().sealKey, null);
  });
});

describe('browser push configuration', () => {
  const vapidPublic = 'B'.repeat(87);
  const vapidPrivate = 'C'.repeat(43);
  const webPush = {
    WEB_PUSH_VAPID_PUBLIC_KEY: vapidPublic,
    WEB_PUSH_VAPID_PRIVATE_KEY: vapidPrivate,
    WEB_PUSH_VAPID_SUBJECT: 'mailto:ops@example.com',
    WEB_PUSH_SWEEP_TOKEN: 'd'.repeat(40),
  };

  it('is optional: an unconfigured deployment reports nulls instead of failing', () => {
    current = production;
    const env = readEnv();
    assert.equal(env.webPushVapidPublicKey, null);
    assert.equal(env.webPushSweepToken, null);
    assert.deepEqual(env.webPushEndpointHosts, []);
  });

  it('accepts a complete VAPID identity and an extra endpoint host', () => {
    current = { ...production, ...webPush, WEB_PUSH_ENDPOINT_HOSTS: 'push.example.com, *.push.example.net' };
    const env = readEnv();
    assert.equal(env.webPushVapidPublicKey, vapidPublic);
    assert.equal(env.webPushVapidSubject, 'mailto:ops@example.com');
    assert.deepEqual(env.webPushEndpointHosts, ['push.example.com', '*.push.example.net']);
  });

  it('refuses half a key pair rather than delivering nothing quietly', () => {
    for (const missing of ['WEB_PUSH_VAPID_PUBLIC_KEY', 'WEB_PUSH_VAPID_PRIVATE_KEY', 'WEB_PUSH_VAPID_SUBJECT']) {
      current = { ...production, ...webPush, [missing]: undefined };
      assert.throws(readEnv, /must be set together/, `${missing} alone should fail`);
    }
    // ...and refuses it in development too, so a local stack cannot pass a
    // configuration that production rejects.
    current = { ...production, MESSENGERX_ENV: 'development', WEB_PUSH_VAPID_PUBLIC_KEY: vapidPublic };
    assert.throws(readEnv, /must be set together/);
  });

  it('requires a contact URI, and only mailto: or https:', () => {
    for (const subject of ['ops@example.com', '', 'tel:+15551234']) {
      current = { ...production, ...webPush, WEB_PUSH_VAPID_SUBJECT: subject };
      assert.throws(readEnv, /WEB_PUSH_VAPID_SUBJECT|must be set together/, `subject ${subject}`);
    }
    current = { ...production, ...webPush, WEB_PUSH_VAPID_SUBJECT: 'https://messengerx.example/push' };
    assert.equal(readEnv().webPushVapidSubject, 'https://messengerx.example/push');
  });

  it('refuses a malformed key or a guessable sweep token', () => {
    current = { ...production, ...webPush, WEB_PUSH_VAPID_PRIVATE_KEY: 'too-short' };
    assert.throws(readEnv, /WEB_PUSH_VAPID_PRIVATE_KEY/);
    current = { ...production, ...webPush, WEB_PUSH_VAPID_PUBLIC_KEY: 'not base64url!' };
    assert.throws(readEnv, /WEB_PUSH_VAPID_PUBLIC_KEY/);
    current = { ...production, ...webPush, WEB_PUSH_SWEEP_TOKEN: 'guessable' };
    assert.throws(readEnv, /WEB_PUSH_SWEEP_TOKEN/);
    // A JWK is also accepted as the private key.
    current = { ...production, ...webPush, WEB_PUSH_VAPID_PRIVATE_KEY: '{"kty":"EC","crv":"P-256","d":"x"}' };
    assert.equal(readEnv().webPushVapidPrivateKey.startsWith('{'), true);
    current = { ...production, ...webPush, WEB_PUSH_ENDPOINT_HOSTS: 'https://push.example.com' };
    assert.throws(readEnv, /WEB_PUSH_ENDPOINT_HOSTS/);
  });
});
