import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../core/errors.dart';
import '../core/formatting.dart';
import '../core/waveform.dart';

/// Hold-to-record voice notes: capture PCM, meter it and upload a WAV container.
/// A take is capped at 120 s of 16 kHz mono PCM (~3.9 MB), so buffering it in
/// memory is safe and works in browsers as well as on Android and iOS. No
/// dart:io, browser-inaccessible temporary paths or permanent local recordings.
class VoiceService {
  VoiceService({this.maxSeconds = 120, this.sampleRate = 16000, this.channels = 1});

  final int maxSeconds;
  final int sampleRate;
  final int channels;

  static const int _bytesPerFrame = 2;

  final StreamController<VoiceLevelEvent> _levels = StreamController<VoiceLevelEvent>.broadcast();
  final List<double> _peaks = <double>[];
  final BytesBuilder _pcm = BytesBuilder(copy: false);

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  int _frames = 0;

  Stream<VoiceLevelEvent> get levels => _levels.stream;
  bool get isRecording => _recorder != null;
  Duration get elapsed => Duration(milliseconds: (millisecondsPerFrame * _frames).round());
  Duration get remaining {
    final left = Duration(seconds: maxSeconds) - elapsed;
    return left.isNegative ? Duration.zero : left;
  }
  bool get isAtLimit => _frames >= maxSeconds * sampleRate;
  double get millisecondsPerFrame => 1000.0 / sampleRate;

  Future<void> ensurePermission() async {
    final probe = AudioRecorder();
    try {
      if (!await probe.hasPermission()) {
        throw const AppException('permission', 'Microphone access is needed for voice notes.');
      }
    } finally {
      await probe.dispose();
    }
  }

  Future<void> start() async {
    await cancel();
    await ensurePermission();
    _frames = 0;
    _peaks.clear();
    _pcm.clear();

    final recorder = AudioRecorder();
    _recorder = recorder;
    try {
      final stream = await recorder.startStream(
        RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: sampleRate, numChannels: channels),
      );
      _subscription = stream.listen(
        _onChunk,
        onError: (Object error) {
          if (!_levels.isClosed) _levels.addError(AppException.wrap(error));
        },
      );
    } catch (error, stack) {
      _recorder = null;
      await recorder.dispose();
      throw AppException.wrap(error, stack);
    }
  }

  void _onChunk(Uint8List chunk) {
    final bytesPerFrame = _bytesPerFrame * channels;
    final available = (maxSeconds * sampleRate - _frames) * bytesPerFrame;
    if (available <= 0) return; // Composer stops the take on its next tick.
    final valid = chunk.length < available ? chunk.length : available;
    final aligned = valid - valid % bytesPerFrame;
    if (aligned == 0) return;
    final captured = Uint8List.sublistView(chunk, 0, aligned);
    _frames += aligned ~/ bytesPerFrame;
    _pcm.add(captured);
    _peaks.add(_peakOf(captured));
    if (!_levels.isClosed) _levels.add(VoiceLevelEvent(level: _normalise(_peaks.last), elapsed: elapsed));
  }

  /// A short accidental tap is discarded. The PCM bytes are used for both the
  /// WAV payload and the waveform: the meter cannot disagree with the recording.
  Future<VoiceTake?> stop() async {
    final recorder = _recorder;
    _recorder = null;
    await _subscription?.cancel();
    _subscription = null;
    if (recorder == null) return null;

    try {
      await recorder.stop();
    } catch (_) {
      // Platforms may auto-stop a recorder when the mic disappears.
    } finally {
      await recorder.dispose();
    }
    final duration = Duration(milliseconds: (millisecondsPerFrame * _frames).round());
    if (duration < const Duration(milliseconds: 500)) {
      _pcm.clear();
      return null;
    }
    final bytes = wavFromPcm(_pcm.takeBytes(), sampleRate: sampleRate, channels: channels);
    return VoiceTake(bytes: bytes, duration: duration, waveform: Waveform.fromDbfs(_peaks));
  }

  Future<void> cancel() async {
    final recorder = _recorder;
    _recorder = null;
    await _subscription?.cancel();
    _subscription = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {
        // Already stopped or never started.
      } finally {
        await recorder.dispose();
      }
    }
    _frames = 0;
    _peaks.clear();
    _pcm.clear();
  }

  /// PCM has no container. RIFF lengths are little-endian and count 36 bytes of
  /// header before the sample data. Pure helper so headers can be tested without
  /// a microphone, native platform or network.
  static Uint8List wavFromPcm(Uint8List pcm, {int sampleRate = 16000, int channels = 1}) {
    final builder = BytesBuilder(copy: false);
    void ascii(String value) => builder.add(value.codeUnits);
    void u32(int value) => builder.add(_littleEndian(value, 4));
    void u16(int value) => builder.add(_littleEndian(value, 2));

    ascii('RIFF');
    u32(36 + pcm.length);
    ascii('WAVE');
    ascii('fmt ');
    u32(16);
    u16(1);
    u16(channels);
    u32(sampleRate);
    u32(sampleRate * channels * _bytesPerFrame);
    u16(channels * _bytesPerFrame);
    u16(_bytesPerFrame * 8);
    ascii('data');
    u32(pcm.length);
    builder.add(pcm);
    return builder.toBytes();
  }

  static List<int> _littleEndian(int value, int width) =>
      List<int>.generate(width, (index) => (value >> (8 * index)) & 0xff);

  static double _peakOf(Uint8List chunk) {
    var peak = 0;
    final frames = chunk.length ~/ _bytesPerFrame;
    for (var i = 0; i < frames; i++) {
      final raw = (chunk[i * 2 + 1] << 8) | chunk[i * 2];
      final signed = raw > 0x7fff ? raw - 0x10000 : raw;
      final magnitude = signed.abs();
      if (magnitude > peak) peak = magnitude;
    }
    if (peak == 0) return -96;
    return 20 * math.log(peak / 0x7fff) / math.ln10;
  }

  static double _normalise(double dbfs) {
    if (!dbfs.isFinite) return 0;
    if (dbfs >= 0) return 1;
    const floor = -48.0;
    if (dbfs <= floor) return 0;
    return (dbfs - floor) / -floor;
  }

  Future<void> dispose() async {
    await cancel();
    await _levels.close();
  }
}

class VoiceTake {
  const VoiceTake({required this.bytes, required this.duration, required this.waveform});

  final Uint8List bytes;
  final Duration duration;
  final List<int> waveform;
  int get sizeBytes => bytes.length;
  String get label => ChatFormatting.duration(duration);
}

class VoiceLevelEvent {
  const VoiceLevelEvent({required this.level, required this.elapsed});

  final double level;
  final Duration elapsed;
}

/// One shared player for the app: starting a second note stops the first, which is
/// what people expect from a chat, and it keeps exactly one audio session alive on
/// iOS instead of fighting for the output.
class VoicePlayer {
  VoicePlayer();

  final AudioPlayer _player = AudioPlayer();
  final Map<String, String> _urls = <String, String>{};
  String? _currentId;

  String? get currentId => _currentId;

  Stream<Duration> get position => _player.positionStream;

  Stream<bool> get isPlaying => _player.playingStream;

  Duration get duration => _player.duration ?? Duration.zero;

  /// Remember a resolved signed URL so a bubble does not re-request one every time
  /// it scrolls back into view.
  void prime(String messageId, String url) => _urls[messageId] = url;

  Future<void> toggle(String messageId, {String? url}) async {
    final resolved = url ?? _urls[messageId];
    if (resolved == null) {
      throw const AppException('media', 'That recording could not be loaded.');
    }
    if (_currentId == messageId && _player.playing) {
      await _player.pause();
      return;
    }
    if (_currentId != messageId) {
      await _player.setUrl(resolved);
      _currentId = messageId;
    }
    await _player.play();
  }

  Future<void> seekTo(double fraction) async {
    final total = _player.duration;
    if (total == null) return;
    await _player.seek(Duration(milliseconds: (total.inMilliseconds * fraction.clamp(0.0, 1.0)).round()));
  }

  Future<void> stop() async {
    await _player.stop();
    _currentId = null;
  }

  Future<void> dispose() async {
    await _player.dispose();
    _urls.clear();
  }
}
