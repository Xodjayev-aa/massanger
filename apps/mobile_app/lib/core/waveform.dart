import 'dart:math' as math;

/// Builds the 64-bucket envelope stored in `messages.media.waveform`.
///
/// The schema requires exactly 64 integers in 0..100 (migration 00002), and the
/// composer draws them as a bar chart that doubles as the seek track. The recorder
/// reports amplitude in dBFS (0 = full scale, more negative = quieter), so this is
/// where that becomes a usable curve: linear in amplitude, not in decibels, or a
/// normal voice renders as a flat line.
class Waveform {
  const Waveform._();

  static const int buckets = 64;
  static const int maxValue = 100;

  /// Even silence gets a few pixels so a bubble never collapses into an empty box.
  static const int floorValue = 3;

  /// Anything at or below this stays proportionally small (see [fromDbfs]).
  static const double referenceFloorDbfs = -18;

  /// [samples] are dBFS readings taken at a steady interval while recording.
  static List<int> fromDbfs(List<double> samples) {
    if (samples.isEmpty) return List<int>.filled(buckets, floorValue);

    final amplitude = samples.map(dbfsToAmplitude).toList();
    final peak = amplitude.reduce(math.max);
    // Normalise against the louder of "the peak of this take" and a fixed
    // reference, which gives an absolute-ish scale: a shout reaches the top, a
    // normal voice fills most of it, and a recording of silence stays a flat line
    // instead of being stretched to full scale by dividing by its own noise floor.
    final reference = math.max(peak, dbfsToAmplitude(referenceFloorDbfs));
    final normalised = reference <= 0
        ? List<double>.filled(amplitude.length, 0.0)
        : amplitude.map((a) => (a / reference).clamp(0.0, 1.0)).toList();

    return List<int>.generate(buckets, (bucket) {
      final value = normalised.length <= buckets
          ? _nearest(normalised, bucket / buckets)
          : _peakOf(normalised, bucket / buckets);
      return floorValue + (value * (maxValue - floorValue)).round();
    });
  }

  static double dbfsToAmplitude(double dbfs) {
    if (!dbfs.isFinite) return 0.0;
    if (dbfs >= 0) return 1.0;
    return math.pow(10, dbfs / 20).toDouble();
  }

  static double _nearest(List<double> values, double position) {
    if (values.isEmpty) return 0.0;
    final index = (position * values.length).floor().clamp(0, values.length - 1);
    return values[index];
  }

  static double _peakOf(List<double> values, double position) {
    final start = (position * values.length).floor().clamp(0, values.length - 1);
    final end = ((position + 1 / buckets) * values.length).ceil().clamp(start + 1, values.length);
    var peak = 0.0;
    for (var i = start; i < end; i++) {
      if (values[i] > peak) peak = values[i];
    }
    return peak;
  }

  /// Validates a waveform that came from the server. The composer must be able to
  /// render it without defending against malformed data on every frame, so bad or
  /// truncated input becomes "no waveform" and the UI falls back to a progress bar.
  static List<int> sanitize(Object? raw) {
    if (raw is! List || raw.length < buckets) return const [];
    final values = <int>[];
    for (final entry in raw.take(buckets)) {
      final value = entry is num ? entry.toInt() : int.tryParse('$entry');
      if (value == null) return const [];
      values.add(value.clamp(0, maxValue));
    }
    return values.length == buckets ? values : const [];
  }
}
