import 'dart:async';

import 'video_repository.dart';

/// Signed URLs, cached.
///
/// Playback URLs are presigned for an hour. Minting one per tile per rebuild
/// would put a network round trip in the middle of every scroll frame, so keys
/// are mapped to URLs once and reused until they are nearly expired. A failure
/// is never cached: the next attempt gets a fresh signature.
class MediaCache {
  MediaCache(this._videos);

  final VideoRepository _videos;
  final Map<String, _Signed> _urls = <String, _Signed>{};
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  /// Callers may keep a URL for at most this long; the edge function signs for
  /// an hour, so there is a deliberate margin before expiry.
  static const Duration _usable = Duration(minutes: 50);

  /// [scope] is only needed when the caller knows better than the key does; by
  /// default the ticket infers the space from the prefix, which is what makes
  /// one cache serve feed posters, chat clips and long-form alike.
  Future<String?> url(String? key, {VideoScope? scope}) async {
    if (key == null || key.isEmpty) return null;
    final cached = _urls[key];
    if (cached != null && cached.validFor(_usable)) return cached.url;

    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _videos
        .playbackUrl(key: key, scope: scope)
        .then<String?>((url) {
      _urls[key] = _Signed(url, DateTime.now());
      return url;
    }).catchError((Object _) => null).whenComplete(() => _inFlight.remove(key));
    _inFlight[key] = future;
    return future;
  }

  /// Synchronous peek, for a build method that must not await. Returns null the
  /// first time a key is seen (the caller then kicks off [url]).
  String? peek(String? key) {
    if (key == null) return null;
    final cached = _urls[key];
    return cached != null && cached.validFor(_usable) ? cached.url : null;
  }

  /// Drops a key — used when an upload is replaced.
  void evict(String key) => _urls.remove(key);
}

class _Signed {
  const _Signed(this.url, this.at);

  final String url;
  final DateTime at;

  bool validFor(Duration window) => DateTime.now().difference(at) < window;
}
