import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { readMp4DurationMs } from '../../supabase/functions/_shared/mp4_duration.ts';

/**
 * Fixture builder: an ISO-BMFF file made of four boxes with exactly the
 * structure the reader walks — size-prefixed, big-endian, `mvhd` inside
 * `moov` with timescale + duration. Real recordings put `moov` before or
 * after `mdat` depending on the recorder, which is why both orders appear
 * below (the reader must not download a 200 MB `mdat` to answer).
 */
const box = (type, payload) => {
  const size = 8 + payload.length;
  const header = Buffer.alloc(8);
  header.writeUInt32BE(size, 0);
  header.write(type, 4, 'ascii');
  return Buffer.concat([header, payload]);
};

const ftyp = () =>
  box(
    'ftyp',
    Buffer.from([0x69, 0x73, 0x6f, 0x6d, 0, 0, 0x02, 0, 0x69, 0x73, 0x6f, 0x6d, 0x69, 0x73, 0x6f, 0x32]),
  );

const mdat = (payloadBytes) => box('mdat', Buffer.alloc(payloadBytes));

const mvhdV0 = (timescale, duration) => {
  const payload = Buffer.alloc(20);
  payload.writeUInt8(0, 0); // version 0
  payload.writeUInt8(0, 1); // flags
  payload.writeUInt32BE(0, 4); // creation
  payload.writeUInt32BE(0, 8); // modification
  payload.writeUInt32BE(timescale, 12);
  payload.writeUInt32BE(duration, 16);
  return box('mvhd', payload);
};

const mvhdV1 = (timescale, duration) => {
  const payload = Buffer.alloc(32);
  payload.writeUInt8(1, 0); // version 1
  payload.writeUInt32BE(0, 4); // creation (8 bytes, zeroed)
  payload.writeUInt32BE(0, 12); // modification (8 bytes, zeroed)
  payload.writeUInt32BE(timescale, 20);
  payload.writeBigUInt64BE(BigInt(duration), 24);
  return box('mvhd', payload);
};

const moov = (mvhd) => box('moov', mvhd);

/** Range reader over an in-memory file; records the windows it was asked for. */
const readerOver = (bytes) => {
  const reads = [];
  const read = async (start, endInclusive) => {
    reads.push([start, endInclusive]);
    if (start < 0 || start > bytes.length) return null;
    return new Uint8Array(bytes.subarray(start, Math.min(endInclusive + 1, bytes.length)));
  };
  return { read, reads };
};

describe('mp4_duration', () => {
  it('reads duration from a moov-first file', async () => {
    const file = Buffer.concat([ftyp(), moov(mvhdV0(600, 6000)), mdat(64)]);
    const { read, reads } = readerOver(file);
    assert.equal(await readMp4DurationMs(read, file.length), 10_000);
    // The reader must never touch the mdat payload.
    assert.ok(reads.every(([start, end]) => start < 16 + 8 + 20), 'no read reaches into mdat');
  });

  it('walks over a large mdat to find moov at the end', async () => {
    const file = Buffer.concat([ftyp(), mdat(200_000), moov(mvhdV0(90_000, 90_000 * 42))]);
    const { read, reads } = readerOver(file);
    assert.equal(await readMp4DurationMs(read, file.length), 42_000);
    const bytesFetched = reads.reduce((sum, [start, end]) => sum + (end - start + 1), 0);
    assert.ok(bytesFetched < 4096, `range reads stay tiny, got ${bytesFetched} bytes`);
  });

  it('parses mvhd version 1 (64-bit duration)', async () => {
    const file = Buffer.concat([ftyp(), moov(mvhdV1(1000, 30_000))]);
    const { read } = readerOver(file);
    assert.equal(await readMp4DurationMs(read, file.length), 30_000);
  });

  it('honours 64-bit extended box sizes in the top-level walk', async () => {
    // free box with a 64-bit size (size == 1 marker + u64), then moov.
    const free = (() => {
      const payload = Buffer.alloc(40);
      const header = Buffer.alloc(16);
      header.writeUInt32BE(1, 0); // wide size marker
      header.write('free', 4, 'ascii');
      header.writeBigUInt64BE(BigInt(16 + 40), 8);
      return Buffer.concat([header, payload]);
    })();
    const file = Buffer.concat([ftyp(), free, moov(mvhdV0(600, 1200))]);
    const { read } = readerOver(file);
    assert.equal(await readMp4DurationMs(read, file.length), 2000);
  });

  it('returns null for files it cannot prove', async () => {
    const noMoov = Buffer.concat([ftyp(), mdat(64)]);
    const { read: r1 } = readerOver(noMoov);
    assert.equal(await readMp4DurationMs(r1, noMoov.length), null);

    const zeroTimescale = Buffer.concat([ftyp(), moov(mvhdV0(0, 6000))]);
    const { read: r2 } = readerOver(zeroTimescale);
    assert.equal(await readMp4DurationMs(r2, zeroTimescale.length), null);

    const unknownDuration = Buffer.concat([ftyp(), moov(mvhdV0(600, 0xFFFFFFFF))]);
    const { read: r3 } = readerOver(unknownDuration);
    assert.equal(await readMp4DurationMs(r3, unknownDuration.length), null);

    const truncated = Buffer.concat([ftyp(), moov(mvhdV0(600, 6000))]).subarray(0, 20);
    const { read: r4 } = readerOver(truncated);
    assert.equal(await readMp4DurationMs(r4, truncated.length), null);

    // A box that claims to extend past the file is corruption, not a duration.
    const lying = Buffer.alloc(32);
    lying.writeUInt32BE(1 << 20, 0);
    lying.write('ftyp', 4, 'ascii');
    const { read: r5 } = readerOver(lying);
    assert.equal(await readMp4DurationMs(r5, lying.length), null);
  });

  it('refuses to walk forever through a hostile box sequence', async () => {
    // Repeating 8-byte zero boxes: size 0 means "to EOF", which would loop
    // without the hop budget if the walker mis-validated; a size-4 box (smaller
    // than its header) must terminate immediately instead.
    const hostile = Buffer.alloc(64);
    hostile.writeUInt32BE(4, 0);
    hostile.write('ftyp', 4, 'ascii');
    const { read } = readerOver(hostile);
    assert.equal(await readMp4DurationMs(read, hostile.length), null);
  });
});
