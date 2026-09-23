import 'package:intl/intl.dart';

/// Chat-shaped date/time helpers.
///
/// The database stores everything in UTC and the UI never shows a raw timestamp:
/// a message that says "14:03" while the phone reads 03:03 the next morning is
/// worse than no time at all, so day boundaries are always resolved in local time.
class ChatFormatting {
  const ChatFormatting._();

  static final DateFormat _time = DateFormat.Hm();
  static final DateFormat _weekday = DateFormat.EEEE();
  static final DateFormat _date = DateFormat.yMMMd();

  /// `14:03` for today, `Mon` inside the last week, `12 Mar 2026` otherwise.
  static String dayLabel(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(local.year, local.month, local.day);
    final days = today.difference(that).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return _weekday.format(that);
    return _date.format(that);
  }

  static String clock(DateTime value) => _time.format(value.toLocal());

  /// Used by the chat list: a timestamp must collapse to something short without
  /// losing the ability to tell "yesterday 22:10" from "three weeks ago".
  static String listStamp(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    if (local.year != now.year) return _date.format(local);
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(local.year, local.month, local.day);
    if (today.difference(that).inDays == 0) return _time.format(local);
    if (today.difference(that).inDays == 1) return 'Yesterday';
    return DateFormat.Md().format(local);
  }

  /// `0:07`, `1:04:09` — voice-note length as people read it in Telegram.
  static String duration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    final two = seconds.toString().padLeft(2, '0');
    if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$two';
    return '$minutes:$two';
  }

  static String fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// A short reason for a failed send, e.g. under the bubble.
  static String failureLabel(String code, String? reason) {
    switch (code) {
      case 'flood_wait':
        return 'Telegram is rate-limiting this account. Retrying shortly.';
      case 'no_telegram_account':
        return 'Telegram is not linked on this account yet.';
      case 'not_authorised':
        return 'Telegram sign-in is needed before this can be delivered.';
      case 'peer_not_found':
        return 'That Telegram chat no longer exists.';
      default:
        return reason == null || reason.isEmpty ? 'Not delivered — tap to retry.' : reason;
    }
  }
}

/// Parses the timestamps PostgREST hands back. Those are already UTC (the columns
/// are `timestamptz`), but the client must not assume the runtime's locale or the
/// JSON layer's separator, so parse defensively and return local time.
DateTime? parseTimestamp(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toLocal();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  final text = value.toString();
  if (text.isEmpty) return null;
  final iso = text.contains('T') ? text : text.replaceFirst(' ', 'T');
  final parsed = DateTime.tryParse(iso.endsWith('Z') || iso.contains('+') || _hasOffset(iso) ? iso : '${iso}Z');
  return parsed?.toLocal();
}

bool _hasOffset(String value) {
  final match = RegExp(r'[+-]\d{2}:?\d{2}$').firstMatch(value);
  return match != null;
}

/// `1234` (bigint from PostgREST can arrive as a String) without throwing.
int asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool asBool(Object? value) => value == true || value == 'true' || value == 1;

String asString(Object? value, {String fallback = ''}) => value is String ? value : fallback;
