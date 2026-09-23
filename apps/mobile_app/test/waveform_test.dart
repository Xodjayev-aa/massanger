import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/core/waveform.dart';

void main() {
  group('fromDbfs', () {
    test('always produces exactly 64 buckets', () {
      expect(Waveform.fromDbfs(<double>[]).length, Waveform.buckets);
      expect(Waveform.fromDbfs(<double>[-20]).length, Waveform.buckets);
      expect(Waveform.fromDbfs(List<double>.filled(500, -12)).length, Waveform.buckets);
    });

    test('silence is a flat floor, not an empty bubble', () {
      final values = Waveform.fromDbfs(List<double>.filled(40, -96));
      expect(values.every((value) => value == Waveform.floorValue), isTrue);
    });

    test('the loudest sample sets the scale, not full scale', () {
      // -6 dBFS is the peak here: it must reach the top of the range even though it
      // is nowhere near 0 dBFS, or a quiet room would render as a hairline.
      final values = Waveform.fromDbfs(<double>[-60, -6, -60]);
      expect(values.reduce((a, b) => a > b ? a : b), Waveform.maxValue);
    });

    test('values stay inside 0..100 for a hot signal', () {
      final values = Waveform.fromDbfs(<double>[0, 3, -1, 12]);
      expect(values.every((value) => value >= 0 && value <= Waveform.maxValue), isTrue);
    });

    test('a short take keeps its width instead of trailing into zeros', () {
      final values = Waveform.fromDbfs(<double>[-10, -30, -10]);
      expect(values.where((value) => value > Waveform.floorValue).length, greaterThan(Waveform.buckets ~/ 2));
    });
  });

  group('sanitize', () {
    test('a valid stored waveform survives unchanged', () {
      final stored = List<int>.generate(Waveform.buckets, (i) => (i * 1.5).round());
      expect(Waveform.sanitize(stored), stored);
    });

    test('clamps out-of-range values from another writer', () {
      final stored = List<int>.filled(Waveform.buckets, 900);
      expect(Waveform.sanitize(stored).every((value) => value == Waveform.maxValue), isTrue);
    });

    test('anything malformed means "no waveform", so the UI falls back', () {
      expect(Waveform.sanitize(null), isEmpty);
      expect(Waveform.sanitize(<int>[1, 2, 3]), isEmpty);
      expect(Waveform.sanitize(List<dynamic>.filled(Waveform.buckets, 'a')), isEmpty);
    });
  });
}
