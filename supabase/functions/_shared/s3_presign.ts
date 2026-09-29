/**
 * AWS Signature Version 4 for the S3-compatible API of Backblaze B2.
 *
 * Written against the exact behaviour of `@aws-sdk/s3-request-presigner`
 * (which delegates to `@smithy/signature-v4`), because that is the reference
 * B2 users confirm presigned PUT/GET against, and because a hand-rolled signer
 * that is *almost* right produces signatures B2 rejects with a bare 403:
 *
 *   • payload hash for presigned URLs is `UNSIGNED-PAYLOAD`, carried as an
 *     `X-Amz-Content-Sha256` *query* parameter (the SDK's S3 presigner sets the
 *     header and the generic signer hoists every `x-amz-*` into the query);
 *   • `content-type` is deliberately unsigned — the SDK adds it to
 *     `unsignableHeaders` — so an upload may (and ours does) send any
 *     `Content-Type` the object was minted with;
 *   • the canonical path is used verbatim (`uriEscapePath: false`), which is
 *     identical for the keys this app mints: `[A-Za-z0-9._/-]` only;
 *   • header-authenticated requests (the HEAD behind `video-ticket confirm`)
 *     do carry `x-amz-content-sha256` and `x-amz-date` as signed headers.
 *
 * B2 supports presigned **PUT and GET** (not POST policies), which is exactly
 * what the upload/playing flow needs: the browser talks to B2 directly and the
 * video bytes never traverse Supabase.
 */

export type S3Config = Readonly<{
  /** Regional endpoint, e.g. `https://s3.us-west-000.backblazeb2.com`. */
  endpoint: string;
  /** B2 bucket region, e.g. `us-west-000`. */
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
}>;

export type PresignInput = Readonly<{
  method?: 'GET' | 'PUT' | 'DELETE';
  /** Object key, already validated as a relative path (no `..`, no leading `/`). */
  key: string;
  expiresInSeconds: number;
  /** Signing instant; injectable so tests are deterministic. */
  now?: Date;
}>;

export type SignedRequest = Readonly<{
  url: string;
  headers: Record<string, string>;
}>;

const ALGORITHM = 'AWS4-HMAC-SHA256';
const EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const UNSIGNED_PAYLOAD = 'UNSIGNED-PAYLOAD';

const encoder = new TextEncoder();

const toHex = (bytes: Uint8Array<ArrayBuffer>): string =>
  [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');

const sha256Hex = async (data: string): Promise<string> =>
  toHex(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(data))));

const hmac = async (
  key: Uint8Array<ArrayBuffer>,
  data: string,
): Promise<Uint8Array<ArrayBuffer>> => {
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    key,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(data)));
};

/** RFC 3986 strict encoding, matching the SDK's `escapeUri`. */
const escapeUri = (uri: string): string =>
  encodeURIComponent(uri).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );

const iso8601 = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, 'Z');

const signingDates = (now: Date): { longDate: string; shortDate: string } => {
  const longDate = iso8601(now).replace(/[-:]/g, '');
  return { longDate, shortDate: longDate.slice(0, 8) };
};

const credentialScope = (shortDate: string, region: string): string =>
  `${shortDate}/${region}/s3/aws4_request`;

const signingKey = async (
  secretAccessKey: string,
  shortDate: string,
  region: string,
): Promise<Uint8Array<ArrayBuffer>> => {
  const kDate = await hmac(encoder.encode(`AWS4${secretAccessKey}`), shortDate);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, 's3');
  return hmac(kService, 'aws4_request');
};

const deriveSignature = async (
  cfg: S3Config,
  canonicalRequest: string,
  longDate: string,
  shortDate: string,
): Promise<string> => {
  const scope = credentialScope(shortDate, cfg.region);
  const stringToSign = `${ALGORITHM}\n${longDate}\n${scope}\n${await sha256Hex(canonicalRequest)}`;
  const key = await signingKey(cfg.secretAccessKey, shortDate, cfg.region);
  return toHex(await hmac(key, stringToSign));
};

/** `https://host[:port]` from the configured endpoint (path-less by contract). */
const endpointParts = (cfg: S3Config): { origin: string; host: string } => {
  const endpoint = new URL(cfg.endpoint);
  return { origin: endpoint.origin, host: endpoint.host };
};

/**
 * A presigned URL: the client sends `method` to it directly and B2 verifies
 * the signature from the query string. `PUT` uploads, `GET` plays/downloads,
 * `DELETE` removes an unreferenced object.
 */
export async function presignS3(cfg: S3Config, input: PresignInput): Promise<string> {
  const { origin, host } = endpointParts(cfg);
  const method = input.method ?? 'GET';
  const path = `/${cfg.bucket}/${input.key}`;
  const { longDate, shortDate } = signingDates(input.now ?? new Date());
  const scope = credentialScope(shortDate, cfg.region);

  const query: Record<string, string> = {
    'X-Amz-Content-Sha256': UNSIGNED_PAYLOAD,
    'X-Amz-Algorithm': ALGORITHM,
    'X-Amz-Credential': `${cfg.accessKeyId}/${scope}`,
    'X-Amz-Date': longDate,
    'X-Amz-Expires': String(input.expiresInSeconds),
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalQuery = Object.keys(query)
    .sort()
    .map((name) => `${escapeUri(name)}=${escapeUri(query[name] ?? '')}`)
    .join('&');

  const canonicalRequest = [
    method,
    path,
    canonicalQuery,
    `host:${host}`,
    '',
    'host',
    UNSIGNED_PAYLOAD,
  ].join('\n');

  const signature = await deriveSignature(cfg, canonicalRequest, longDate, shortDate);
  return `${origin}${path}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

/**
 * A header-authenticated request for server-side object administration —
 * the `HEAD` that verifies a finished upload's real size before the database
 * is allowed to learn about it.
 */
export async function signS3Request(
  cfg: S3Config,
  input: Readonly<{ method: 'HEAD' | 'DELETE' | 'GET'; key: string; now?: Date }>,
): Promise<SignedRequest> {
  const { origin, host } = endpointParts(cfg);
  const path = `/${cfg.bucket}/${input.key}`;
  const { longDate, shortDate } = signingDates(input.now ?? new Date());
  const scope = credentialScope(shortDate, cfg.region);

  const headers: Record<string, string> = {
    host,
    'x-amz-content-sha256': EMPTY_SHA256,
    'x-amz-date': longDate,
  };
  const signedNames = ['host', 'x-amz-content-sha256', 'x-amz-date'];
  const canonicalHeaders = signedNames.map((name) => `${name}:${headers[name] ?? ''}`).join('\n');
  const canonicalRequest = [
    input.method,
    path,
    '',
    canonicalHeaders,
    '',
    signedNames.join(';'),
    EMPTY_SHA256,
  ].join('\n');

  const signature = await deriveSignature(cfg, canonicalRequest, longDate, shortDate);
  headers.authorization = `${ALGORITHM} Credential=${cfg.accessKeyId}/${scope}, ` +
    `SignedHeaders=${signedNames.join(';')}, Signature=${signature}`;
  return { url: `${origin}${path}`, headers };
}
