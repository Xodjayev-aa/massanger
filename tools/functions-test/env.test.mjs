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
  ALLOWED_ORIGINS: 'https://messengerx-uz.vercel.app',
};

const previousDeno = globalThis.Deno;
let current = production;
globalThis.Deno = { env: { get: (key) => current[key] } };
after(() => { globalThis.Deno = previousDeno; });

describe('production edge function configuration', () => {
  it('accepts an exact HTTPS web origin and sealed link credentials', () => {
    current = production;
    const env = readEnv();
    assert.deepEqual(env.allowedOrigins, ['https://messengerx-uz.vercel.app']);
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
