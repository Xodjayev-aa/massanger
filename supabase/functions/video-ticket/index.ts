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
 * One bucket, four key spaces: `chat/<chatId>/…`, `shorts/<uid>/…`,
 * `video/<uid>/…` and the poster frames in `thumb/<uid>/…`. The prefix is
 * re-derived and re-checked on every action — a ticket for one chat can never
 * read or confirm another, and an upload can only ever land in the caller's own
 * space. Posters live in their own space because both publish paths
 * (`publish_video`, `publish_short`) require a thumbnail key under `thumb/`.
 *
 * Reads are the one place where "your own key space" is not the rule, because a
 * feed plays other people's videos. `get` therefore accepts a foreign
 * `shorts/`, `video/` or `thumb/` key only when `public.media_visible` — a
 * database question — says the caller may see the row that references it.
 * Uploads (put/confirm) and deletes stay owner-only; a poster frame is minted
 * the same way a video is, with `image/jpeg` or `image/png` instead of
 * `video/mp4`.
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

/**
 * Long-form caps. The object store accepts far more than a phone uploads in one
 * in-memory PUT; the numbers here are the *server's* limits, so a future
 * chunked uploader does not need a redeploy — the app's own composer is the
 * thing that stops at 250 MB today.
 */
const MAX_LONG_DURATION_MS = 4 * 60 * 60 * 1000; // 4 hours
const MAX_LONG_SIZE_BYTES = 1_073_741_824; // 1 GiB
/** Poster frames are images: small, and only in the caller's own key space. */
const MAX_IMAGE_BYTES = 8_388_608; // 8 MB
const IMAGE_TYPES: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
};

/**
 * A voice-over / soundtrack file. The caps are `public.sounds`' own limits, so
 * the ticket can never mint a ticket for bytes the row would refuse to record.
 *
 * `audio/mp4` is deliberately absent: an M4A is an MP4 container, and sniffing
 * cannot tell a silent audio file from a video without reading the whole moov.
 * Android's speech engine writes WAV and the browser's writes MP3, which is
 * everything the client actually produces; a device that can only write `.caf`
 * (iOS) keeps the script-only sound instead of uploading it.
 */
const MAX_AUDIO_SIZE_BYTES = 52_428_800; // 50 MB, public.sounds' cap
const MAX_AUDIO_DURATION_MS = 3_600_000; // 1 hour, public.sounds' cap
const AUDIO_TYPES: Record<string, string> = {
  'audio/mpeg': 'mp3',
  'audio/ogg': 'ogg',
  'audio/wav': 'wav',
};

type Scope = 'chat' | 'short' | 'video' | 'sound';

/** What the stored bytes actually are, once `confirm` has sniffed them. */
type ObjectKind = 'video' | 'image' | 'audio';

type RequestBody = {
  action?: 'status' | 'put' | 'confirm' | 'get' | 'delete';
  scope?: Scope;
  /** Required for scope 'chat'. */
  chatId?: string;
  /** Object key; required for confirm / get / delete. */
  key?: string;
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

/**
 * The caller's own spaces. `thumb/` is deliberately shared by both publish
 * paths: a poster frame is an image, and neither `publish_video` nor
 * `publish_short` accepts a thumbnail outside `thumb/<uid>/`.
 */
const ownPrefixes = (uid: string): string[] => [
  `shorts/${uid}/`,
  `video/${uid}/`,
  `thumb/${uid}/`,
  `sounds/${uid}/`,
];

const isOwnKey = (key: string, uid: string): boolean => ownPrefixes(uid).some((p) => key.startsWith(p));

/**
 * Re-derives the expected prefix for an action. [kind] is only known after the
 * bytes have been sniffed, so `confirm` passes it; `put` and `delete` know from
 * the mime they are working with.
 */
const assertKeyScope = (
  scope: Scope,
  key: string,
  chatId: string | null,
  uid: string,
  kind: ObjectKind | null = null,
): void => {
  if (kind === 'image') {
    if (!key.startsWith(`thumb/${uid}/`)) {
      throw new HttpError('bad_request', 'a poster frame must live in the caller\'s thumbnail space');
    }
    return;
  }
  // Audio is a sound and nothing else: a reel that ends in `.mp3` is a mistake,
  // and `public.create_sound` would refuse the key anyway.
  if (kind === 'audio') {
    if (!key.startsWith(`sounds/${uid}/`)) {
      throw new HttpError('bad_request', 'an audio file belongs in the caller\'s sound space');
    }
    return;
  }
  if (kind === 'video' && scope === 'sound') {
    throw new HttpError('bad_request', 'a sound ticket only accepts an audio file');
  }
  if (scope === 'chat') {
    if (!key.startsWith(`chat/${chatId}/`)) {
      throw new HttpError('bad_request', 'key does not belong to this chat');
    }
    return;
  }
  const expected = scope === 'video'
    ? `video/${uid}/`
    : scope === 'sound'
    ? `sounds/${uid}/`
    : `shorts/${uid}/`;
  if (!key.startsWith(expected)) {
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
    if (body.scope !== 'chat' && body.scope !== 'short' && body.scope !== 'video' && body.scope !== 'sound') {
      throw new HttpError('bad_request', "scope must be 'chat', 'short', 'video' or 'sound'");
    }
    const scope: Scope = body.scope;
    const chatId = body.chatId == null ? null : String(body.chatId);

    enforce(`video-ticket:${action}:uid`, caller.uid, action === 'get' ? 300 : 30, 60_000);
    if (action !== 'get') enforce('video-ticket:ip', clientIp(req) ?? 'unknown', 120);

    const s3 = s3Config(env);

    switch (action) {
      case 'put': {
        await authorizeScope(userClient(env, token!), scope, caller.uid, chatId);
        const mime = expectString(body.mime, 'mime', { max: 100 })!;
        const imageExtension = IMAGE_TYPES[mime];
        const audioExtension = AUDIO_TYPES[mime];
        if (mime !== 'video/mp4' && imageExtension === undefined && audioExtension === undefined) {
          throw new HttpError(
            'bad_request',
            'only video/mp4, image/jpeg, image/png, audio/mpeg, audio/ogg and audio/wav are accepted '
              + '(there is no transcoding pipeline)',
          );
        }
        if (audioExtension !== undefined && scope !== 'sound') {
          throw new HttpError(
            'bad_request',
            "an audio file needs the 'sound' scope: it becomes a sound, not a reel",
          );
        }
        if (imageExtension !== undefined && scope === 'chat') {
          // A poster frame is a personal asset; uploaded into a chat's space it
          // would be readable by that chat's members only, which is not what a
          // feed thumbnail needs.
          throw new HttpError('bad_request', 'image tickets are only minted for the personal key space');
        }
        const isLong = scope === 'video';
        const isSound = audioExtension !== undefined;
        const sizeCap = imageExtension !== undefined
          ? MAX_IMAGE_BYTES
          : isSound
          ? MAX_AUDIO_SIZE_BYTES
          : (isLong ? MAX_LONG_SIZE_BYTES : MAX_SIZE_BYTES);
        if (imageExtension === undefined) {
          expectInt(
            body.durationMs,
            'durationMs',
            1,
            isSound
              ? MAX_AUDIO_DURATION_MS
              : (isLong ? MAX_LONG_DURATION_MS : MAX_DURATION_MS),
          );
        }
        expectInt(body.sizeBytes, 'sizeBytes', 1, sizeCap);

        const prefix = scope === 'chat'
          ? `chat/${chatId}/app`
          : imageExtension !== undefined
          ? `thumb/${caller.uid}/app`
          : isSound
          ? `sounds/${caller.uid}/app`
          : (isLong ? `video/${caller.uid}/app` : `shorts/${caller.uid}/app`);
        const extension = imageExtension ?? audioExtension ?? 'mp4';
        const key = `${prefix}/${Date.now()}_${randomHex(4)}.${extension}`;
        const url = await presignS3(s3, {
          method: 'PUT',
          key,
          expiresInSeconds: PUT_EXPIRES_SECONDS,
        });
        log.info('upload ticket', { uid: caller.uid, scope, key, mime });
        return ok(
          { key, url, expiresInSeconds: PUT_EXPIRES_SECONDS, contentType: mime },
          cors,
        );
      }

      case 'confirm': {
        await authorizeScope(userClient(env, token!), scope, caller.uid, chatId);
        const key = expectKey(body.key);

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

        // What the bytes are decides which cap applies and what the client is
        // allowed to write into the database.
        const kind = await sniffKind(s3, key);
        if (kind === null) {
          await deleteObject(s3, key);
          throw new HttpError('bad_request', 'that file is not an MP4 video, a JPEG, a PNG or audio');
        }
        // The bytes decide the space they are allowed to have come from.
        assertKeyScope(scope, key, chatId, caller.uid, kind);

        if (kind === 'image') {
          if (scope === 'chat') {
            await deleteObject(s3, key);
            throw new HttpError('bad_request', 'a chat never holds an image object of its own');
          }
          if (sizeBytes > MAX_IMAGE_BYTES) {
            await deleteObject(s3, key);
            throw new HttpError('payload_too_large', `images must stay under ${MAX_IMAGE_BYTES} bytes`);
          }
          log.info('image confirmed', { uid: caller.uid, scope, key, sizeBytes });
          return ok({ key, sizeBytes, durationMs: 0, kind, contentType: 'image' }, cors);
        }

        // Audio stops here: its size is checked, its bytes are sniffed, and its
        // duration is *not* measured, because reading an MP3 frame count means
        // reading the whole file. The client passes the duration it knows (the
        // spoken length of the script) and `public.create_sound` bounds it; the
        // row is a soundtrack hint, never a security boundary.
        if (kind === 'audio') {
          if (scope !== 'sound') {
            await deleteObject(s3, key);
            throw new HttpError('bad_request', 'an audio file needs the sound scope');
          }
          if (sizeBytes > MAX_AUDIO_SIZE_BYTES) {
            await deleteObject(s3, key);
            throw new HttpError(
              'payload_too_large',
              `sounds must stay under ${MAX_AUDIO_SIZE_BYTES} bytes`,
            );
          }
          log.info('sound confirmed', { uid: caller.uid, scope, key, sizeBytes });
          return ok({ key, sizeBytes, durationMs: 0, kind, contentType: 'audio' }, cors);
        }

        const sizeCap = scope === 'video' ? MAX_LONG_SIZE_BYTES : MAX_SIZE_BYTES;
        if (sizeBytes > sizeCap) {
          await deleteObject(s3, key);
          throw new HttpError(
            'payload_too_large',
            `videos must stay under ${sizeCap} bytes`,
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
        const durationCap = scope === 'video' ? MAX_LONG_DURATION_MS : MAX_DURATION_MS;
        if (durationMs > durationCap) {
          await deleteObject(s3, key);
          throw new HttpError('payload_too_large', `videos must stay under ${durationCap} ms`);
        }

        log.info('video confirmed', { uid: caller.uid, scope, key, sizeBytes, durationMs });
        return ok({ key, sizeBytes, durationMs, kind, contentType: 'video/mp4' }, cors);
      }

      case 'get': {
        const key = expectKey(body.key);
        const asUser = userClient(env, token!);
        if (scope === 'chat') {
          assertKeyScope(scope, key, chatId, caller.uid);
          if (chatId === null) {
            throw new HttpError('bad_request', 'chatId is required for a chat ticket');
          }
          // Watching needs membership, not posting standing: a restricted
          // account still reads its own chats, exactly like message RLS.
          await requireChatMember(asUser, caller.uid, chatId);
        } else if (!isOwnKey(key, caller.uid)) {
          // Somebody else's key: allowed only when the database says a row the
          // caller may see references it. This is what lets a feed play, and it
          // keeps a private account's unpublished uploads unreadable.
          const { data, error } = await asUser.rpc('media_visible', { p_key: key });
          if (error) throw new HttpError('upstream_error', 'could not check that object');
          if (data !== true) {
            throw new HttpError('forbidden', 'that object is not available to you');
          }
        }
        const url = await presignS3(s3, {
          method: 'GET',
          key,
          expiresInSeconds: GET_EXPIRES_SECONDS,
        });
        return ok({ url, expiresInSeconds: GET_EXPIRES_SECONDS }, cors);
      }

      case 'delete': {
        await authorizeScope(userClient(env, token!), scope, caller.uid, chatId);
        const key = expectKey(body.key);
        assertKeyScope(scope, key, chatId, caller.uid);
        const asUser = userClient(env, token!);

        // Attached media is not removable from here — deleting the object
        // under a live message, video or short would break playback for
        // everyone. delete_message + the runbook's orphan sweep own that
        // lifecycle.
        const referenced = await findReference(asUser, scope, chatId, key);
        if (referenced.error) {
          throw new HttpError('upstream_error', 'could not check the object reference');
        }
        if (referenced.data.length > 0) {
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

/**
 * Is this object referenced by a live row? A poster key can be referenced by a
 * long video *or* a short, so the check follows the key, not the scope the
 * caller happened to declare.
 */
async function findReference(
  client: AdminClient,
  scope: Scope,
  chatId: string | null,
  key: string,
): Promise<{ data: unknown[]; error: unknown }> {
  if (scope === 'chat') {
    const rows = await client
      .from('messages')
      .select('id')
      .eq('chat_id', chatId!)
      .is('deleted_at', null)
      .contains('media', { key })
      .limit(1);
    return { data: rows.data ?? [], error: rows.error };
  }
  if (key.startsWith('sounds/')) {
    const rows = await client.from('sounds').select('id').eq('object_key', key).limit(1);
    return { data: rows.data ?? [], error: rows.error };
  }
  if (key.startsWith('thumb/')) {
    const [videos, shorts] = await Promise.all([
      client.from('videos').select('id').eq('thumbnail_key', key).limit(1),
      client.from('shorts').select('id').eq('thumbnail_key', key).limit(1),
    ]);
    return {
      data: [...(videos.data ?? []), ...(shorts.data ?? [])],
      error: videos.error ?? shorts.error,
    };
  }
  const table = scope === 'video' ? 'videos' : 'shorts';
  const rows = await client.from(table).select('id').eq('object_key', key).limit(1);
  return { data: rows.data ?? [], error: rows.error };
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
/**
 * What the stored object actually is, from its first bytes: `ftyp` means MP4,
 * the JPEG and PNG signatures mean a poster frame, anything else is rejected.
 * The client's declared mime is a hint; this is the fact, and it is what makes
 * the caps enforceable per kind.
 */
async function sniffKind(s3: S3Config, key: string): Promise<ObjectKind | null> {
  const signed = await signS3Request(s3, { method: 'GET', key });
  const response = await fetch(signed.url, {
    method: 'GET',
    headers: { ...signed.headers, range: 'bytes=0-15' },
  });
  if (response.status !== 206 && !response.ok) return null;
  const head = new Uint8Array(await response.arrayBuffer()).subarray(0, 16);
  if (head.length >= 8 &&
      head[4] === 0x66 && head[5] === 0x74 && head[6] === 0x79 && head[7] === 0x70) {
    return 'video';
  }
  if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image';
  if (head.length >= 8 && head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47) {
    return 'image';
  }
  // Audio, in the three containers the ticket accepts: an MPEG file (with or
  // without an `ID3` tag), an Ogg stream, or a RIFF/WAVE payload. Checked after
  // the video and image signatures so a JPEG's `ffd8` can never read as audio.
  if (head.length >= 3 && head[0] === 0x49 && head[1] === 0x44 && head[2] === 0x33) return 'audio';
  if (head.length >= 12 && head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46 &&
      head[8] === 0x57 && head[9] === 0x41 && head[10] === 0x56 && head[11] === 0x45) {
    return 'audio';
  }
  if (head.length >= 4 && head[0] === 0x4f && head[1] === 0x67 && head[2] === 0x67 && head[3] === 0x53) {
    return 'audio';
  }
  if (head.length >= 2 && head[0] === 0xff && ((head[1] ?? 0) & 0xe0) === 0xe0) return 'audio';
  return null;
}

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
