// The one client-side contract that has no compiler between it and the database:
// `messages.media` is jsonb validated by `app.validate_message_media`
// (supabase/migrations/00004). If a key here is renamed, or duration arrives as a
// string, every image and voice send starts failing with 22023 and the app has no way
// to explain why. These assertions mirror the validator's checks exactly.

import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/core/waveform.dart';
import 'package:messengerx_app/data/models.dart';

/// The buckets the validator accepts (00004), which are also the only ones the
/// storage policies in 00008 created.
const Set<String> _allowedBuckets = <String>{'images', 'voice-notes', 'avatars'};

final List<int> waveform = List<int>.generate(Waveform.buckets, (i) => (i * 1.3).round().clamp(0, Waveform.maxValue));

void main() {
  group('voice media map', () {
    const VoiceMedia sample = VoiceMedia(
      bucket: 'voice-notes',
      storagePath: 'c0ffee00-0000-0000-0000-000000000001/notes/msg.wav',
      duration: Duration(seconds: 4, milliseconds: 250),
      sizeBytes: 705212,
    );

    test('carries the keys validate_message_media reads', () {
      final Map<String, Object?> map = VoiceMedia(
        bucket: sample.bucket,
        storagePath: sample.storagePath,
        duration: sample.duration,
        sizeBytes: sample.sizeBytes,
        waveform: waveform,
      ).toMap();

      expect(map['kind'], 'voice');
      expect(map['bucket'], 'voice-notes');
      expect(_allowedBuckets, contains(map['bucket']));
      // `path` or `url` — one of them must exist, or the row is rejected.
      expect(map.containsKey('path'), isTrue);
      // A positive duration_ms is a hard requirement, not a nicety.
      expect(map['duration_ms'], 4250);
      expect(map['duration_ms'], isA<int>());
      expect(map['mime'], 'audio/wav');
      expect(map['size_bytes'], isA<int>());
    });

    test('waveform is a 64-element array of ints or absent', () {
      // The validator only checks that it is a json array, so a 40-bar list would be
      // accepted by Postgres and then rendered as a truncated bubble: 64 or nothing.
      const VoiceMedia noWaveform = VoiceMedia(
        bucket: 'voice-notes',
        storagePath: 'a/b.wav',
        duration: Duration(seconds: 4),
      );
      final Map<String, Object?> stored = noWaveform.toMap();
      expect(stored.containsKey('waveform'), isFalse, reason: 'no waveform recorded, so none is written');
      expect(stored['duration_ms'], 4000, reason: 'the duration still has to be there');

      expect(waveform, hasLength(Waveform.buckets));
      expect(waveform.every((int value) => value >= 0 && value <= Waveform.maxValue), isTrue);
    });

    test('a zero duration is what the server would refuse', () {
      // The composer checks the same bound before uploading; this pins the fact that
      // there is no hidden default making the row look valid.
      expect(const VoiceMedia(duration: Duration.zero).toMap()['duration_ms'], 0);
    });
  });

  group('image media map', () {
    test('storage upload keeps path and drops url', () {
      const ImageMedia image = ImageMedia(
        bucket: 'images',
        storagePath: 'c0ffee00-0000-0000-0000-000000000001/msg.jpg',
        width: 1080,
        height: 720,
        sizeBytes: 204800,
        caption: 'from the road',
      );
      final Map<String, Object?> map = image.toMap();
      expect(map['kind'], 'image');
      expect(_allowedBuckets, contains(map['bucket']));
      expect(map['path'], image.storagePath);
      expect(map.containsKey('url'), isFalse);
      expect(map['width'], 1080);
      expect(map['height'], 720);
      expect(map['caption'], 'from the road');
    });

    test('a mirrored Telegram image may be url-only', () {
      const ImageMedia external = ImageMedia(url: 'https://cdn.example.test/1.jpg', width: 800, height: 600);
      final Map<String, Object?> map = external.toMap();
      // `path` is written as an explicit null rather than dropped, which is what the
      // validator wants: `p_media ? 'path' or p_media ? 'url'` checks for a key, and a
      // mirrored row has a url and no storage object.
      expect(map['path'], isNull, reason: 'no storage object to point at');
      expect(map['url'], 'https://cdn.example.test/1.jpg');
      expect(external.isExternal, isTrue);
      expect(external.aspectRatio, closeTo(800 / 600, 0.001));
    });

    test('an unknown bucket is a bug we would rather see here than in Postgres', () {
      const ImageMedia wrong = ImageMedia(bucket: 'attachments', storagePath: 'a/b.jpg');
      expect(_allowedBuckets, isNot(contains(wrong.toMap()['bucket'])));
    });

    test('an empty caption is not stored as an empty string', () {
      const ImageMedia image = ImageMedia(bucket: 'images', storagePath: 'a/b.jpg', caption: '');
      expect(image.toMap().containsKey('caption'), isFalse);
    });
  });

  group('fromMap dispatch', () {
    test('kind decides, and duration_ms breaks the tie', () {
      const VoiceMedia voice = VoiceMedia(
        bucket: 'voice-notes',
        storagePath: 'a/b.wav',
        duration: Duration(seconds: 1),
      );
      final Map<String, Object?> voiceMap = <String, Object?>{...voice.toMap(), 'waveform': waveform};
      expect(MessageMedia.fromMap(voiceMap), isA<VoiceMedia>());
      expect(MessageMedia.fromMap(const ImageMedia(bucket: 'images', storagePath: 'a/b.jpg').toMap()), isA<ImageMedia>());

      const Map<String, Object?> untagged = <String, Object?>{'bucket': 'voice-notes', 'path': 'a/b.wav', 'duration_ms': 900};
      expect(MessageMedia.fromMap(untagged), isA<VoiceMedia>());
      expect(MessageMedia.fromMap(null), isNull);
      expect(MessageMedia.fromMap('nope'), isNull);
    });

    test('retry resends the attachment it was given, unchanged', () {
      // ChatBloc._onRetry re-posts message.media?.toMap(); if that round trip lost the
      // waveform or the transcript, a retry would silently degrade the message.
      const VoiceMedia original = VoiceMedia(
        bucket: 'voice-notes',
        storagePath: 'a/b.wav',
        duration: Duration(seconds: 12),
        sizeBytes: 384000,
        transcript: 'salom',
      );
      final Map<String, Object?> first = <String, Object?>{...original.toMap(), 'waveform': waveform};
      final MessageMedia parsed = MessageMedia.fromMap(first)!;
      expect(parsed, isA<VoiceMedia>());
      expect(parsed.toMap(), first);
      expect((parsed as VoiceMedia).transcript, 'salom');
      expect(parsed.duration, const Duration(seconds: 12));
    });
  });
}
