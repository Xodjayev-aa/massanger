/**
 * Media helpers.
 *
 * Constraints that actually matter on the wire:
 *   • Telegram voice notes are OGG/Opus. The app records `audio/ogg;
 *     codecs=opus` (record ^5 oggOpus) — anything else is sent as a document
 *     style audio rather than silently corrupting the voice-note bubble.
 *   • The waveform TDLib expects is 5–100 bytes of 0–100 amplitudes (the
 *     "51-bar" visualisation). We normalise whatever the client produced.
 *   • Photo sizes come from TDLib metadata, but for client uploads we parse the
 *     image header ourselves rather than decode pixels.
 */

import { mkdir, rm, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

export const OGG_OPUS_MIMES = new Set(['audio/ogg', 'audio/opus', 'application/ogg']);
export const IMAGE_MIMES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/avif']);

export const mimeForPath = (value: string): string => {
  const ext = path.extname(value).toLowerCase();
  switch (ext) {
    case '.ogg':
    case '.oga':
      return 'audio/ogg';
    case '.opus':
      return 'audio/opus';
    case '.mp3':
      return 'audio/mpeg';
    case '.m4a':
    case '.mp4':
    case '.aac':
      return 'audio/mp4';
    case '.webm':
      return 'audio/webm';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.webp':
      return 'image/webp';
    case '.gif':
      return 'image/gif';
    case '.avif':
      return 'image/avif';
    case '.pdf':
      return 'application/pdf';
    default:
      return 'application/octet-stream';
  }
};

export const isVoiceMime = (mime: string | undefined): boolean =>
  !!mime && (OGG_OPUS_MIMES.has(mime) || mime === 'audio/opus');

export const isImageMime = (mime: string | undefined): boolean => !!mime && IMAGE_MIMES.has(mime);

/** TDLib wants 5..100 bytes, each 0..100. */
export function normalizeWaveform(input: unknown, bars = 64): number[] {
  const source = Array.isArray(input) ? input.map((value) => Number(value)).filter(Number.isFinite) : [];
  if (source.length === 0) {
    // A flat, visible bar is friendlier than an empty array (which TDLib rejects).
    return new Array(51).fill(35);
  }
  const peak = Math.max(...source, 1);
  const stretched = new Array<number>(bars);
  for (let index = 0; index < bars; index++) {
    const position = (index / (bars - 1 || 1)) * (source.length - 1);
    const low = Math.floor(position);
    const high = Math.min(source.length - 1, low + 1);
    const weight = position - low;
    stretched[index] = Math.round((((source[low] ?? 0) * (1 - weight) + (source[high] ?? 0) * weight) / peak) * 100);
  }
  const clipped = stretched.map((value) => Math.max(1, Math.min(100, value)));
  if (clipped.length <= 100) return clipped;
  // TDLib caps at 100 bars: keep the envelope, not the head of the array.
  const step = clipped.length / 100;
  return Array.from({ length: 100 }, (_, index) => {
    const from = Math.floor(index * step);
    const to = Math.max(from + 1, Math.floor((index + 1) * step));
    return Math.max(...clipped.slice(from, to));
  });
}

export const waveformToBase64 = (values: number[]): string =>
  Buffer.from(new Uint8Array(values)).toString('base64');

export type ImageDimensions = { width: number; height: number } | null;

/**
 * Header-only image sizing (PNG / JPEG / GIF / WebP / BMP). Deliberately not a
 * decoder: we need numbers for `messages.media`, not pixels.
 */
export function imageSize(bytes: Uint8Array): ImageDimensions {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const at = (offset: number, length: number): number => {
    let value = 0;
    for (let i = 0; i < length; i++) value = (value << 8) | (bytes[offset + i] ?? 0);
    return value >>> 0;
  };

  if (bytes.byteLength < 16) return null;

  // PNG: IHDR at fixed offset, big-endian.
  if (at(0, 8) === 0x89504e47 && bytes[12] === 0x49 /* I */) {
    return { width: view.getUint32(16, false), height: view.getUint32(20, false) };
  }
  // GIF: little-endian 16-bit logical screen descriptor.
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
    return { width: view.getUint16(6, true), height: view.getUint16(8, true) };
  }
  // WEBP: RIFF....WEBP + VP8/VP8L/VP8X
  if (at(0, 4) === 0x52494646 && at(8, 4) === 0x57454250) {
    const flavor = at(12, 4);
    if (flavor === 0x56503858 /* VP8X */) {
      // 24-bit little-endian "canvas minus one" fields at offsets 24 and 27.
      const le24 = (offset: number): number =>
        (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8) | ((bytes[offset + 2] ?? 0) << 16);
      return { width: 1 + le24(24), height: 1 + le24(27) };
    }
    if (flavor === 0x56503820 /* VP8 */) {
      return { width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff };
    }
    return null;
  }
  // JPEG: walk the marker chain until a start-of-frame is found.
  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < bytes.byteLength) {
      if (bytes[offset] !== 0xff) {
        offset++;
        continue;
      }
      const marker = bytes[offset + 1] ?? 0;
      const isSof = marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
      if (isSof) {
        return { height: view.getUint16(offset + 5, false), width: view.getUint16(offset + 7, false) };
      }
      offset += 2 + view.getUint16(offset + 2, false);
    }
  }
  return null;
}

/** Writes bytes to the bridge's temp dir and returns the path TDLib reads from. */
export async function writeTempFile(directory: string, name: string, bytes: Uint8Array): Promise<string> {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const target = path.join(directory, `${Date.now()}-${randomUUID()}-${name.replace(/[^\w.-]+/g, '_')}`);
  await writeFile(target, bytes, { mode: 0o600 });
  return target;
}

export const removeIfExists = async (target: string | null | undefined): Promise<void> => {
  if (!target) return;
  await rm(target, { force: true }).catch(() => undefined);
};

export const formatBytes = (bytes: number): string => {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KiB', 'MiB', 'GiB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
};

/** Telegram's voice-note length cap; anything longer is refused by the server. */
export const MAX_VOICE_SECONDS = 300;

export function clampDurationMs(durationMs: number | undefined, maxSeconds = MAX_VOICE_SECONDS): number {
  const value = Number.isFinite(durationMs ?? NaN) ? Number(durationMs) : 0;
  return Math.max(100, Math.min(Math.round(value), maxSeconds * 1000));
}
