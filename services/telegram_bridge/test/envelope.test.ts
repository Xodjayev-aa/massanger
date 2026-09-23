/**
 * The credential envelope is the only thing standing between a Postgres row and
 * somebody's Telegram login code, and it is implemented twice on purpose (Deno
 * edge function, Node worker). These tests pin the interop: a payload sealed by a
 * WebCrypto implementation that mirrors `_shared/crypto.ts` must open here, and
 * the reverse.
 */

import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { describe, it } from 'node:test';

import {
  aesKeyFromSecret,
  buildSignatureHeader,
  openEnvelope,
  sealEnvelope,
  verifySignatureHeader,
} from '../src/util/envelope.js';
import { HEX_KEY } from './helpers.js';

// ── the Deno side, re-implemented with WebCrypto exactly as _shared/crypto.ts ──

const encoder = new TextEncoder();
const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const fromB64url = (value: string): Uint8Array => {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
};

type WebKey = Awaited<ReturnType<typeof crypto.subtle.importKey>>;

async function webCryptoKey(secret: string): Promise<WebKey> {
  const trimmed = secret.trim();
  let bytes: Uint8Array;
  if (/^[0-9a-f]{64}$/i.test(trimmed)) {
    bytes = new Uint8Array((trimmed.match(/.{2}/g) ?? []).map((pair) => Number.parseInt(pair, 16)));
  } else {
    try {
      bytes = fromB64url(trimmed.replace(/\s/g, ''));
    } catch {
      bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(trimmed)));
    }
  }
  if (bytes.byteLength < 32) bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return crypto.subtle.importKey('raw', bytes.slice(0, 32), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

async function webCryptoSeal(payload: Record<string, unknown>, secret: string) {
  const key = await webCryptoKey(secret);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, tagLength: 128 }, key, encoder.encode(JSON.stringify(payload)));
  return { alg: 'A256GCM', iv: b64url(iv), ct: b64url(new Uint8Array(cipher)) };
}

async function webCryptoOpen(envelope: { iv: string; ct: string }, secret: string): Promise<unknown> {
  const key = await webCryptoKey(secret);
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: fromB64url(envelope.iv), tagLength: 128 },
    key,
    fromB64url(envelope.ct),
  );
  return JSON.parse(new TextDecoder().decode(plain));
}

describe('credential envelopes', () => {
  const payloads: Array<[string, Record<string, unknown>]> = [
    ['a phone number', { phone: '+998901112233' }],
    ['a login code', { code: '48291' }],
    ['a 2FA password with symbols', { password: 'pässwörd—é "quoted" \\ slash' }],
    ['unicode names', { reason: 'базируйся ✓ 日本語' }],
  ];

  for (const [label, payload] of payloads) {
    it(`opens a ${label} envelope sealed by the edge function`, async () => {
      const sealed = await webCryptoSeal(payload, HEX_KEY);
      assert.deepEqual(openEnvelope(sealed, aesKeyFromSecret(HEX_KEY)), payload);
    });

    it(`produces a ${label} envelope the edge function can open`, async () => {
      const sealed = sealEnvelope(payload as never, aesKeyFromSecret(HEX_KEY));
      assert.equal(sealed.alg, 'A256GCM');
      assert.deepEqual(await webCryptoOpen(sealed as { iv: string; ct: string }, HEX_KEY), payload);
    });
  }

  it('derives the same key from a passphrase, hex, and base64url secret', async () => {
    for (const secret of ['correct horse battery staple', 'ab'.repeat(32), b64url(crypto.getRandomValues(new Uint8Array(32)))]) {
      const ours = aesKeyFromSecret(secret);
      // Indirect but airtight: data sealed with WebCrypto under the mirrored
      // derivation opens with our raw key bytes, and vice versa.
      const payload = { code: '12345' };
      const sealedByFunction = await webCryptoSeal(payload, secret);
      assert.deepEqual(openEnvelope(sealedByFunction, ours), payload);
      const sealedHere = sealEnvelope(payload as never, ours);
      assert.deepEqual(await webCryptoOpen(sealedHere as { iv: string; ct: string }, secret), payload);
    }
  });

  it('keeps the development plaintext envelope readable, but never the default', () => {
    const plain = sealEnvelope({ code: '12345' }, null);
    assert.equal(plain.alg, 'plain');
    assert.deepEqual(openEnvelope(plain, null), { code: '12345' });
    assert.deepEqual(openEnvelope({ alg: 'plain', data: { phone: '+1' } }, aesKeyFromSecret(HEX_KEY)), {
      phone: '+1',
    });
  });

  it('refuses to open sealed material without a key, or with the wrong one', () => {
    const sealed = sealEnvelope({ code: '12345' }, aesKeyFromSecret(HEX_KEY));
    assert.throws(() => openEnvelope(sealed, null), /SEAL_KEY is required/);
    assert.throws(() => openEnvelope(sealed, aesKeyFromSecret('ff'.repeat(32))), /(tag|auth|decrypt)/i);
  });

  it('rejects an unknown algorithm instead of guessing', () => {
    assert.throws(() => openEnvelope({ alg: 'A128CBC', iv: 'AAA', ct: 'BBB' }, aesKeyFromSecret(HEX_KEY)), /unsupported envelope algorithm/);
    assert.deepEqual(openEnvelope(null, aesKeyFromSecret(HEX_KEY)), {});
    assert.deepEqual(openEnvelope(undefined, aesKeyFromSecret(HEX_KEY)), {});
  });

  it('never leaks the plaintext into the ciphertext fields', () => {
    const sealed = sealEnvelope({ code: '48291', phone: '+998901112233' }, aesKeyFromSecret(HEX_KEY)) as {
      iv: string;
      ct: string;
    };
    const haystack = `${sealed.iv}${sealed.ct}`;
    assert.ok(!haystack.includes('48291'));
    assert.ok(!haystack.includes('998901112233'));
  });
});

describe('bridge request signing', () => {
  const secret = 'bridge-hmac-secret-value';
  const body = JSON.stringify({ events: [{ dedupe_key: 'x' }] });

  it('signs the exact `${ts}.${body}` preimage the edge function expects', () => {
    const ts = 1_700_000_000;
    const { header } = buildSignatureHeader(secret, body, ts);
    const signature = header.split(',')[1]?.split('=')[1];
    const recomputed = createHmac('sha256', secret).update(`${ts}.${body}`).digest('hex');
    assert.equal(signature, recomputed);
  });

  it('accepts a good signature and rejects a tampered body', () => {
    const { header, ts } = buildSignatureHeader(secret, body);
    assert.equal(verifySignatureHeader(secret, header, body, 60, ts), true);
    assert.equal(verifySignatureHeader(secret, header, body + ' ', 60, ts), false);
    assert.equal(verifySignatureHeader('other-secret', header, body, 60, ts), false);
  });

  it('refuses a signature outside the replay window', () => {
    const ts = 1_700_000_000;
    const { header } = buildSignatureHeader(secret, body, ts);
    assert.equal(verifySignatureHeader(secret, header, body, 60, ts + 61), false, 'too old');
    assert.equal(verifySignatureHeader(secret, header, body, 60, ts - 61), false, 'from the future');
    assert.equal(verifySignatureHeader(secret, header, body, 60, ts + 30), true);
  });

  it('tolerates malformed headers', () => {
    assert.equal(verifySignatureHeader(secret, null, body, 60), false);
    assert.equal(verifySignatureHeader(secret, 'garbage', body, 60), false);
    assert.equal(verifySignatureHeader(secret, 't=abc,v1=def', body, 60), false);
    assert.equal(verifySignatureHeader(secret, 't=1,v1=zz', body, 60), false);
  });
});
