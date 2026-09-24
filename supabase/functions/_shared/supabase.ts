/** Supabase clients + JWT handling for edge functions. */

import { createClient, type SupabaseClient, type User } from 'npm:@supabase/supabase-js@2';
import { HttpError } from './types.ts';
import type { Env } from './env.ts';

export type AdminClient = SupabaseClient;

/**
 * Service-role client. Only ever used for: writing audit rows, the bridge-only
 * RPCs, and storage administration. Every *user data* write in the app-facing
 * functions goes through `userClient()` instead, so RLS stays the authority.
 */
export function adminClient(env: Env): AdminClient {
  return createClient(env.supabaseUrl, env.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false, storageKey: `messengerx-admin-${Date.now()}` },
    global: { headers: { 'x-application-name': 'messengerx-edge' } },
  });
}

/** PostgREST client that carries the caller's JWT ⇒ RLS + column guards apply. */
export function userClient(env: Env, jwt: string): AdminClient {
  return createClient(env.supabaseUrl, env.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${jwt}`, 'x-application-name': 'messengerx-edge' } },
  });
}

export type DecodedJwt = {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  signature: string;
  raw: string;
};

export function decodeJwtUnverified(token: string): DecodedJwt {
  const segments = token.split('.');
  if (segments.length !== 3) throw new HttpError('unauthorized', 'malformed token');
  const [head, body, signature] = segments as [string, string, string];
  const decode = (segment: string): Record<string, unknown> => {
    try {
      return JSON.parse(atob(segment.replace(/-/g, '+').replace(/_/g, '/'))) as Record<string, unknown>;
    } catch {
      throw new HttpError('unauthorized', 'malformed token');
    }
  };
  return { header: decode(head), payload: decode(body), signature, raw: `${head}.${body}` };
}

const seconds = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) ? value : null;

/** Cheap preflight only. Hosted projects may issue ES256/RS256 user tokens;
 * for them the trusted GoTrue `getUser(token)` request in requireUser is the
 * authoritative signature check. HS256 projects also get a local HMAC check
 * when SUPABASE_JWT_SECRET is available. Never authorize using payload alone. */
export async function verifyJwt(env: Env, token: string): Promise<{ payload: Record<string, unknown> }> {
  const { header, payload, signature, raw } = decodeJwtUnverified(token);
  const now = Math.floor(Date.now() / 1000);

  const exp = seconds(payload.exp);
  if (exp !== null && exp + 5 < now) throw new HttpError('unauthorized', 'token expired');
  const nbf = seconds(payload.nbf);
  if (nbf !== null && nbf - 5 > now) throw new HttpError('unauthorized', 'token not valid yet');

  const role = typeof payload.role === 'string' ? payload.role : '';
  if (role !== 'authenticated') throw new HttpError('unauthorized', 'a user session is required');
  if (header.alg !== 'HS256' && header.alg !== 'ES256' && header.alg !== 'RS256') {
    throw new HttpError('unauthorized', 'unsupported token algorithm');
  }

  if (header.alg === 'HS256' && env.jwtSecret) {
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(env.jwtSecret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const expected = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)));
    const presented = (() => {
      const binary = atob(signature.replace(/-/g, '+').replace(/_/g, '/'));
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      return bytes;
    })();
    if (expected.length !== presented.length) throw new HttpError('unauthorized', 'bad token signature');
    let diff = 0;
    for (let i = 0; i < expected.length; i++) diff |= expected[i]! ^ presented[i]!;
    if (diff !== 0) throw new HttpError('unauthorized', 'bad token signature');
  }

  return { payload };
}

export type Caller = {
  user: User;
  uid: string;
  role: string;
  /** 'google' | 'phone' | 'email' | ... */
  provider: string;
  email: string | null;
  phone: string | null;
};

/**
 * The single entry point every client-facing function uses: signature check →
 * live user lookup (revoked sessions must not work) → provider info.
 */
export async function requireUser(env: Env, token: string | null): Promise<Caller> {
  if (!token) throw new HttpError('unauthorized', 'missing bearer token');
  const { payload } = await verifyJwt(env, token);

  const admin = adminClient(env);
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user || data.user.id !== payload.sub) {
    throw new HttpError('unauthorized', 'session is no longer valid');
  }

  const user = data.user;
  const metadataProvider = (user.app_metadata?.provider as string | undefined) ?? undefined;
  const identityProvider = user.identities?.[0]?.provider ?? undefined;

  return {
    user,
    uid: user.id,
    role: typeof payload.role === 'string' ? payload.role : 'authenticated',
    provider: identityProvider ?? metadataProvider ?? (user.email ? 'email' : 'phone'),
    email: user.email ?? null,
    phone: user.phone ?? null,
  };
}

/** Maps Postgres/HSF errors onto HTTP envelopes instead of leaking them. */
export async function rpc<T>(
  client: AdminClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    const message = error.message ?? '';
    if (fn === 'telegram_start_chat') {
      if (error.code === '42501') {
        throw new HttpError('forbidden', 'Connect Telegram and enable chat mirroring and outbound sync first.');
      }
      if (error.code === '22023') {
        throw new HttpError('bad_request', 'Enter a public Telegram @username (5–32 letters, digits or underscores).');
      }
      if (error.code === 'P0001' && /Too many Telegram lookups/i.test(message)) {
        throw new HttpError('rate_limited', 'Too many Telegram lookups. Try again in a minute.', { retryAfterSeconds: 60 });
      }
    }
    if (/not eligible|server-managed|permission denied|row-level security/i.test(message)) {
      throw new HttpError('forbidden', message);
    }
    if (/already exists|duplicate key/i.test(message)) {
      throw new HttpError('conflict', message);
    }
    if (/not found|no rows/i.test(message)) {
      throw new HttpError('not_found', message);
    }
    throw new HttpError('upstream_error', `database rejected the request`, { details: { fn } });
  }
  return data as T;
}
