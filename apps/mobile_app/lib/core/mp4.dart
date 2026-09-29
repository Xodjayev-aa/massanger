import 'dart:typed_data';

/// Largest 64-bit box size the walk will honour.
///
/// mp4's `size == 1` escape hatch stores a uint64, so a hostile header can
/// claim any length up to 2^64-1; we need a bound that rejects nonsense while
/// keeping the arithmetic exact. It has to stay at or below 2^53-1 because the
/// web build represents `int` as a JS double, and dart2js *rejects* integer
/// literals it cannot represent exactly — a wider cap would not compile.
/// Real uploads are capped far below this either way (see video_limits.dart).
const int _maxWideBoxSize = 0x1FFFFFFFFFFFFF; // 2^53 - 1

/// Reads the movie duration straight out of an MP4 (ISO-BMFF) container.
///
/// The composer needs the duration *before* the upload starts — the 60 s cap
/// should cost a snackbar, not 200 MB of bandwidth — and `XFile` has no length
/// for the format itself, only bytes. So the `moov`/`mvhd` walk happens here,
/// in pure Dart, identically on mobile and on the web.
///
/// This is the fast, friendly check. The authoritative one is the server:
/// `video-ticket confirm` re-reads the same fields from the stored bytes
/// (`supabase/functions/_shared/mp4_duration.ts`), because a declared duration
/// is a hint and the cap has to survive an adversarial client.
Duration? readMp4Duration(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final data = ByteData.sublistView(bytes);

  int offset = 0;
  // Bounded walk: a hostile file of tiny boxes must not spin forever.
  for (var hop = 0; hop < 32; hop++) {
    if (bytes.length - offset < 8) return null;
    var size = data.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    var headerSize = 8;
    if (size == 1) {
      if (bytes.length - offset < 16) return null;
      final wide = data.getUint64(offset + 8);
      if (wide > _maxWideBoxSize) return null;
      size = wide;
      headerSize = 16;
    } else if (size == 0) {
      size = bytes.length - offset;
    }
    if (size < headerSize || offset + size > bytes.length) return null;
    if (type == 'moov') return _mvhdDuration(bytes, offset, size, headerSize);
    offset += size;
  }
  return null;
}

Duration? _mvhdDuration(Uint8List bytes, int start, int size, int headerSize) {
  final data = ByteData.sublistView(bytes);
  final end = start + size;
  var pos = start + headerSize;
  while (pos + 8 <= end) {
    var childSize = data.getUint32(pos);
    final childType = String.fromCharCodes(bytes, pos + 4, pos + 8);
    var childHeader = 8;
    if (childSize == 1) {
      if (pos + 16 > end) return null;
      final wide = data.getUint64(pos + 8);
      if (wide > _maxWideBoxSize) return null;
      childSize = wide;
      childHeader = 16;
    } else if (childSize == 0) {
      childSize = end - pos;
    }
    if (childSize < childHeader || pos + childSize > end) return null;

    if (childType == 'mvhd') {
      final payload = pos + childHeader;
      final version = bytes[payload];
      final int timescale;
      final int duration;
      if (version == 1) {
        if (payload + 32 > end) return null;
        timescale = data.getUint32(payload + 20);
        final wide = data.getUint64(payload + 24);
        if (wide > _maxWideBoxSize) return null;
        duration = wide;
      } else {
        if (payload + 20 > end) return null;
        timescale = data.getUint32(payload + 12);
        duration = data.getUint32(payload + 16);
      }
      // 0xFFFFFFFF is the spec's "unknown duration"; a zero timescale would
      // divide by zero. Neither is a duration we can enforce a cap against.
      if (timescale <= 0 || duration == 0 || duration == 0xFFFFFFFF) return null;
      final microseconds = duration * 1000000 ~/ timescale;
      if (microseconds <= 0) return null;
      return Duration(microseconds: microseconds);
    }
    pos += childSize;
  }
  return null;
}
