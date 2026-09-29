import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { presignS3, signS3Request } from '../../supabase/functions/_shared/s3_presign.ts';

/**
 * SigV4 vectors for the B2 presigner.
 *
 * These exact strings were cross-checked byte-for-byte against
 * `@smithy/signature-v4` (the implementation behind
 * `@aws-sdk/s3-request-presigner`) with the same pinned clock, plus a
 * header-auth HEAD against `SignatureV4.sign()`. B2's S3 endpoint speaks the
 * same dialect (presigned PUT/GET/DELETE; no POST policies), so a change to
 * any vector below means uploads would start failing with a bare 403 — this
 * test exists so that change is a red unit test, not a production incident.
 */
const CFG = {
  endpoint: 'https://s3.us-west-000.backblazeb2.com',
  region: 'us-west-000',
  accessKeyId: '00221133445566778899aabbccddeeff',
  secretAccessKey: 'K001234567890abcdefghijklmnopqrstuvwxyzEXAMPLEKEY',
  bucket: 'messengerx-video',
};
const KEY = 'chat/3fa85f64-5717-4562-b3fc-2c963f66afa6/app/1770000000_ab12cd34.mp4';
const NOW = new Date('2026-09-28T12:00:00Z');
const ORIGIN = 'https://s3.us-west-000.backblazeb2.com';
const PATH = `/messengerx-video/${KEY}`;
const CREDENTIAL = '00221133445566778899aabbccddeeff/20260928/us-west-000/s3/aws4_request';

const VECTORS = {
  GET: {
    expires: 3600,
    url: `${ORIGIN}${PATH}?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD&X-Amz-Credential=00221133445566778899aabbccddeeff%2F20260928%2Fus-west-000%2Fs3%2Faws4_request&X-Amz-Date=20260928T120000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=fb22380382bd3aa2ed150907fc9efc58b2e48422571fd523d1cc685bf0a4347e`,
  },
  PUT: {
    expires: 900,
    url: `${ORIGIN}${PATH}?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD&X-Amz-Credential=00221133445566778899aabbccddeeff%2F20260928%2Fus-west-000%2Fs3%2Faws4_request&X-Amz-Date=20260928T120000Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host&X-Amz-Signature=07441ef5ed927dfa6eea8f2637df8136e8c6dfe1c1d65db2c2b2df1859bfe6ac`,
  },
  DELETE: {
    expires: 300,
    url: `${ORIGIN}${PATH}?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD&X-Amz-Credential=00221133445566778899aabbccddeeff%2F20260928%2Fus-west-000%2Fs3%2Faws4_request&X-Amz-Date=20260928T120000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature=a7099d1e1caa5ed58fc05817aebad38f07c3cd42216a9b8a9d3c5fdbe5ef7215`,
  },
};

describe('s3_presign presigned URLs', () => {
  for (const [method, vector] of Object.entries(VECTORS)) {
    it(`reproduces the ${method} reference signature at a pinned clock`, async () => {
      const url = await presignS3(CFG, {
        method: /** @type {'GET'|'PUT'|'DELETE'} */ (method),
        key: KEY,
        expiresInSeconds: vector.expires,
        now: NOW,
      });
      assert.equal(url, vector.url);
    });
  }

  it('keeps only host as a signed header and carries UNSIGNED-PAYLOAD', async () => {
    const url = new URL(await presignS3(CFG, { method: 'PUT', key: KEY, expiresInSeconds: 900, now: NOW }));
    assert.equal(url.searchParams.get('X-Amz-SignedHeaders'), 'host');
    assert.equal(url.searchParams.get('X-Amz-Content-Sha256'), 'UNSIGNED-PAYLOAD');
    assert.equal(url.searchParams.get('X-Amz-Algorithm'), 'AWS4-HMAC-SHA256');
    assert.equal(url.searchParams.get('X-Amz-Credential'), CREDENTIAL);
    assert.equal(url.searchParams.get('X-Amz-Date'), '20260928T120000Z');
    assert.equal(url.searchParams.get('X-Amz-Expires'), '900');
    assert.match(url.searchParams.get('X-Amz-Signature') ?? '', /^[0-9a-f]{64}$/);
    // Bucket-first, path-style addressing — what B2's endpoint expects.
    assert.equal(url.origin + url.pathname, `${ORIGIN}${PATH}`);
  });

  it('refuses to produce different output for the same instant (no hidden state)', async () => {
    const a = await presignS3(CFG, { method: 'GET', key: KEY, expiresInSeconds: 60, now: NOW });
    const b = await presignS3(CFG, { method: 'GET', key: KEY, expiresInSeconds: 60, now: NOW });
    assert.equal(a, b);
    const later = await presignS3(CFG, {
      method: 'GET',
      key: KEY,
      expiresInSeconds: 60,
      now: new Date('2026-09-28T12:00:01Z'),
    });
    assert.notEqual(a, later, 'a new second must re-sign');
  });

  it('escapes the credential slash and nothing else that matters', async () => {
    const url = new URL(await presignS3(CFG, { method: 'GET', key: KEY, expiresInSeconds: 60, now: NOW }));
    assert.equal(
      [...url.searchParams.keys()].filter((k) => k === 'X-Amz-Credential').length,
      1,
    );
    assert.ok(url.href.includes('X-Amz-Credential=00221133445566778899aabbccddeeff%2F20260928%2F'));
  });
});

describe('s3_presign header-authenticated requests', () => {
  it('reproduces the HEAD reference authorization header', async () => {
    const signed = await signS3Request(CFG, { method: 'HEAD', key: KEY, now: NOW });
    assert.equal(signed.url, `${ORIGIN}${PATH}`);
    assert.equal(
      signed.headers.authorization,
      'AWS4-HMAC-SHA256 Credential=00221133445566778899aabbccddeeff/20260928/us-west-000/s3/aws4_request, ' +
        'SignedHeaders=host;x-amz-content-sha256;x-amz-date, ' +
        'Signature=704412219b1fd3e3a6e9edbd54e5ac5a9752990e54a1498551e6240b2447152b',
    );
    assert.equal(signed.headers['x-amz-content-sha256'],
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    assert.equal(signed.headers['x-amz-date'], '20260928T120000Z');
    assert.equal(signed.headers.host, 's3.us-west-000.backblazeb2.com');
  });

  it('signs the path with the bucket exactly once', async () => {
    const signed = await signS3Request(CFG, { method: 'DELETE', key: KEY, now: NOW });
    assert.equal(signed.url, `${ORIGIN}${PATH}`);
    assert.notEqual(signed.headers.authorization?.includes('UNSIGNED'), true);
  });
});
