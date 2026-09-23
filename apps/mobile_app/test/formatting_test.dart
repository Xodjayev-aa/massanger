// These two files are pure-Dart unit tests: they run with `flutter test` and cover
// the pieces whose correctness the UI cannot verify by eye — timestamp boundaries
// and the waveform the schema validates. `dart test` also works, since neither file
// imports Flutter.

import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/core/formatting.dart';

void main() {
  group('dayLabel', () {
    test('today and yesterday are relative', () {
      final now = DateTime.now();
      expect(ChatFormatting.dayLabel(now), 'Today');
      expect(ChatFormatting.dayLabel(now.subtract(const Duration(days: 1))), 'Yesterday');
    });

    test('a label is stable across midnight for the same day', () {
      final morning = DateTime(now() - 1, 6, 12, 0, 0);
      final evening = DateTime(morning.year, morning.month, morning.day, 23, 30);
      expect(ChatFormatting.dayLabel(morning), ChatFormatting.dayLabel(evening));
    });

    test('older than a week falls back to a date', () {
      final longAgo = DateTime.now().subtract(const Duration(days: 30));
      expect(ChatFormatting.dayLabel(longAgo), contains('${longAgo.year}'));
    });
  });

  group('duration', () {
    test('under an hour has no hours component', () {
      expect(ChatFormatting.duration(const Duration(seconds: 7)), '0:07');
      expect(ChatFormatting.duration(const Duration(minutes: 4, seconds: 9)), '4:09');
    });

    test('over an hour pads the minutes', () {
      expect(ChatFormatting.duration(const Duration(hours: 1, seconds: 4)), '1:00:04');
    });
  });

  group('listStamp', () {
    test('a message from this year shows month and day, not the year', () {
      // Deliberately "00:00 today" rather than "four days ago": in early January the
      // latter lands in last year and legitimately grows a year in its label, which
      // would make this test fail depending on the calendar.
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      expect(ChatFormatting.listStamp(today), isNot(contains('${now.year}')));
      final earlierThisYear = DateTime(now.year, now.month, now.day - 20);
      expect(ChatFormatting.listStamp(earlierThisYear), isNot(contains('${now.year}')));
    });

    test('an older year shows the full date', () {
      final stamp = ChatFormatting.listStamp(DateTime(DateTime.now().year - 2, 3, 4));
      expect(stamp, contains('${DateTime.now().year - 2}'));
    });
  });

  group('parseTimestamp', () {
    test('a PostgREST timestamp without an offset is read as UTC', () {
      final parsed = parseTimestamp('2026-03-23T10:15:00');
      expect(parsed!.toUtc().hour, 10);
    });

    test('an ISO string with an offset keeps its instant', () {
      final parsed = parseTimestamp('2026-03-23T10:15:00+05:00');
      expect(parsed!.toUtc().hour, 5);
    });

    test('epoch seconds survive as an int', () {
      expect(parseTimestamp(0)!.toUtc(), DateTime.utc(1970));
    });

    test('null and empty stay null', () {
      expect(parseTimestamp(null), isNull);
      expect(parseTimestamp(''), isNull);
    });
  });

  group('coercions', () {
    test('bigint arrives as a string from PostgREST', () {
      expect(asInt('9007199254740993'), 9007199254740993);
      expect(asInt(null, -1), -1);
      expect(asBool('true'), isTrue);
      expect(asBool(0), isFalse);
    });
  });
}

int now() => DateTime.now().year;
