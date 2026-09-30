import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';

/// Which key space a video lives in — `chat/<chatId>/…` or `shorts/<uid>/…`.
/// The edge function re-derives this from the key it is handed and refuses a
/// mismatch, so a chat ticket can never read a short or another chat.
enum VideoScope {
  chat('chat'),
  short('short');

  const VideoScope(this.wire);

  final String wire;

  static VideoScope fromKey(String key) =>
      key.startsWith('shorts/') ? VideoScope.short : VideoScope.chat;

  /// The chat id embedded in a `chat/<uuid>/…` key, when there is one.
  static String? chatIdFromKey(String key) {
    if (!key.startsWith('chat/')) return null;
    final parts = key.split('/');
    if (parts.length < 3) return null;
    final candidate = parts[1];
    return candidate.isEmpty ? null : candidate;
  }
}

/// A presigned PUT: upload [url] directly to B2 with [contentType], then call
/// `confirm` — only the confirmed numbers may reach the database.
class VideoUploadTicket {
  const VideoUploadTicket({
    required this.key,
    required this.url,
    required this.expiresIn,
    required this.contentType,
  });

  final String key;
  final String url;
  final Duration expiresIn;
  final String contentType;

  factory VideoUploadTicket.fromMap(Map<String, dynamic> map) => VideoUploadTicket(
        key: '${map['key']}',
        url: '${map['url']}',
        expiresIn: Duration(seconds: (map['expiresInSeconds'] as num?)?.toInt() ?? 0),
        contentType: map['contentType'] is String ? map['contentType'] as String : 'video/mp4',
      );
}

/// What `video-ticket confirm` verified by reading the stored bytes: the real
/// size (HEAD) and the real duration (`moov`/`mvhd`), both already capped.
class VerifiedVideo {
  const VerifiedVideo({required this.key, required this.sizeBytes, required this.duration});

  final String key;
  final int sizeBytes;
  final Duration duration;
}

/// The `video-ticket` edge function: the only holder of the S3 secret and the
/// only path to a presigned URL.
///
/// Split of trust, in one line each: the client declares a shape and uploads
/// bytes **straight to Backblaze B2** (no video byte ever touches Supabase);
/// the function checks membership/standing, mints the URL, then re-reads what
/// actually landed before the database is allowed to learn about it.
class VideoRepository {
  VideoRepository(this._client);

  final SupabaseClient _client;

  /// False when the deployment has no B2 secrets — the app then hides the
  /// video affordances rather than offering an upload that cannot land.
  Future<bool> isConfigured() async {
    try {
      final data = await _call(<String, Object?>{'action': 'status'});
      return data['configured'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<VideoUploadTicket> requestUpload({
    required VideoScope scope,
    String? chatId,
    required int sizeBytes,
    required Duration duration,
  }) async {
    final chat = _requireChatId(scope, chatId);
    final data = await _call(<String, Object?>{
      'action': 'put',
      'scope': scope.wire,
      if (chat != null) 'chatId': chat,
      'mime': 'video/mp4',
      'durationMs': duration.inMilliseconds,
      'sizeBytes': sizeBytes,
    });
    return VideoUploadTicket.fromMap(data);
  }

  Future<VerifiedVideo> confirm({
    required VideoScope scope,
    String? chatId,
    required String key,
  }) async {
    final chat = _requireChatId(scope, chatId);
    final data = await _call(
      <String, Object?>{
        'action': 'confirm',
        'scope': scope.wire,
        if (chat != null) 'chatId': chat,
        'key': key,
      },
      timeout: const Duration(seconds: 60),
    );
    return VerifiedVideo(
      key: '${data['key']}',
      sizeBytes: (data['sizeBytes'] as num?)?.toInt() ?? 0,
      duration: Duration(milliseconds: (data['durationMs'] as num?)?.toInt() ?? 0),
    );
  }

  /// Presigned GET for playback. Scope and chat id are inferred from [key]
  /// unless given, which is what lets a bubble render from media alone.
  Future<String> playbackUrl({
    required String key,
    VideoScope? scope,
    String? chatId,
    bool download = false,
  }) async {
    final resolved = scope ?? VideoScope.fromKey(key);
    final chat = chatId ?? VideoScope.chatIdFromKey(key);
    final data = await _call(<String, Object?>{
      'action': 'get',
      'scope': resolved.wire,
      if (chat != null) 'chatId': chat,
      'key': key,
      if (download) 'download': true,
    });
    final url = data['url'];
    if (url is! String || url.isEmpty) {
      throw const AppException('storage', 'That video is not available.');
    }
    return url;
  }

  /// Presigned GET with `Content-Disposition: attachment` for browser downloads.
  Future<String> downloadUrl({
    required String key,
    VideoScope? scope,
    String? chatId,
  }) =>
      playbackUrl(
        key: key,
        scope: scope,
        chatId: chatId,
        download: true,
      );

  /// Best-effort cleanup for an upload that never became a message. Attached
  /// media is refused server-side on purpose: the message-row lifecycle owns it.
  Future<void> discard({required VideoScope scope, String? chatId, required String key}) async {
    final chat = _requireChatId(scope, chatId);
    await _call(<String, Object?>{
      'action': 'delete',
      'scope': scope.wire,
      if (chat != null) 'chatId': chat,
      'key': key,
    });
  }

  /// Direct-to-B2 upload. The URL is presigned, so the only headers that
  /// matter are the ones B2 saw at signing time (host) plus the object's type.
  static Future<void> putBytes({
    required String url,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final client = http.Client();
    try {
      final response = await client
          .put(
            Uri.parse(url),
            headers: <String, String>{'content-type': contentType},
            body: bytes,
          )
          .timeout(const Duration(minutes: 15));
      if (response.statusCode != 200 && response.statusCode != 204) {
        throw AppException(
          'storage',
          'The video upload to storage failed (${response.statusCode}). '
          'Check your connection and retry.',
        );
      }
    } on AppException {
      rethrow;
    } catch (error) {
      // A CORS refusal or a dropped socket arrives here as a bare client
      // exception with no user-facing meaning; translate it.
      throw AppException(
        'storage',
        'The video could not be uploaded. Check your connection and retry.',
        cause: error,
      );
    } finally {
      client.close();
    }
  }

  String? _requireChatId(VideoScope scope, String? chatId) {
    if (scope == VideoScope.short) return null;
    final chat = chatId;
    if (chat == null || chat.isEmpty) {
      throw const AppException('bad_request', 'A chat video needs its chat.');
    }
    return chat;
  }

  Future<Map<String, dynamic>> _call(
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final response = await _client.functions.invoke('video-ticket', body: body).timeout(timeout);
      final envelope = response.data;
      final data = envelope is Map ? envelope['data'] : null;
      if (envelope is Map && envelope['ok'] == true && data is Map) {
        return Map<String, dynamic>.from(data);
      }
      throw const AppException('storage', 'The server rejected the video request.');
    } on AppException {
      rethrow;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}
