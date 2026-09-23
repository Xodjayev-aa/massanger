/**
 * Web-crypto helpers: AES-256-GCM sealing for one-time credentials, and
 * HMAC-SHA256 request signing for the bridge → edge webhook.
 *
 * Why sealing at all: the 6-digit Telegram login code and the 2FA password are
 * the crown jewels of a Telegram account. They must not sit in a Postgres row
 * (or in a WAL stream / read replica / logical-replication slot) in plaintext,
 * so the edge function encrypts them with a key that exists only in the
 * function + bridge environments (SEAL_KEY) and stores the ciphertext envelope.
 * The same key wraps stored Google refresh tokens at rest.
 */

import { HttpError } from './types.ts';
import type { CredentialEnvelope, LinkEnvelopePayload } from './types.ts';

const enc = new TextEncoder();
const dec = new TextDecoder();

/**
 * WebCrypto wants an `ArrayBuffer`-backed BufferSource. Copying through
 * `toArrayBuffer` keeps the types honest without relying on structural casts.
 */
const toArrayBuffer = (bytes: Uint8Array): ArrayBuffer => {
  const copy = new Uint8Array(new ArrayBuffer(bytes.byteLength));
  copy.set(bytes);
  return copy.buffer;
};

const toBytes = (bytes: Uint8Array): Uint8Array<ArrayBuffer> => new Uint8Array(toArrayBuffer(bytes));

export const b64urlEncode = (bytes: Uint8Array): string => {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

export const b64urlDecode = (value: string): Uint8Array<ArrayBuffer> => {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
};

/** Accepts 32 bytes base64url/base64/hex; rejects anything weaker. */
export async function aesKeyFromSecret(secret: string): Promise<CryptoKey> {
  const trimmed = secret.trim();
  let bytes: Uint8Array<ArrayBuffer>;
  if (/^[0-9a-f]{64}$/i.test(trimmed)) {
    bytes = toBytes(new Uint8Array(trimmed.match(/.{2}/g)!.map((pair) => Number.parseInt(pair, 16))));
  } else {
    try {
      bytes = b64urlDecode(trimmed.replace(/\s/g, ''));
    } catch {
      // A long passphrase is allowed too: stretch it with SHA-256.
      bytes = toBytes(new Uint8Array(await crypto.subtle.digest('SHA-256', toArrayBuffer(enc.encode(trimmed)))));
    }
  }
  if (bytes.byteLength < 32) {
    bytes = toBytes(new Uint8Array(await crypto.subtle.digest('SHA-256', toArrayBuffer(bytes))));
  }
  return crypto.subtle.importKey('raw', toArrayBuffer(bytes.subarray(0, 32)), { name: 'AES-GCM' }, false, [
    'encrypt',
    'decrypt',
  ]);
}

export async function seal(
  payload: LinkEnvelopePayload,
  key: CryptoKey | null,
): Promise<CredentialEnvelope> {
  if (!key) {
    // Local development (`supabase start`) without LINK_PAYLOAD_KEY.
    return { alg: 'plain', data: payload as unknown as Record<string, string | boolean> };
  }
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: toArrayBuffer(iv), tagLength: 128 },
    key,
    enc.encode(JSON.stringify(payload)),
  );
  return { alg: 'A256GCM', iv: b64urlEncode(iv), ct: b64urlEncode(new Uint8Array(cipher)) };
}

export async function open(
  envelope: CredentialEnvelope | Record<string, unknown> | null | undefined,
  key: CryptoKey | null,
): Promise<LinkEnvelopePayload> {
  if (!envelope || typeof envelope !== 'object') return {};
  const alg = (envelope as CredentialEnvelope).alg;
  if (alg === 'plain') {
    const data = (envelope as { data?: Record<string, string | boolean> }).data ?? {};
    return data as LinkEnvelopePayload;
  }
  if (alg !== 'A256GCM') {
    throw new HttpError('bad_request', `unsupported envelope algorithm ${String(alg)}`);
  }
  if (!key) {
    throw new HttpError('misconfigured', 'SEAL_KEY is required to open sealed credentials');
  }
  const { iv, ct } = envelope as { iv: string; ct: string };
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: b64urlDecode(iv), tagLength: 128 },
    key,
    toArrayBuffer(b64urlDecode(ct)),
  );
  return JSON.parse(dec.decode(plain)) as LinkEnvelopePayload;
}

// ---------------------------------------------------------------------------
// HMAC signing (bridge ⇄ edge)
// ---------------------------------------------------------------------------

export async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    toArrayBuffer(enc.encode(secret)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

export async function hmacSign(secret: string, message: string): Promise<string> {
  const signature = await crypto.subtle.sign(
    'HMAC',
    await hmacKey(secret),
    toArrayBuffer(enc.encode(message)),
  );
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** `t=<epoch>.v1=<hex>` signature scheme (Stripe-compatible shape). */
export async function verifySignedMessage(options: {
  secret: string;
  signatureHeader: string | null;
  body: string;
  toleranceSeconds: number;
  nowMs?: number;
}): Promise<{ ts: number; payload: string }> {
  const { secret, signatureHeader, body, toleranceSeconds } = options;
  if (!signatureHeader) {
    throw new HttpError('signature_invalid', 'missing x-bridge-signature header');
  }
  const parts = new Map<string, string>();
  for (const chunk of signatureHeader.split(',')) {
    const [key, value] = chunk.split('=');
    if (key && value !== undefined) parts.set(key.trim(), value.trim());
  }
  const tsRaw = parts.get('t');
  const signatures = (parts.get('v1') ?? '').split(' ').filter(Boolean);
  if (!tsRaw || signatures.length === 0) {
    throw new HttpError('signature_invalid', 'malformed x-bridge-signature header');
  }
  const ts = Number.parseInt(tsRaw, 10);
  if (!Number.isFinite(ts)) throw new HttpError('signature_invalid', 'malformed timestamp');
  const nowMs = options.nowMs ?? Date.now();
  const skew = Math.abs(Math.floor(nowMs / 1000) - ts);
  if (skew > toleranceSeconds) {
    throw new HttpError('stale_request', `signature timestamp is ${skew}s off the server clock`);
  }

  const expected = await hmacSign(secret, `${ts}.${body}`);
  const matched = signatures.some((candidate) => timingSafeEqual(candidate, expected));
  if (!matched) throw new HttpError('signature_invalid', 'signature does not match the shared secret');
  return { ts, payload: body };
}

export async function signRequest(secret: string, body: string): Promise<{ header: string; ts: number }> {
  const ts = Math.floor(Date.now() / 1000);
  const v1 = await hmacSign(secret, `${ts}.${body}`);
  return { header: `t=${ts},v1=${v1}`, ts };
}

/** Length-independent comparison (signatures may differ in length). */
export function timingSafeEqual(a: string, b: string): boolean {
  const left = enc.encode(a);
  const right = enc.encode(b);
  const length = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;
  for (let i = 0; i < length; i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

export const requireTokenMatch = (presented: string | null, expected: string | null): void => {
  if (!expected) {
    throw new HttpError('misconfigured', 'the expected shared secret is not configured');
  }
  if (!presented || !timingSafeEqual(presented, expected)) {
    throw new HttpError('unauthorized', 'invalid bridge token');
  }
};

/** 32-byte key material for LINK_PAYLOAD_KEY / BRIDGE_HMAC_SECRET generation. */
export const generateSecret = (): string => b64urlEncode(crypto.getRandomValues(new Uint8Array(32)));
