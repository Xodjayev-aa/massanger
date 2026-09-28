import 'dart:typed_data';

import 'errors.dart';
import 'mp4.dart';

/// The Phase-1 hard caps, in one place the composer, the chat upload and the
/// shorts publisher all agree with — and all mirror `video-ticket` +
/// `app.validate_message_media`, so a value rejected here is a value the
/// server would reject anyway.
///
/// Single MP4 quality by design: there is no transcoding pipeline and Phase 1
/// does not pretend otherwise.
class VideoLimits {
  const VideoLimits._();

  static const int maxBytes = 250 * 1024 * 1024;
  static const Duration maxDuration = Duration(seconds: 60);
  static const String mime = 'video/mp4';

  static bool isMp4Name(String fileName) => fileName.toLowerCase().endsWith('.mp4');

  /// Validates the picked file *before* any byte leaves the device and returns
  /// the duration the cap check proved. Throws [AppException] with words a
  /// person can act on.
  static Duration preflight(String fileName, Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const AppException('storage', 'Videos must stay under 250 MB.');
    }
    if (!isMp4Name(fileName)) {
      throw const AppException('storage', 'Only MP4 videos are supported.');
    }
    final duration = readMp4Duration(bytes);
    if (duration == null || duration <= Duration.zero) {
      throw const AppException('storage', 'That video could not be read.');
    }
    if (duration > maxDuration) {
      throw const AppException('storage', 'Videos must stay under 60 seconds.');
    }
    return duration;
  }
}
