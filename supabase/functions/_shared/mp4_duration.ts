/**
 * Server-side MP4 (ISO-BMFF) duration reader for `video-ticket confirm`.
 *
 * The client declares `duration_ms` before it uploads, but a declared number is
 * not a cap: an adversarial client could announce one second and push a
 * fifteen-minute file into the feed. The confirm step therefore verifies the
 * *actual* bytes: size via HEAD, duration via this reader, and only those
 * verified numbers are allowed into `messages.media` / `shorts`.
 *
 * The reader walks top-level boxes with HTTP range reads (the `moov` atom is
 * often at the *end* of a recording, after a multi-hundred-megabyte `mdat`, so
 * buffering the file to parse it is not an option) and then scans `moov` for
 * `mvhd`. It returns `null` for anything it cannot prove — confirm turns that
 * into a rejected upload rather than an unverifiable clip.
 */

/** Reads bytes [start, endInclusive] of an object; null when unreadable. */
export type RangeReader = (
  start: number,
  endInclusive: number,
) => Promise<Uint8Array<ArrayBuffer> | null>;

export type Mp4DurationOptions = {
  /** Maximum top-level boxes to inspect before giving up (cycle guard). */
  maxHops?: number;
  /** Largest `moov` we will download to find `mvhd` (real ones are ~KBs). */
  maxMoovBytes?: number;
};

const DEFAULT_MAX_HOPS = 32;
const DEFAULT_MAX_MOOV = 1 << 20; // 1 MiB

const ascii = (bytes: Uint8Array, from: number, to: number): string =>
  String.fromCharCode(...bytes.subarray(from, to));

/** Reads the duration in milliseconds, or null when it cannot be proven. */
export async function readMp4DurationMs(
  read: RangeReader,
  contentLength: number,
  options: Mp4DurationOptions = {},
): Promise<number | null> {
  const maxHops = options.maxHops ?? DEFAULT_MAX_HOPS;
  const maxMoovBytes = options.maxMoovBytes ?? DEFAULT_MAX_MOOV;
  if (!Number.isFinite(contentLength) || contentLength < 16) return null;

  let offset = 0;
  for (let hop = 0; hop < maxHops; hop++) {
    if (contentLength - offset < 8) return null;
    const head = await read(offset, offset + 15);
    if (!head || head.length < 8) return null;
    const view = new DataView(head.buffer, head.byteOffset, head.byteLength);
    let size = view.getUint32(0);
    const type = ascii(head, 4, 8);
    let headerSize = 8;
    if (size === 1) {
      if (head.length < 16) return null;
      const wide = view.getBigUint64(8);
      if (wide > BigInt(Number.MAX_SAFE_INTEGER)) return null;
      size = Number(wide);
      headerSize = 16;
    } else if (size === 0) {
      size = contentLength - offset;
    }
    if (size < headerSize || offset + size > contentLength) return null;
    if (type === 'moov') {
      return await readMoovDuration(read, offset, size, headerSize, maxMoovBytes);
    }
    offset += size;
  }
  return null;
}

async function readMoovDuration(
  read: RangeReader,
  start: number,
  size: number,
  headerSize: number,
  maxMoovBytes: number,
): Promise<number | null> {
  if (size > maxMoovBytes) return null;
  const box = await read(start, start + size - 1);
  if (!box || box.length < headerSize + 8) return null;
  const view = new DataView(box.buffer, box.byteOffset, box.byteLength);

  let pos = headerSize;
  while (pos + 8 <= box.length) {
    let childSize = view.getUint32(pos);
    const childType = ascii(box, pos + 4, pos + 8);
    let childHeader = 8;
    if (childSize === 1) {
      if (pos + 16 > box.length) return null;
      const wide = view.getBigUint64(pos + 8);
      if (wide > BigInt(Number.MAX_SAFE_INTEGER)) return null;
      childSize = Number(wide);
      childHeader = 16;
    } else if (childSize === 0) {
      childSize = box.length - pos;
    }
    if (childSize < childHeader || pos + childSize > box.length) return null;

    if (childType === 'mvhd') {
      const payload = pos + childHeader;
      const version = box[payload] ?? 0;
      let timescale: number;
      let duration: number;
      if (version === 1) {
        if (payload + 32 > box.length) return null;
        timescale = view.getUint32(payload + 20);
        const wideDuration = view.getBigUint64(payload + 24);
        if (wideDuration > BigInt(Number.MAX_SAFE_INTEGER)) return null;
        duration = Number(wideDuration);
      } else {
        if (payload + 20 > box.length) return null;
        timescale = view.getUint32(payload + 12);
        duration = view.getUint32(payload + 16);
      }
      // 0xFFFFFFFF is the spec's "unknown duration" marker; a zero timescale
      // would divide by zero, and neither is something we can verify against.
      if (timescale <= 0 || duration === 0 || duration === 0xFFFFFFFF) return null;
      const ms = Math.round((duration * 1000) / timescale);
      return Number.isFinite(ms) && ms > 0 ? ms : null;
    }
    pos += childSize;
  }
  return null;
}
