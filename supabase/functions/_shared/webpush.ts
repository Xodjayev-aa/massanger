/**
 * Web Push: RFC 8030 transport, RFC 8291 payload encryption (aes128gcm) and
 * RFC 8292 VAPID — on WebCrypto only, so the same code runs in the Deno edge
 * runtime and in the Node test suite.
 *
 * Why this exists: MessengerX's original offline notice path pushes text into
 * the user's *own* Telegram Saved Messages, which requires the TDLib bridge to
 * be running somewhere. Web Push removes that requirement for the PWA: the
 * browser's push service keeps the connection, the notification is rendered by
 * a service worker, and no machine of ours has to stay awake.
 *
 * Nothing here is MessengerX-specific. The three primitives are:
 *
 *   • HKDF-SHA256, used twice — once to mix the subscriber's `auth` secret into
 *     the ECDH shared secret (RFC 8291 §3.3), once to derive the record key and
 *     nonce from the per-message salt (RFC 8188 §2.2).
 *   • AES-128-GCM with the 16-byte tag appended, which is exactly the `aes128gcm`
 *     content coding.
 *   • ES256 (P-256 / SHA-256) for the VAPID assertion.
 *
 * WebCrypto's ECDSA output is already the raw `r || s` pair that JWS wants —
 * unlike OpenSSL, it never returns DER here — which is the one detail that
 * usually forces a hand-rolled signature encoder.
 */

import { b64urlDecode, b64urlEncode } from './crypto.ts';
import { HttpError } from './types.ts';

const enc = new TextEncoder();

/** RFC 8188 record size we advertise. 4096 is the size every push service accepts. */
const RECORD_SIZE = 4096;

/**
 * RFC 8291 §4 caps the plaintext at `rs - 17` (16 bytes of tags plus the single
 * record delimiter). Anything longer would need real record splitting, which is
 * pointless for a chat notification — we refuse instead of truncating.
 */
export const MAX_PUSH_PAYLOAD_BYTES = RECORD_SIZE - 17;

/** VAPID assertions stay valid for 12 h; shorter is safer, longer saves signatures. */
const VAPID_TTL_SECONDS = 12 * 60 * 60;

const toArrayBuffer = (bytes: Uint8Array): ArrayBuffer => {
  const copy = new Uint8Array(new ArrayBuffer(bytes.byteLength));
  copy.set(bytes);
  return copy.buffer;
};

const utf8 = (value: string): Uint8Array<ArrayBuffer> => new Uint8Array(toArrayBuffer(enc.encode(value)));

const concat = (...parts: Uint8Array[]): Uint8Array<ArrayBuffer> => {
  const total = parts.reduce((sum, part) => sum + part.byteLength, 0);
  const out = new Uint8Array(new ArrayBuffer(total));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
};

// ---------------------------------------------------------------------------
// Endpoint policy — a registered endpoint is attacker-controlled input, so it
// must not become an SSRF primitive. Only the real push services are allowed.
// ---------------------------------------------------------------------------
const DEFAULT_PUSH_HOSTS = [
  // Chrome / Edge / Opera / Brave, and every Chromium-based Android browser.
  'fcm.googleapis.com',
  // Firefox.
  'updates.push.services.mozilla.com',
  // Safari (macOS and iOS PWA).
  'web.push.apple.com',
  // Windows.
  'notify.windows.com',
];

export type PushEndpoint = { url: string; origin: string };

/**
 * Accepts only an `https://` URL on a known push service host and returns the
 * exact origin, which is the VAPID `aud` value (RFC 8292 §2). `extraHosts` is
 * the operator escape hatch for a self-hosted or future push service.
 */
export function parsePushEndpoint(endpoint: string, extraHosts: string[] = []): PushEndpoint {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    throw new HttpError('bad_request', 'push endpoint is not a URL');
  }
  if (url.protocol !== 'https:') {
    throw new HttpError('bad_request', 'push endpoint must use https');
  }
  if (url.username !== '' || url.password !== '') {
    throw new HttpError('bad_request', 'push endpoint must not carry credentials');
  }
  const allowed = [...DEFAULT_PUSH_HOSTS, ...extraHosts.map((host) => host.trim().toLowerCase())]
    .filter((host) => host.length > 0);
  const host = url.hostname.toLowerCase();
  const known = allowed.some((candidate) =>
    candidate.startsWith('*.') ? host.endsWith(candidate.slice(1)) : host === candidate
  );
  if (!known) {
    throw new HttpError('bad_request', 'push endpoint host is not a known push service');
  }
  return { url: url.toString(), origin: url.origin };
}

// ---------------------------------------------------------------------------
// VAPID (RFC 8292)
// ---------------------------------------------------------------------------
export type VapidKeys = {
  /** base64url uncompressed P-256 point — the public `k=` parameter. */
  publicKey: string;
  /** The matching P-256 private key, ready to sign. */
  privateKey: CryptoKey;
};

const decodePublicPoint = (value: string): Uint8Array<ArrayBuffer> => {
  let bytes: Uint8Array<ArrayBuffer>;
  try {
    bytes = b64urlDecode(value.replace(/\s/g, ''));
  } catch {
    throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PUBLIC_KEY is not base64url');
  }
  // 0x04 marks an uncompressed point: 0x04 || X(32) || Y(32).
  if (bytes.byteLength !== 65 || bytes[0] !== 0x04) {
    throw new HttpError(
      'misconfigured',
      'WEB_PUSH_VAPID_PUBLIC_KEY must be the 65-byte uncompressed P-256 point, base64url-encoded',
    );
  }
  return bytes;
};

/**
 * Loads and *proves* the key pair. A deployment that pastes a public key from a
 * different pair would otherwise sign every push with a VAPID assertion the push
 * service rejects — a silent, total delivery outage. Signing one probe message
 * and verifying it with the public half turns that into a start-up failure.
 */
export async function loadVapidKeys(publicKeyValue: string, privateKeyValue: string): Promise<VapidKeys> {
  const point = decodePublicPoint(publicKeyValue);
  const x = b64urlEncode(point.subarray(1, 33));
  const y = b64urlEncode(point.subarray(33, 65));

  const raw = privateKeyValue.trim().replace(/\s/g, '');
  let d: string;
  if (raw.startsWith('{')) {
    // A full JWK is also accepted: operators sometimes generate one directly.
    let jwk: JsonWebKey;
    try {
      jwk = JSON.parse(raw) as JsonWebKey;
    } catch {
      throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PRIVATE_KEY is not valid JSON');
    }
    if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || typeof jwk.d !== 'string') {
      throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PRIVATE_KEY JWK must be an EC P-256 key with a `d` value');
    }
    d = jwk.d;
  } else {
    let bytes: Uint8Array<ArrayBuffer>;
    try {
      bytes = b64urlDecode(raw);
    } catch {
      throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PRIVATE_KEY is not base64url');
    }
    if (bytes.byteLength !== 32) {
      throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_PRIVATE_KEY must be the 32-byte private scalar');
    }
    d = b64urlEncode(bytes);
  }

  const pairMismatch = new HttpError(
    'misconfigured',
    'WEB_PUSH_VAPID_PUBLIC_KEY and WEB_PUSH_VAPID_PRIVATE_KEY are not the same key pair',
  );

  // Some runtimes reject a `d` that does not belong to `x`/`y` while importing
  // (Node throws DataError); others only fail at verification. Both are the same
  // operator mistake, so both get the same actionable message.
  const privateKey = await crypto.subtle.importKey(
    'jwk',
    { kty: 'EC', crv: 'P-256', x, y, d },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  ).catch(() => {
    throw pairMismatch;
  });

  const verifier = await crypto.subtle.importKey(
    'jwk',
    { kty: 'EC', crv: 'P-256', x, y },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  const probe = utf8('messengerx-vapid-pair-check');
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    privateKey,
    toArrayBuffer(probe),
  ));
  const matches = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    verifier,
    toArrayBuffer(signature),
    toArrayBuffer(probe),
  );
  if (!matches) throw pairMismatch;

  return { publicKey: b64urlEncode(point), privateKey };
}

/**
 * `Authorization: vapid t=<jwt>, k=<key>` (RFC 8292 §3). The audience is the
 * push service origin, never the app origin — a common cause of 401s.
 */
export async function vapidAuthorization(
  keys: VapidKeys,
  target: PushEndpoint,
  options: { subject: string; now?: number; ttlSeconds?: number },
): Promise<string> {
  const subject = options.subject.trim();
  if (!/^(mailto:|https:)/.test(subject)) {
    // Push services require a contact URI; a bare address is silently rejected.
    throw new HttpError('misconfigured', 'WEB_PUSH_VAPID_SUBJECT must be a mailto: or https: URI');
  }
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const exp = now + (options.ttlSeconds ?? VAPID_TTL_SECONDS);

  const header = b64urlEncode(utf8(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64urlEncode(utf8(JSON.stringify({ aud: target.origin, exp, sub: subject })));
  const signingInput = `${header}.${claims}`;
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    keys.privateKey,
    toArrayBuffer(utf8(signingInput)),
  ));
  return `vapid t=${signingInput}.${b64urlEncode(signature)}, k=${keys.publicKey}`;
}

// ---------------------------------------------------------------------------
// Payload encryption (RFC 8291 / RFC 8188)
// ---------------------------------------------------------------------------
export type SenderKeys = {
  /** The ephemeral ECDH private key for this one message. */
  privateKey: CryptoKey;
  /** The raw uncompressed point (65 bytes) that accompanies it in the header. */
  publicKey: Uint8Array;
};

/** A fresh P-256 ECDH key pair, exported to the raw point RFC 8291 wants. */
export async function generateSenderKeys(): Promise<SenderKeys> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  return {
    privateKey: pair.privateKey,
    publicKey: new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)),
  };
}

export type EncryptedPush = {
  /** The complete `aes128gcm` body: header block followed by the ciphertext. */
  body: Uint8Array<ArrayBuffer>;
};

/**
 * Encrypts one push message for one subscription key pair.
 *
 * `salt` and the ephemeral sender key are injectable so the test suite can
 * assert against the RFC 8291 §5 worked example instead of merely round-tripping
 * our own code. The sender's public point is passed in raw rather than read back
 * with `exportKey`, because a non-extractable key is perfectly valid input here
 * and exporting it is not something this function should require.
 */
export async function encryptPushPayload(
  target: Pick<PushSubscriptionRow, 'p256dh' | 'auth'>,
  payload: string,
  options: { salt?: Uint8Array; senderKeys?: SenderKeys } = {},
): Promise<EncryptedPush> {
  const plaintext = utf8(payload);
  if (plaintext.byteLength > MAX_PUSH_PAYLOAD_BYTES) {
    throw new HttpError('bad_request', `push payload exceeds ${MAX_PUSH_PAYLOAD_BYTES} bytes`);
  }

  const uaPublic = b64urlDecode(target.p256dh.replace(/\s/g, ''));
  if (uaPublic.byteLength !== 65 || uaPublic[0] !== 0x04) {
    throw new HttpError('bad_request', 'subscription p256dh must be the 65-byte uncompressed P-256 point');
  }
  const authSecret = b64urlDecode(target.auth.replace(/\s/g, ''));
  if (authSecret.byteLength !== 16) {
    throw new HttpError('bad_request', 'subscription auth must be a 16-byte secret');
  }

  const salt = options.salt ?? crypto.getRandomValues(new Uint8Array(16));
  if (salt.byteLength !== 16) {
    throw new HttpError('bad_request', 'salt must be 16 bytes');
  }

  const uaKey = await crypto.subtle.importKey(
    'raw',
    toArrayBuffer(uaPublic),
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );

  const sender = options.senderKeys ?? await generateSenderKeys();
  const senderPublic = sender.publicKey;
  if (senderPublic.byteLength !== 65 || senderPublic[0] !== 0x04) {
    throw new HttpError('bad_request', 'sender public key must be the 65-byte uncompressed P-256 point');
  }

  // RFC 8291 §3.1 — the ECDH shared secret.
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'ECDH', public: uaKey },
    sender.privateKey,
    256,
  ));

  // RFC 8291 §3.3 — fold the subscription's `auth` secret into the IKM.
  // The literal includes the trailing NUL; dropping it is the classic bug.
  const ikm = await hkdf(ecdhSecret, authSecret, concat(utf8('WebPush: info\0'), uaPublic, senderPublic), 32);

  // RFC 8188 §2.2 — per-message key material.
  const contentKey = await hkdf(ikm, salt, utf8('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(ikm, salt, utf8('Content-Encoding: nonce\0'), 12);

  const aesKey = await crypto.subtle.importKey('raw', toArrayBuffer(contentKey), { name: 'AES-GCM' }, false, ['encrypt']);

  // A single record ends with the 0x02 delimiter (RFC 8188 §2.1). WebCrypto
  // appends the 16-byte GCM tag to the ciphertext for us.
  const record = concat(plaintext, new Uint8Array([0x02]));
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: toArrayBuffer(nonce), tagLength: 128 },
    aesKey,
    toArrayBuffer(record),
  ));

  const recordSize = new Uint8Array(new ArrayBuffer(4));
  new DataView(recordSize.buffer).setUint32(0, RECORD_SIZE, false);

  return {
    body: concat(salt, recordSize, new Uint8Array([senderPublic.byteLength]), senderPublic, sealed),
  };
}

/** RFC 5869 extract-then-expand, which WebCrypto's HKDF performs in one call. */
async function hkdf(
  ikm: Uint8Array,
  salt: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey('raw', toArrayBuffer(ikm), 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: toArrayBuffer(salt), info: toArrayBuffer(info) },
    key,
    length * 8,
  );
  return new Uint8Array(bits);
}

// ---------------------------------------------------------------------------
// Request assembly — pure, so the whole outbound request is unit-testable.
// ---------------------------------------------------------------------------
export type PushSubscriptionRow = {
  endpoint: string;
  p256dh: string;
  auth: string;
};

export type PushRequest = {
  url: string;
  init: RequestInit;
};

/**
 * Builds the exact POST a push service expects: `aes128gcm` body, the VAPID
 * assertion, and `TTL` (a required header — some services reject a request that
 * omits it). `Urgency: high` asks the service to deliver immediately rather than
 * batching a chat alert behind a low-priority queue.
 */
export async function buildPushRequest(
  subscription: PushSubscriptionRow,
  message: { title: string; body: string; tag?: string; data?: Record<string, unknown> },
  keys: VapidKeys,
  options: { subject: string; ttlSeconds?: number; extraEndpointHosts?: string[]; now?: number },
): Promise<PushRequest> {
  const target = parsePushEndpoint(subscription.endpoint, options.extraEndpointHosts ?? []);
  const payload = JSON.stringify({ ...message, tag: message.tag ?? 'messengerx' });
  const { body } = await encryptPushPayload(subscription, payload);
  const authorization = await vapidAuthorization(keys, target, {
    subject: options.subject,
    now: options.now,
  });

  return {
    url: target.url,
    init: {
      method: 'POST',
      headers: {
        'authorization': authorization,
        'content-encoding': 'aes128gcm',
        'content-type': 'application/octet-stream',
        'content-length': String(body.byteLength),
        'ttl': String(options.ttlSeconds ?? 2419200),
        'urgency': 'high',
      },
      body,
    },
  };
}
