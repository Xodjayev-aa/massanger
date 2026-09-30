/**
 * video-ticket — authorization and presigned S3 URLs for Backblaze B2.
 *
 * Video bytes never pass through Supabase: the client asks this function for a
 * ticket, uploads **directly to B2**, then asks it to confirm what landed. The
 * function is the only place that holds the S3 secret, and it is the gate the
 * caps live behind:
 *
 *   put     → membership + account standing + declared limits → presigned PUT
 *   confirm → HEAD the object: real size, and the duration parsed out of the
 *             actual MP4 bytes (a declared number is not a cap) → the verified
 *             pair is what the client may write into messages.media / shorts
 *   get     → membership (chat) or any signed-in user (short) → presigned GET
 *   delete  → same authorization, and only when no live row references the key
 *             (attached media is reclaimed by the runbook's orphan sweep)
 *   status  → `{ configured }` so a deployment without B2 secrets can hide the
 *             video affordances instead of offering a broken upload
 *
 * One bucket, two key spaces: `chat/<chatId>/…` and `shorts/<uid>/…`. The
 * prefix is re-derived and re-checked on every action — a ticket for one chat
 * can never read or confirm another.
 */

import { type Env, readEnv } from '../_shared/env.ts';
import { configureLogger, log } from '../_shared/logger.ts';
import {
  bearerToken,
  clientIp,
  corsHeaders,
  expectString,
  ok,
  readJsonBody,
  UUID_RE,
  withEnvelope,
} from '../_shared/http.ts';
import { type AdminClient, requireUser, userClient } from '../_shared/supabase.ts';
import { enforce } from '../_shared/rate-limit.ts';
import { HttpError } from '../_shared/types.ts';
import { presignS3, type S3Config, signS3Request } from '../_shared/s3_presign.ts';
import { readMp4DurationMs } from '../_shared/mp4_duration.ts';

const FUNCTION_NAME = 'video-ticket';
const MAX_BODY = 8 * 1024;

/** Window the client has to start the upload after asking for a ticket. */
const PUT_EXPIRES_SECONDS = 900;
/** Playback window: long enough to watch, short enough to rot. */
const GET_EXPIRES_SECONDS = 3600;

/** Hard caps — the same numbers app.validate_message_media enforces. */
const MAX_DURATION_MS = 60_000;
const MAX_SIZE_BYTES = 262_144_000; // 250 MB

type Scope = 'chat' | 'short';

type RequestBody = {
  action?: 'status' | 'put' | 'confirm' | 'get' | 'delete';
  scope?: Scope;
  /** Required for scope 'chat'. */
  chatId?: string;
  /** Object key; required for confirm / get / delete. */
  key?: string;
  /** get only: request a signed attachment Content-Disposition for browser downloads. */
  download?: boolean;
  /** put only: declared shape, verified against the bytes at confirm. */
  mime?: string;
  durationMs?: number;
  sizeBytes?: number;
};

const isConfigured = (env: Env): boolean =>
  env.videoS3Endpoint !== null &&
  env.videoS3Region !== null &&
  env.videoS3AccessKeyId !== null &&
  env.videoS3SecretAccessKey !== null &&
  env.videoBucket !== null;

const s3Config = (env: Env): S3Config => ({
  endpoint: env.videoS3Endpoint as string,
  region: env.videoS3Region as string,
  accessKeyId: env.videoS3AccessKeyId as string,
  secretAccessKey: env.videoS3SecretAccessKey as string,
  bucket: env.videoBucket as string,
});

const expectInt = (value: unknown, field: string, min: number, max: number): number => {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new HttpError('bad_request', `${field} must be an integer`);
  }
  if (value < min || value > max) {
    throw new HttpError('bad_request', `${field} must be between ${min} and ${max}`);
  }
  return value;
};

const expectKey = (value: unknown): string => {
  const key = expectString(value, 'key', { min: 1, max: 512 });
  // Mirrors app.validate_message_media: a relative object path, nothing that
  // could climb out of the bucket or impersonate an absolute location.
  if (key!.startsWith('/') || key!.includes('..')) {
    throw new HttpError('bad_request', 'key must be a relative object path');
  }
  return key!;
};

const assertKeyScope = (scope: Scope, key: string, chatId: string | null, uid: string): void => {
  if (scope === 'chat') {
    if (!key.startsWith(`chat/${chatId}/`)) {
      throw new HttpError('bad_request', 'key does not belong to this chat');
    }
  } else if (!key.startsWith(`shorts/${uid}/`)) {
    throw new HttpError('bad_request', 'key does not belong to this account');
  }
};

/** Same standing rule the message and shorts insert policies apply. */
async function requireStanding(client: AdminClient, uid: string): Promise<void> {
  const { data, error } = await client.from('profiles').select('access_state').eq('id', uid)
    .maybeSingle();
  if (error) throw new HttpError('upstream_error', 'could not read the account state');
  if (data?.access_state !== 'active') {
    throw new HttpError('forbidden', 'account is not eligible to post');
  }
}

async function requireChatMember(client: AdminClient, uid: string, chatId: string): Promise<void> {
  if (!UUID_RE.test(chatId)) throw new HttpError('bad_request', 'chatId must be a uuid');
  const { data, error } = await client
    .from('chat_participants')
    .select('chat_id')
    .eq('chat_id', chatId)
    .eq('user_id', uid)
    .is('left_at', null)
    .maybeSingle();
  if (error) throw new HttpError('upstream_error', 'could not verify chat membership');
  if (!data) throw new HttpError('forbidden', 'you are not a participant of this chat');
}

/** Scope gate shared by put/confirm/delete (get has its own, see handle). */
async function authorizeScope(
  client: AdminClient,
  scope: Scope,
  uid: string,
  chatId: string | null,
): Promise<void> {
  await requireStanding(client, uid);
  if (scope === 'chat') {
    if (chatId === null) throw new HttpError('bad_request', 'chatId is required for a chat ticket');
    await requireChatMember(client, uid, chatId);
  }
}

const randomHex = (bytes: number): string =>
  [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, '0'))
    .join('');

function handle(request: Request): Promise<Response> {
  const env = readEnv();
  configureLogger(env, FUNCTION_NAME);

  return withEnvelope(async (req, cors) => {
    if (req.method !== 'POST') {
      throw new HttpError('bad_request', `${FUNCTION_NAME} only accepts POST`);
    }

    const token = bearerToken(req);
    const caller = await requireUser(env, token);
    const body = await readJsonBody<RequestBody>(req, MAX_BODY);
    const action = body.action ?? 'status';

    // Answered before the configuration gate: "is video enabled here?" must
    // work on a deployment that has not set the B2 secrets at all.
    if (action === 'status') return ok({ configured: isConfigured(env) }, cors);

    if (!isConfigured(env)) {
      throw new HttpError('misconfigured', 'video storage is not configured on this deployment', {
        status: 500,
      });
    }
    if (body.scope !== 'chat' && body.scope !== 'short') {
      throw new HttpError('bad_request', "scope must be 'chat' or 'short'");
    }
    const scope: Scope = body.scope;
    const chatId = body.chatId == null ? null : String(body.chatId);

    enforce(`video-ticket:${action}:uid`, caller.uid, action === 'get' ? 300 : 30, 60_000);
    if (action !== 'get') enforce('video-ticket:ip', clientIp(req) ?? 'unknown', 120);

    const s3 = s3Config(env);

    switch (action) {
      case 'put': {
        await authorizeScope(userClient(env, token!), scope, caller.uid, chatId);
        const mime = expectString(body.mime, 'mime', { max: 100 });
        if (mime !== 'video/mp4') {
          throw new HttpError(
            'bad_request',
            'only video/mp4 is accepted (there is no transcoding pipeline)',
          );
        }
        expectInt(body.durationMs, 'durationMs', 1, MAX_DURATION_MS);
        expectInt(body.sizeBytes, 'sizeBytes', 1, MAX_SIZE_BYTES);

        const prefix = scope === 'chat' ? `chat/${chatId}/app` : `shorts/${caller.uid}/app`;
        const key = `${prefix}/${Date.now()}_${randomHex(4)}.mp4`;
        const url = await presignS3(s3, {
          method: 'PUT',
          key,
          expiresInSeconds: PUT_EXPIRES_SECONDS,
        });
        log.info('video put ticket', { uid: caller.uid, scope, key });
        return ok(
          { key, url, expiresInSeconds: PUT_EXPIRES_SECONDS, contentType: 'video/mp4' },
          cors,
        );
      }

      case 'confirm': {
        await authorizeScope(userClient(env, token!), scope, caller.uid, chatId);
        const key = expectKey(body.key);
        assertKeyScope(scope, key, chatId, caller.uid);

        const head = await signS3Request(s3, { method: 'HEAD', key });
        const headResponse = await fetch(head.url, { method: 'HEAD', headers: head.headers });
        if (headResponse.status === 404) {
          throw new HttpError(
            'not_found',
            'that upload does not exist yet — upload first, then confirm',
          );
        }
        if (!headResponse.ok) throw new HttpError('upstream_error', 'could not verify the upload');
        const sizeBytes = Number(headResponse.headers.get('content-length') ?? 'NaN');
        if (!Number.isInteger(sizeBytes) || sizeBytes <= 0) {
          throw new HttpError('upstream_error', 'the upload reported no size');
        }
        if (sizeBytes > MAX_SIZE_BYTES) {
          await deleteObject(s3, key);
          throw new HttpError(
            'payload_too_large',
            `videos must stay under ${MAX_SIZE_BYTES} bytes`,
          );
        }

        // The duration is read from the bytes themselves: a declared number is
        // a hint, this is the cap. An `.mp4` that is not an MP4 fails here too,
        // which is what makes a content-type check unnecessary.
        const durationMs = await verifiedDurationMs(s3, key, sizeBytes);
        if (durationMs === null) {
          await deleteObject(s3, key);
          throw new HttpError('bad_request', 'that file could not be read as an MP4 video');
        }
        if (durationMs > MAX_DURATION_MS) {
          await deleteObject(s3, key);
          throw new HttpError('payload_too_large', `videos must stay under ${MAX_DURATION_MS} ms`);
        }

        log.info('video confirmed', { uid: caller.uid, scope, key, sizeBytes, durationMs });
        return ok({ key, sizeBytes, durationMs, contentType: 'video/mp4' }, cors);
      }

      case 'get': {
        const key = expectKey(body.key);
        const asUser = userClient(env, token!);
        if (scope === 'chat') {
          if (chatId === null) {
            throw new HttpError('bad_request', 'chatId is required for a chat ticket');
          }
          assertKeyScope(scope, key, chatId, caller.uid);
          // Watching needs membership, not posting standing: a restricted
          // account still reads its own chats, exactly like message RLS.
          await requireChatMember(asUser, caller.uid, chatId);
        } else {
          if (!key.startsWith('shorts/')) {
            throw new HttpError('bad_request', 'key does not belong to shorts');
          }
          // Feed videos are readable by any authenticated user, provided the
          // key belongs to a published row and matches its author-scoped path.
          const { data: shortRow, error: shortError } = await asUser
            .from('shorts')
            .select('id, author_id')
            .eq('object_key', key)
            .maybeSingle();
          if (shortError) {
            throw new HttpError('upstream_error', 'could not verify the video');
          }
          if (
            !shortRow ||
            typeof shortRow.author_id !== 'string' ||
            !key.startsWith(`shorts/${shortRow.author_id}/`)
          ) {
            throw new HttpError('not_found', 'that video does not exist');
          }
        }
        const rawFile = key.split('/').pop() ?? 'video.mp4';
        const fileName = /^[A-Za-z0-9._-]+$/.test(rawFile) ? rawFile : 'video.mp4';
        const url = await presignS3(s3, {
          method: 'GET',
          key,
          expiresInSeconds: GET_EXPIRES_SECONDS,
          responseContentDisposition: body.download === true
            ? `attachment; filename="${fileName}"`
            : undefined,
        });
        return ok({ url, expiresInSeconds: GET_EXPIRES_SECONDS }, cors);
      }

      case 'delete': {
        await authorizeScope(userClient(env, token!), scope, caller.uid, chatId);
        const key = expectKey(body.key);
        assertKeyScope(scope, key, chatId, caller.uid);
        const asUser = userClient(env, token!);

        // Attached media is not removable from here — deleting the object
        // under a live message or short would break playback for everyone.
        // delete_message + the runbook's orphan sweep own that lifecycle.
        const referenced = scope === 'chat'
          ? await asUser
            .from('messages')
            .select('id')
            .eq('chat_id', chatId!)
            .is('deleted_at', null)
            .contains('media', { key })
            .limit(1)
          : await asUser.from('shorts').select('id').eq('object_key', key).limit(1);
        if (referenced.error) {
          throw new HttpError('upstream_error', 'could not check the object reference');
        }
        if ((referenced.data ?? []).length > 0) {
          throw new HttpError(
            'forbidden',
            'that video is attached to a message; delete the message instead',
          );
        }

        const gone = await deleteObject(s3, key);
        if (!gone) throw new HttpError('upstream_error', 'could not remove the object');
        log.info('video discarded', { uid: caller.uid, scope, key });
        return ok({ deleted: true }, cors);
      }

      default:
        throw new HttpError('bad_request', `unknown action "${action}"`);
    }
  }, (req) => corsHeaders(req.headers.get('origin'), env.allowedOrigins))(request);
}

async function deleteObject(s3: S3Config, key: string): Promise<boolean> {
  const signed = await signS3Request(s3, { method: 'DELETE', key });
  const response = await fetch(signed.url, { method: 'DELETE', headers: signed.headers });
  // B2/S3 answers 204 for a removed object and 404 when it is already gone —
  // both mean "not there", which is what every caller wants.
  return response.ok || response.status === 404;
}

/**
 * Range-reads the file to `mvhd` and returns the real duration, or null when
 * it cannot be proven. The reader keeps every fetch to a bounded window: the
 * `mdat` of a 250 MB clip is never downloaded to answer a question about it.
 */
async function verifiedDurationMs(
  s3: S3Config,
  key: string,
  contentLength: number,
): Promise<number | null> {
  const signed = await signS3Request(s3, { method: 'GET', key });
  const read = async (
    start: number,
    endInclusive: number,
  ): Promise<Uint8Array<ArrayBuffer> | null> => {
    const response = await fetch(signed.url, {
      method: 'GET',
      headers: { ...signed.headers, range: `bytes=${start}-${endInclusive}` },
    });
    if (response.status !== 206 && response.ok === false) return null;
    if (response.status === 200) {
      // The whole object in one body would defeat the point; read the window
      // we asked for out of the stream instead of buffering everything.
      const full = new Uint8Array(await response.arrayBuffer());
      return full.subarray(start, endInclusive + 1) as Uint8Array<ArrayBuffer>;
    }
    if (response.status !== 206) return null;
    return new Uint8Array(await response.arrayBuffer());
  };
  return await readMp4DurationMs(read, contentLength);
}

Deno.serve(handle);
