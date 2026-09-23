import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/errors.dart';
import '../core/formatting.dart';
import '../core/waveform.dart';

/// Hold-to-record voice notes: capture, level metering, WAV writing, playback.
///
/// 16-bit PCM is captured deliberately instead of a platform codec. Two reasons
/// that matter in production:
///
///  * the composer needs a real waveform for the bubble (the schema stores 64
///    0..100 bars), and reading the PCM stream gives true peaks, while the
///    platform amplitude callback is throttled to ~200 ms on Android — useless for
///    a three-second note;
///  * a 44-byte WAV header around the same bytes plays identically on Android, iOS
///    and the web, with no codec gamble per device. 16 kHz mono is 32 KB/s, so even
///    the 120 s cap stays well under the 10 MB bucket limit.
class VoiceService {
  VoiceService({this.maxSeconds = 120, this.sampleRate = 16000, this.channels = 1});

  final int maxSeconds;
  final int sampleRate;
  final int channels;

  static const int _bytesPerFrame = 2;

  final StreamController<VoiceLevelEvent> _levels = StreamController<VoiceLevelEvent>.broadcast();
  final List<double> _peaks = <double>[];

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  RandomAccessFile? _file;
  String? _path;
  int _frames = 0;

  /// Live metering for the composer: level (0..1) plus elapsed time.
  Stream<VoiceLevelEvent> get levels => _levels.stream;

  bool get isRecording => _recorder != null;

  Duration get elapsed => Duration(milliseconds: (millisecondsPerFrame * _frames).round());

  Duration get remaining {
    final left = Duration(seconds: maxSeconds) - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  bool get isAtLimit => elapsed >= Duration(seconds: maxSeconds);

  double get millisecondsPerFrame => 1000.0 / sampleRate;

  /// Checked before the mic opens, so the user gets a permission prompt rather than
  /// a half-started recorder that has to be torn down.
  Future<void> ensurePermission() async {
    // `hasPermission` both checks and requests, so this is where the OS prompt
    // appears — before any temp file or recorder is created.
    if (!await AudioRecorder().hasPermission()) {
      throw const AppException('permission', 'Microphone access is needed for voice notes.');
    }
  }

  /// Starts a take. Any in-flight take is discarded first: a second long-press
  /// means the first was abandoned, and keeping it would leak a temp file.
  Future<void> start() async {
    await ensurePermission();
    await cancel();

    final directory = await getTemporaryDirectory();
    final target = File('${directory.path}/voice-${DateTime.now().millisecondsSinceEpoch}.pcm');
    _path = target.path;
    _file = await target.open(mode: FileMode.write);
    _frames = 0;
    _peaks.clear();

    final recorder = AudioRecorder();
    _recorder = recorder;
    // Streaming rather than a recorder-managed file: the peaks below come from the
    // same bytes that go to disk, and the 120 s cap is enforced here so the take
    // ends as a message instead of being discarded by the platform.
    final stream = await recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
      ),
    );

    _subscription = stream.listen(
      _onChunk,
      onError: (Object error) => _levels.addError(AppException.wrap(error)),
      cancelOnError: false,
    );
  }

  Future<void> _onChunk(Uint8List chunk) async {
    _frames += chunk.length ~/ (_bytesPerFrame * channels);
    final peak = _peakOf(chunk);
    _peaks.add(peak);
    final handle = _file;
    if (handle != null) {
      await handle.writeFrom(chunk);
    }
    _levels.add(VoiceLevelEvent(level: _normalise(peak), elapsed: elapsed));
    if (isAtLimit) {
      // Telegram-style auto-stop: the take is finished, not thrown away.
      await stop();
    }
  }

  /// Stops and finalises. Returns null for a take too short to send (< 500 ms),
  /// which is what an accidental tap on the mic produces.
  Future<VoiceTake?> stop() async {
    final recorder = _recorder;
    final path = _path;
    _recorder = null;
    _path = null;

    await _subscription?.cancel();
    _subscription = null;

    if (recorder == null || path == null) {
      await _closeFile(null);
      return null;
    }

    try {
      await recorder.stop();
    } catch (_) {
      // Stopping a recorder the platform already halted is not a user error.
    }
    await recorder.dispose();

    final duration = Duration(milliseconds: (millisecondsPerFrame * _frames).round());
    if (duration < const Duration(milliseconds: 500)) {
      await _closeFile(path);
      return null;
    }

    final wavPath = '${path.substring(0, path.length - 4)}.wav';
    final bytes = await _readAndClose(path);
    await File(wavPath).writeAsBytes(_withWavHeader(bytes), flush: true);
    await _deleteQuietly(path);

    return VoiceTake(
      file: File(wavPath),
      duration: duration,
      waveform: Waveform.fromDbfs(_peaks),
      sizeBytes: bytes.length + 44,
    );
  }

  /// Abandons the take in progress and removes its file.
  Future<void> cancel() async {
    final recorder = _recorder;
    final path = _path;
    _recorder = null;
    _path = null;

    await _subscription?.cancel();
    _subscription = null;

    if (recorder != null) {
      try {
        if (await recorder.isRecording()) await recorder.stop();
      } catch (_) {
        // Already halted by the platform.
      }
      await recorder.dispose();
    }
    await _closeFile(path);
  }

  Future<void> _closeFile(String? path) async {
    final handle = _file;
    _file = null;
    if (handle != null) {
      try {
        await handle.close();
      } catch (_) {
        // Closing twice is fine to ignore.
      }
    }
    if (path != null) await _deleteQuietly(path);
  }

  Future<Uint8List> _readAndClose(String path) async {
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      return Uint8List(0);
    }
  }

  /// PCM has no container, so the header is written by hand. RIFF sizes are
  /// little-endian and include the 8 bytes of the RIFF tag itself.
  Uint8List _withWavHeader(Uint8List pcm) {
    final byteRate = sampleRate * channels * _bytesPerFrame;
    final builder = BytesBuilder(copy: false);
    void ascii(String value) => builder.add(value.codeUnits);
    void u32(int value) => builder.add(_littleEndian(value, 4));
    void u16(int value) => builder.add(_littleEndian(value, 2));

    ascii('RIFF');
    u32(36 + pcm.length);
    ascii('WAVE');
    ascii('fmt ');
    u32(16);
    u16(1); // PCM, uncompressed
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(channels * _bytesPerFrame);
    u16(_bytesPerFrame * 8);
    ascii('data');
    u32(pcm.length);
    builder.add(pcm);
    return builder.toBytes();
  }

  static List<int> _littleEndian(int value, int width) =>
      List<int>.generate(width, (index) => (value >> (8 * index)) & 0xff);

  /// Peak of one chunk in dBFS, the same unit the recorder's own amplitude
  /// callback uses, so both meters agree.
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

  /// dBFS → 0..1 for the live meter, with the noise floor folded in so silence
  /// reads as a flat line instead of a full-scale bar.
  static double _normalise(double dbfs) {
    if (!dbfs.isFinite) return 0;
    if (dbfs >= 0) return 1;
    const floor = -48.0;
    if (dbfs <= floor) return 0;
    return (dbfs - floor) / -floor;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temp files are reclaimed by the OS.
    }
  }

  Future<void> dispose() async {
    await cancel();
    await _levels.close();
  }
}

class VoiceTake {
  const VoiceTake({required this.file, required this.duration, required this.waveform, required this.sizeBytes});

  final File file;
  final Duration duration;
  final List<int> waveform;
  final int sizeBytes;

  String get label => ChatFormatting.duration(duration);
}

class VoiceLevelEvent {
  const VoiceLevelEvent({required this.level, required this.elapsed});

  /// 0..1.
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
