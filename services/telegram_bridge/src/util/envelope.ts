/**
 * Credential envelopes + webhook signing.
 *
 * Byte-for-byte compatible with `supabase/functions/_shared/crypto.ts`; the
 * interop test (test/envelope.test.ts) proves a payload sealed by the edge
 * function opens here and vice versa, which is the one place where a silent
 * drift between the two runtimes would be catastrophic.
 */

import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual as nodeTimingSafeEqual } from 'node:crypto';
import { createHash } from 'node:crypto';

export type CredentialEnvelope =
  | { alg: 'plain'; data: Record<string, string | boolean> }
  | { alg: 'A256GCM'; iv: string; ct: string };

export type LinkEnvelopePayload = {
  phone?: string;
  code?: string;
  password?: string;
  use_qr?: boolean;
  reason?: string;
  access_token?: string;
  refresh_token?: string;
};

const b64u = (buffer: Buffer): string =>
  buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/**
 * `atob` (not Buffer's lenient base64) is deliberate: it throws on malformed
 * input exactly like the WebCrypto side does, so both runtimes take the same
 * branch of the key derivation below for the same secret.
 */
const fromB64u = (value: string): Buffer =>
  Buffer.from(atob(value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4)), 'binary');

/**
 * Key material from `SEAL_KEY`. This mirrors `aesKeyFromSecret()` in
 * `supabase/functions/_shared/crypto.ts` line for line — hex64 is taken raw, a
 * base64url secret is decoded, short input is stretched with SHA-256 — because
 * both runtimes must derive the *same* 32 bytes or sealed credentials written by
 * the edge function cannot be opened here. `test/envelope.test.ts` proves it.
 */
export function aesKeyFromSecret(secret: string): Buffer {
  const trimmed = secret.trim();
  if (/^[0-9a-f]{64}$/i.test(trimmed)) return Buffer.from(trimmed, 'hex').subarray(0, 32);

  let bytes: Buffer;
  try {
    bytes = fromB64u(trimmed.replace(/\s/g, ''));
  } catch {
    // Not base64 at all: it is a passphrase, and the edge function stretches it
    // the same way.
    bytes = createHash('sha256').update(trimmed).digest();
  }
  if (bytes.byteLength < 32) bytes = createHash('sha256').update(bytes).digest();
  return bytes.subarray(0, 32);
}

export function sealEnvelope(payload: LinkEnvelopePayload, key: Buffer | null): CredentialEnvelope {
  if (!key) return { alg: 'plain', data: payload as unknown as Record<string, string | boolean> };
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return { alg: 'A256GCM', iv: b64u(iv), ct: b64u(Buffer.concat([ciphertext, tag])) };
}

export function openEnvelope(
  envelope: CredentialEnvelope | Record<string, unknown> | null | undefined,
  key: Buffer | null,
): LinkEnvelopePayload {
  if (!envelope || typeof envelope !== 'object') return {};
  const candidate = envelope as Partial<CredentialEnvelope>;
  if (candidate.alg === 'plain') {
    return ((candidate as { data?: LinkEnvelopePayload }).data ?? {}) as LinkEnvelopePayload;
  }
  if (candidate.alg !== 'A256GCM' || !candidate.iv || !candidate.ct) {
    throw new Error(`unsupported envelope algorithm ${String(candidate.alg ?? '(none)')}`);
  }
  if (!key) throw new Error('SEAL_KEY is required to open sealed credentials');

  const raw = fromB64u(candidate.ct);
  const tag = raw.subarray(raw.byteLength - 16);
  const body = raw.subarray(0, raw.byteLength - 16);
  const decipher = createDecipheriv('aes-256-gcm', key, fromB64u(candidate.iv), { authTagLength: 16 });
  decipher.setAuthTag(tag);
  return JSON.parse(Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8')) as LinkEnvelopePayload;
}

export async function hmacHex(secret: string, message: string): Promise<string> {
  return createHmac('sha256', secret).update(message).digest('hex');
}

export function buildSignatureHeader(secret: string, body: string, nowSeconds = Math.floor(Date.now() / 1000)): {
  header: string;
  ts: number;
} {
  return { header: `t=${nowSeconds},v1=${createHmac('sha256', secret).update(`${nowSeconds}.${body}`).digest('hex')}`, ts: nowSeconds };
}

/** Server-side helper: also used by the test-suite to assert the edge format. */
export function verifySignatureHeader(
  secret: string,
  header: string | null,
  body: string,
  toleranceSeconds: number,
  nowSeconds = Math.floor(Date.now() / 1000),
): boolean {
  if (!header) return false;
  const parts = new Map<string, string>();
  for (const chunk of header.split(',')) {
    const index = chunk.indexOf('=');
    if (index > 0) parts.set(chunk.slice(0, index).trim(), chunk.slice(index + 1).trim());
  }
  const ts = Number.parseInt(parts.get('t') ?? '', 10);
  const signature = parts.get('v1');
  if (!Number.isFinite(ts) || !signature) return false;
  if (Math.abs(nowSeconds - ts) > toleranceSeconds) return false;
  const expected = createHmac('sha256', secret).update(`${ts}.${body}`).digest();
  const presented = Buffer.from(signature, 'hex');
  return expected.byteLength === presented.byteLength && nodeTimingSafeEqual(expected, presented);
}

export const timingSafeEqualStrings = (a: string, b: string): boolean => {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.byteLength === right.byteLength && nodeTimingSafeEqual(left, right);
};
