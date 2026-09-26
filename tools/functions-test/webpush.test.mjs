/**
 * Web Push crypto conformance.
 *
 * A chat notification is only worth anything if the push service can actually
 * decrypt it, and a wrong byte in the `aes128gcm` layout fails silently —
 * the browser shows nothing and the subscription just stops. So this suite does
 * not merely round-trip our own code:
 *
 *   • it decrypts the **RFC 8291 §5 published example** with an independent
 *     receiver implementation written here from the spec, and
 *   • it **re-encrypts that same example** with the RFC's fixed salt and sender
 *     key, then asserts the bytes are identical to the documented ciphertext,
 *     and
 *   • it checks a fresh subscriber's payload survives a full round trip.
 *
 * Node 22 has `crypto`, `atob`/`btoa` and `fetch` globally, so the Deno-side
 * module imports unchanged.
 */
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { HttpError } from '../../supabase/functions/_shared/types.ts';
import {
  MAX_PUSH_PAYLOAD_BYTES,
  buildPushRequest,
  encryptPushPayload,
  loadVapidKeys,
  parsePushEndpoint,
  vapidAuthorization,
} from '../../supabase/functions/_shared/webpush.ts';
import { b64urlDecode, b64urlEncode } from '../../supabase/functions/_shared/crypto.ts';
import { WAIT_MS_MAX, resolveSweepPlan } from '../../supabase/functions/_shared/push-sweep.ts';

const ab = (bytes) => {
  const copy = new Uint8Array(new ArrayBuffer(bytes.byteLength));
  copy.set(bytes);
  return copy.buffer;
};
const utf8 = (value) => new TextEncoder().encode(value);
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.byteLength, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.byteLength;
  }
  return out;
};

// ---------------------------------------------------------------------------
// RFC 8291 §5 — the published worked example.
// ---------------------------------------------------------------------------
const RFC = {
  plaintext: 'When I grow up, I want to be a watermelon',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  uaPrivate: 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  auth: 'BTBZMqHH6r4Tts7J_aSIgg',
  // The exact body from the RFC's "result" listing.
  body:
    'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
};

/**
 * Receiver side, written from RFC 8291 §3.4 / RFC 8188 §2.1: parse the header,
 * redo the HKDF chain from the *subscriber's* private key, then open the record.
 */
async function decryptAsSubscriber({ uaPrivate, auth, body, uaPublic }) {
  const bytes = b64urlDecode(body);
  const point = b64urlDecode(uaPublic);
  const salt = bytes.subarray(0, 16);
  const recordSize = new DataView(ab(bytes.subarray(0, 20))).getUint32(16, false);
  const keyIdLength = bytes[20];
  const senderPublic = bytes.subarray(21, 21 + keyIdLength);
  const ciphertext = bytes.subarray(21 + keyIdLength);

  const hkdf = async (ikm, saltBytes, info, length) => {
    const key = await crypto.subtle.importKey('raw', ab(ikm), 'HKDF', false, ['deriveBits']);
    return new Uint8Array(
      await crypto.subtle.deriveBits(
        { name: 'HKDF', hash: 'SHA-256', salt: ab(saltBytes), info: ab(info) },
        key,
        length * 8,
      ),
    );
  };

  const senderKey = await crypto.subtle.importKey(
    'raw',
    ab(senderPublic),
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );
  const uaPrivateKey = await importPair(uaPublic, uaPrivate, ['deriveBits']);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: senderKey }, uaPrivateKey, 256));
  const ikm = await hkdf(
    ecdh,
    b64urlDecode(auth),
    concat(utf8('WebPush: info\0'), point, senderPublic),
    32,
  );
  const cek = await hkdf(ikm, salt, utf8('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(ikm, salt, utf8('Content-Encoding: nonce\0'), 12);

  const key = await crypto.subtle.importKey('raw', ab(cek), { name: 'AES-GCM' }, false, ['decrypt']);
  const record = new Uint8Array(
    await crypto.subtle.decrypt({ name: 'AES-GCM', iv: ab(nonce), tagLength: 128 }, key, ab(ciphertext)),
  );
  assert.equal(record[record.byteLength - 1], 0x02, 'single record must end with the 0x02 padding delimiter');
  return { recordSize, keyIdLength, plaintext: new TextDecoder().decode(record.subarray(0, -1)) };
}

const importPair = async (publicKey, privateKeyValue, usages) => {
  const point = b64urlDecode(publicKey);
  return await crypto.subtle.importKey(
    'jwk',
    {
      kty: 'EC',
      crv: 'P-256',
      d: privateKeyValue,
      x: b64urlEncode(point.subarray(1, 33)),
      y: b64urlEncode(point.subarray(33, 65)),
    },
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    usages,
  );
};

describe('RFC 8291 aes128gcm payload encryption', () => {
  it('reproduces the published example byte for byte', async () => {
    const senderPrivate = await importPair(RFC.asPublic, RFC.asPrivate, ['deriveBits']);

    const { body } = await encryptPushPayload(
      { p256dh: RFC.uaPublic, auth: RFC.auth },
      RFC.plaintext,
      {
        salt: b64urlDecode(RFC.salt),
        senderKeys: { privateKey: senderPrivate, publicKey: b64urlDecode(RFC.asPublic) },
      },
    );

    assert.equal(b64urlEncode(body), RFC.body);

    // ...and the documented ciphertext really does decrypt with the
    // subscriber's private key, decoded by code that shares nothing with ours.
    const decrypted = await decryptAsSubscriber({
      uaPrivate: RFC.uaPrivate,
      uaPublic: RFC.uaPublic,
      auth: RFC.auth,
      body: RFC.body,
    });
    assert.equal(decrypted.plaintext, RFC.plaintext);
    assert.equal(decrypted.recordSize, 4096);
    assert.equal(decrypted.keyIdLength, 65);
    assert.equal(body.byteLength, b64urlDecode(RFC.body).byteLength);
  });

  it('round-trips a fresh subscription and keeps the header layout', async () => {
    const ua = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const uaPublic = new Uint8Array(await crypto.subtle.exportKey('raw', ua.publicKey));
    const uaPrivateJwk = await crypto.subtle.exportKey('jwk', ua.privateKey);
    const auth = b64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
    const payload = JSON.stringify({ title: 'Aziz', body: 'Salom!', tag: 'chat-1' });

    const { body } = await encryptPushPayload(
      { p256dh: b64urlEncode(uaPublic), auth },
      payload,
    );

    assert.equal(body[16 + 4], 65, 'key id length byte');
    assert.deepEqual([...body.subarray(16, 20)], [0, 0, 16, 0], 'record size 4096, big endian');
    // The ephemeral sender key must never repeat.
    assert.notDeepEqual(uaPublic, body.subarray(21, 86));

    const decrypted = await decryptAsSubscriber({
      uaPrivate: uaPrivateJwk.d,
      uaPublic: b64urlEncode(uaPublic),
      auth,
      body: b64urlEncode(body),
    });
    assert.equal(decrypted.plaintext, payload);
  });

  it('refuses malformed subscription keys and oversized payloads', async () => {
    await assert.rejects(
      () => encryptPushPayload({ p256dh: b64urlEncode(new Uint8Array(32)), auth: 'BTBZMqHH6r4Tts7J_aSIgg' }, 'x'),
      /uncompressed P-256 point/,
    );
    await assert.rejects(
      () => encryptPushPayload({ p256dh: RFC.uaPublic, auth: b64urlEncode(new Uint8Array(8)) }, 'x'),
      /16-byte secret/,
    );
    await assert.rejects(
      () => encryptPushPayload({ p256dh: RFC.uaPublic, auth: RFC.auth }, 'x'.repeat(MAX_PUSH_PAYLOAD_BYTES + 1)),
      /exceeds/,
    );
  });
});

describe('push endpoint policy', () => {
  it('accepts the real push services and returns the VAPID audience', () => {
    const target = parsePushEndpoint('https://fcm.googleapis.com/fcm/send/abc123');
    assert.equal(target.origin, 'https://fcm.googleapis.com');
    assert.equal(parsePushEndpoint('https://updates.push.services.mozilla.com/wpush/v2/xyz').origin,
      'https://updates.push.services.mozilla.com');
    assert.equal(parsePushEndpoint('https://web.push.apple.com/QGxhbWJlcnQ').origin, 'https://web.push.apple.com');
  });

  it('refuses plaintext, credentials, and an endpoint that is not a push service', () => {
    for (const bad of [
      'http://fcm.googleapis.com/fcm/send/abc',
      'https://user:pass@fcm.googleapis.com/fcm/send/abc',
      // The classic SSRF targets, and an attacker-chosen host.
      'https://169.254.169.254/latest/meta-data/',
      'https://127.0.0.1:54321/rest/v1/',
      'https://evil.example.com/collect',
      'not a url',
    ]) {
      assert.throws(() => parsePushEndpoint(bad), HttpError, `expected ${bad} to be refused`);
    }
  });

  it('allows an operator-approved host through the escape hatch', () => {
    assert.equal(
      parsePushEndpoint('https://push.internal.example/x', ['push.internal.example']).origin,
      'https://push.internal.example',
    );
    assert.equal(
      parsePushEndpoint('https://a.push.example/x', ['*.push.example']).origin,
      'https://a.push.example',
    );
    // A wildcard must not be defeated by a suffix trick.
    assert.throws(() => parsePushEndpoint('https://push.example.evil.test/x', ['*.push.example']));
  });
});

describe('VAPID (RFC 8292)', () => {
  const pair = async () => {
    const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const raw = new Uint8Array(await crypto.subtle.exportKey('raw', key.publicKey));
    const jwk = await crypto.subtle.exportKey('jwk', key.privateKey);
    return { publicKey: b64urlEncode(raw), privateKey: jwk.d, key };
  };

  it('loads a matching pair and refuses a mismatched one', async () => {
    const a = await pair();
    const b = await pair();
    const keys = await loadVapidKeys(a.publicKey, a.privateKey);
    assert.equal(keys.publicKey, a.publicKey);

    await assert.rejects(() => loadVapidKeys(a.publicKey, b.privateKey), /not the same key pair/);
    await assert.rejects(() => loadVapidKeys(b64urlEncode(new Uint8Array(64)), a.privateKey), /65-byte uncompressed/);
    await assert.rejects(() => loadVapidKeys(a.publicKey, b64urlEncode(new Uint8Array(16))), /32-byte private scalar/);
  });

  it('signs an assertion the push service can verify, scoped to the endpoint origin', async () => {
    const a = await pair();
    const keys = await loadVapidKeys(a.publicKey, a.privateKey);
    const target = parsePushEndpoint('https://updates.push.services.mozilla.com/wpush/v2/xyz');
    const header = await vapidAuthorization(keys, target, {
      subject: 'mailto:ops@example.com',
      now: 1_700_000_000,
    });

    const match = /^vapid t=([\w-]+\.[\w-]+\.[\w-]+), k=([\w-]+)$/.exec(header);
    assert.ok(match, `unexpected authorization header: ${header}`);
    const [, jwt, k] = match;
    assert.equal(k, a.publicKey);

    const [head, claims, signature] = jwt.split('.');
    assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(head))), { typ: 'JWT', alg: 'ES256' });
    const parsed = JSON.parse(new TextDecoder().decode(b64urlDecode(claims)));
    assert.equal(parsed.aud, 'https://updates.push.services.mozilla.com');
    assert.equal(parsed.sub, 'mailto:ops@example.com');
    assert.equal(parsed.exp, 1_700_000_000 + 12 * 60 * 60);

    // ES256 over the signing input, verified with the public half. WebCrypto's
    // ECDSA output is already raw r||s, which is what JWS expects.
    const point = b64urlDecode(a.publicKey);
    const verifier = await crypto.subtle.importKey(
      'jwk',
      { kty: 'EC', crv: 'P-256', x: b64urlEncode(point.subarray(1, 33)), y: b64urlEncode(point.subarray(33, 65)) },
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify'],
    );
    assert.equal(signature.length, 86, '64-byte r||s signature, base64url');
    assert.equal(
      await crypto.subtle.verify(
        { name: 'ECDSA', hash: 'SHA-256' },
        verifier,
        ab(b64urlDecode(signature)),
        ab(utf8(`${head}.${claims}`)),
      ),
      true,
    );
  });

  it('rejects a subject the push services would refuse', async () => {
    const a = await pair();
    const keys = await loadVapidKeys(a.publicKey, a.privateKey);
    const target = parsePushEndpoint('https://fcm.googleapis.com/fcm/send/abc');
    await assert.rejects(() => vapidAuthorization(keys, target, { subject: '' }), /mailto:/);
    await assert.rejects(() => vapidAuthorization(keys, target, { subject: 'ops@example.com' }), /mailto:/);
  });
});

describe('outbound request assembly', () => {
  it('builds a complete POST with the headers a push service requires', async () => {
    const a = await (async () => {
      const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
      const raw = new Uint8Array(await crypto.subtle.exportKey('raw', key.publicKey));
      const jwk = await crypto.subtle.exportKey('jwk', key.privateKey);
      return loadVapidKeys(b64urlEncode(raw), jwk.d);
    })();
    const ua = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const request = await buildPushRequest(
      {
        endpoint: 'https://fcm.googleapis.com/fcm/send/abc123',
        p256dh: b64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw', ua.publicKey))),
        auth: b64urlEncode(crypto.getRandomValues(new Uint8Array(16))),
      },
      { title: 'Aziz', body: 'Salom!', data: { chat_id: 'c1', url: '/#/chat/c1' } },
      a,
      { subject: 'mailto:ops@example.com' },
    );

    assert.equal(request.url, 'https://fcm.googleapis.com/fcm/send/abc123');
    assert.equal(request.init.method, 'POST');
    const headers = request.init.headers;
    assert.equal(headers['content-encoding'], 'aes128gcm');
    assert.equal(headers['content-type'], 'application/octet-stream');
    assert.equal(headers['urgency'], 'high');
    assert.match(headers.ttl, /^\d+$/);
    assert.match(headers.authorization, /^vapid t=/);
    assert.equal(Number(headers['content-length']), request.init.body.byteLength);
    assert.ok(request.init.body.byteLength > 100);
  });
});

describe('sweep policy (pg_net triggers the same function the app does)', () => {
  it('lets a scheduled caller wait out the fold window, and never a user request', () => {
    // Migration 00018 dispatches at INSERT time; the row is held for 2 s.
    const scheduled = resolveSweepPlan({ limit: 10, wait_ms: 3000 }, { maxLimit: 25, isScheduled: true });
    assert.deepEqual(scheduled, { limit: 10, waitMs: 3000 });

    // The same body from a user's tab must not hold that person's request open.
    const user = resolveSweepPlan({ limit: 10, wait_ms: 3000 }, { maxLimit: 5, isScheduled: false });
    assert.deepEqual(user, { limit: 5, waitMs: 0 });
  });

  it('clamps a hostile or mistaken body instead of trusting it', () => {
    for (const [body, expected] of [
      [{}, { limit: 25, waitMs: 0 }],
      [{ limit: 10_000 }, { limit: 25, waitMs: 0 }],
      [{ limit: 0 }, { limit: 1, waitMs: 0 }],
      [{ limit: -4, wait_ms: -1 }, { limit: 1, waitMs: 0 }],
      [{ limit: '7', wait_ms: '2500' }, { limit: 7, waitMs: 2500 }],
      [{ wait_ms: 600_000 }, { limit: 25, waitMs: WAIT_MS_MAX }],
      [{ limit: 2.9, wait_ms: 12.7 }, { limit: 2, waitMs: 12 }],
      ['not an object', { limit: 25, waitMs: 0 }],
      [null, { limit: 25, waitMs: 0 }],
    ]) {
      assert.deepEqual(
        resolveSweepPlan(body, { maxLimit: 25, isScheduled: true }),
        expected,
        `body ${JSON.stringify(body)}`,
      );
    }
  });

  it('keeps the wait well inside an edge invocation budget', () => {
    // Two sweeps plus this wait is the worst case; it must stay far below any
    // function wall-clock limit, and above the 2 s fold window it exists for.
    assert.ok(WAIT_MS_MAX >= 2500, 'long enough to outlast the fold window');
    assert.ok(WAIT_MS_MAX <= 10_000, 'short enough not to risk a timeout');
  });
});
