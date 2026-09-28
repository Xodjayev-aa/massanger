// Byte-level fixtures for the MP4 duration reader. The server re-verifies the
// same fields in `_shared/mp4_duration.ts` before any row may be written; this
// suite pins the client-side copy that makes the 60 s cap a pre-upload
// snackbar instead of a wasted 200 MB send.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/core/mp4.dart';

Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  final out = BytesBuilder();
  final header = ByteData(8)..setUint32(0, size);
  out.add(header.buffer.asUint8List());
  out.add(type.codeUnits);
  out.add(payload);
  return out.takeBytes();
}

Uint8List _ftyp() => _box(
      'ftyp',
      <int>[...('isom'.codeUnits), 0, 0, 0x02, 0, ...('isomiso2'.codeUnits)],
    );

/// A box whose size field is the 64-bit variant: `size == 1` means the real
/// length follows the type as a uint64 instead of living in the 32-bit field.
Uint8List _boxWide(String type, List<int> payload) {
  final size = 16 + payload.length;
  final out = BytesBuilder();
  final header = ByteData(16)..setUint32(0, 1)..setUint64(8, size);
  out.add(header.buffer.asUint8List());
  out.add(type.codeUnits);
  out.add(payload);
  return out.takeBytes();
}

Uint8List _mdat(int payloadBytes) => _box('mdat', List<int>.filled(payloadBytes, 0));

Uint8List _moov(Uint8List mvhd) => _box('moov', mvhd);

Uint8List _mvhdV0(int timescale, int duration) {
  final payload = ByteData(20);
  payload.setUint8(0, 0); // version 0
  payload.setUint32(12, timescale);
  payload.setUint32(16, duration);
  return _box('mvhd', payload.buffer.asUint8List());
}

Uint8List _concat(List<Uint8List> parts) {
  final out = BytesBuilder();
  for (final part in parts) {
    out.add(part);
  }
  return out.takeBytes();
}

void main() {
  group('readMp4Duration', () {
    test('reads a moov-first file without touching the media payload', () {
      final bytes = _concat(<Uint8List>[_ftyp(), _moov(_mvhdV0(600, 6000)), _mdat(64)]);
      expect(readMp4Duration(bytes), const Duration(seconds: 10));
    });

    test('walks over a large mdat to find moov at the end', () {
      // Phone recordings usually append moov after mdat; the reader must jump
      // by box size rather than scan, or a 200 MB file would be read twice.
      final bytes = _concat(<Uint8List>[_ftyp(), _mdat(200000), _moov(_mvhdV0(90000, 90000 * 42))]);
      expect(readMp4Duration(bytes), const Duration(seconds: 42));
    });

    test('returns null when there is no proof', () {
      expect(readMp4Duration(_concat(<Uint8List>[_ftyp(), _mdat(64)])), isNull, reason: 'no moov');
      expect(readMp4Duration(_concat(<Uint8List>[_ftyp(), _moov(_mvhdV0(0, 6000))])), isNull, reason: 'zero timescale');
      expect(
        readMp4Duration(_concat(<Uint8List>[_ftyp(), _moov(_mvhdV0(600, 0xFFFFFFFF))])),
        isNull,
        reason: 'unknown-duration marker',
      );
      expect(readMp4Duration(_concat(<Uint8List>[_ftyp(), _moov(_mvhdV0(600, 6000))]).sublist(0, 20)), isNull,
          reason: 'truncated');
      expect(readMp4Duration(Uint8List(4)), isNull, reason: 'too small');
    });

    test('reads a wide-size (64-bit length) moov box', () {
      final bytes = _concat(<Uint8List>[
        _ftyp(),
        _boxWide('moov', _mvhdV0(1000, 5000)),
        _mdat(64),
      ]);
      expect(readMp4Duration(bytes), const Duration(seconds: 5));
    });

    test('rejects a box that claims to extend past the file', () {
      final lying = Uint8List(32);
      final header = ByteData.sublistView(lying)..setUint32(0, 1 << 20);
      header.setUint32(4, 0x66747970); // 'ftyp'
      expect(readMp4Duration(lying), isNull);
    });

    test('rejects a box smaller than its own header', () {
      final hostile = Uint8List(64);
      final header = ByteData.sublistView(hostile)..setUint32(0, 4);
      header.setUint32(4, 0x66747970);
      expect(readMp4Duration(hostile), isNull);
    });
  });
}
