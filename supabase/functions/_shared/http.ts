/** HTTP plumbing: CORS, envelopes, bounded body reading, auth extraction. */

import { HttpError, STATUS_BY_CODE, type Envelope, type ErrorCode } from './types.ts';
import { redact } from './logger.ts';

const CORS_HEADERS_CACHE = new Map<string, Headers>();

export function corsHeaders(origin: string | null, allowedOrigins: string[]): Headers {
  const cacheKey = `${origin ?? 'null'}|${allowedOrigins.join(',')}`;
  const cached = CORS_HEADERS_CACHE.get(cacheKey);
  if (cached) return cached;

  const wildcard = allowedOrigins.includes('*');
  const allowed = wildcard ? '*' : origin && allowedOrigins.includes(origin) ? origin : '';
  const headers = new Headers({
    'access-control-allow-methods': 'POST, GET, OPTIONS',
    'access-control-allow-headers': [
      'authorization',
      'apikey',
      'content-type',
      'x-bridge-signature',
      'x-bridge-ts',
      'x-request-id',
      'x-supabase-accept-profile',
    ].join(', '),
    'access-control-max-age': '600',
    'vary': 'Origin',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  });
  if (allowed) {
    headers.set('access-control-allow-origin', allowed);
    if (!wildcard) headers.set('access-control-allow-credentials', 'true');
  }
  CORS_HEADERS_CACHE.set(cacheKey, headers);
  return headers;
}

export function json<T>(body: Envelope<T>, cors: Headers, status?: number): Response {
  const headers = new Headers(cors);
  headers.set('content-type', 'application/json; charset=utf-8');
  const ok = body.ok;
  if (!ok) headers.set('cache-control', 'no-store');
  return new Response(JSON.stringify(body), {
    status: status ?? (ok ? 200 : STATUS_BY_CODE[body.error.code]),
    headers,
  });
}

export const ok = <T>(data: T, cors: Headers): Response => json<T>({ ok: true, data }, cors);

export const fail = (
  code: ErrorCode,
  message: string,
  cors: Headers,
  options: { retryAfterSeconds?: number; status?: number } = {},
): Response =>
  json<never>(
    {
      ok: false,
      error: {
        code,
        message,
        ...(options.retryAfterSeconds ? { retry_after_seconds: options.retryAfterSeconds } : {}),
      },
    },
    cors,
    options.status,
  );

/** Wraps a handler so any throw becomes a clean envelope (and preflights work). */
export function withEnvelope(
  handler: (request: Request, cors: Headers) => Promise<Response> | Response,
  corsFor: (request: Request) => Headers,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    const cors = corsFor(request);
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors });
    }
    try {
      return await handler(request, cors);
    } catch (error) {
      if (error instanceof HttpError) {
        return fail(error.code, error.message, cors, {
          retryAfterSeconds: error.retryAfterSeconds,
          status: error.status,
        });
      }
      // Never leak stack traces or upstream bodies to the caller.
      console.error('unhandled', redact({ message: (error as Error)?.message, name: (error as Error)?.name }));
      return fail('internal_error', 'internal error', cors, { status: 500 });
    }
  };
}

export async function readJsonBody<T>(request: Request, maxBytes: number): Promise<T> {
  const lengthHeader = request.headers.get('content-length');
  if (lengthHeader && Number.parseInt(lengthHeader, 10) > maxBytes) {
    throw new HttpError('payload_too_large', `body exceeds ${maxBytes} bytes`);
  }
  const raw = await request.text();
  if (raw.length > maxBytes) {
    throw new HttpError('payload_too_large', `body exceeds ${maxBytes} bytes`);
  }
  if (raw.trim() === '') return {} as T;
  try {
    return JSON.parse(raw) as T;
  } catch {
    throw new HttpError('bad_request', 'body must be valid JSON');
  }
}

export function bearerToken(request: Request): string | null {
  const header = request.headers.get('authorization') ?? request.headers.get('Authorization');
  if (!header) return null;
  const [scheme, token] = header.split(' ');
  if (!scheme || scheme.toLowerCase() !== 'bearer' || !token) return null;
  return token.trim();
}

export function clientIp(request: Request): string | null {
  const forwarded = request.headers.get('x-forwarded-for');
  if (forwarded) return forwarded.split(',')[0]?.trim() ?? null;
  return request.headers.get('x-real-ip') ?? request.headers.get('cf-connecting-ip') ?? null;
}

export const queryParam = (request: Request, name: string): string | null =>
  new URL(request.url).searchParams.get(name);

/** Narrow, dependency-free body validation (kept explicit: no reflection magic). */
export function expectString(value: unknown, field: string, options: {
  min?: number;
  max?: number;
  pattern?: RegExp;
  optional?: boolean;
}): string | null {
  if (value === undefined || value === null || value === '') {
    if (options.optional) return null;
    throw new HttpError('bad_request', `${field} is required`);
  }
  if (typeof value !== 'string') throw new HttpError('bad_request', `${field} must be a string`);
  const trimmed = value.trim();
  if (options.min !== undefined && trimmed.length < options.min) {
    throw new HttpError('bad_request', `${field} must be at least ${options.min} characters`);
  }
  if (options.max !== undefined && trimmed.length > options.max) {
    throw new HttpError('bad_request', `${field} must be at most ${options.max} characters`);
  }
  if (options.pattern && !options.pattern.test(trimmed)) {
    throw new HttpError('bad_request', `${field} has an invalid format`);
  }
  return trimmed;
}

export function expectUuidArray(value: unknown, field: string, max: number): string[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new HttpError('bad_request', `${field} must be a non-empty array`);
  }
  if (value.length > max) {
    throw new HttpError('bad_request', `${field} accepts at most ${max} entries`);
  }
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return value.map((item, index) => {
    if (typeof item !== 'string' || !uuid.test(item)) {
      throw new HttpError('bad_request', `${field}[${index}] is not a uuid`);
    }
    return item.toLowerCase();
  });
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
