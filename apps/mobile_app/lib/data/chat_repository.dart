import 'dart:async';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import '../core/formatting.dart';
import 'models.dart';

/// Everything the chat screens need from the backend.
///
/// Reads go through the RPCs (`chat_feed`, `chat_summaries`) rather than table
/// selects: those functions own the projection the UI needs (unread badges, the
/// preview row, the reply quote, `is_mine`) and enforce membership in one place.
/// Writes go through `send_message` so the optimistic bubble and the server row
/// share a `client_message_id`, which is what makes deduplication work.
class ChatRepository {
  ChatRepository(this._client);

  final SupabaseClient _client;

  static const int feedPageSize = 30;

  Future<List<ChatSummary>> summaries({String? query, int limit = 60}) async {
    try {
      final rows = await _client.rpc<dynamic>('chat_summaries', params: <String, Object?>{
        'p_query': (query == null || query.trim().isEmpty) ? null : query.trim(),
        'p_limit': limit,
      });
      return _rows(rows).map((row) => ChatSummary.fromMap(row)).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<MessageItem>> feed({
    required String chatId,
    String? beforeId,
    int limit = feedPageSize,
    required String currentUserId,
  }) async {
    try {
      final rows = await _client.rpc<dynamic>('chat_feed', params: <String, Object?>{
        'p_chat_id': chatId,
        'p_before_id': beforeId,
        'p_limit': limit,
      });
      final messages = _rows(rows).map((row) => MessageItem.fromMap(row, currentUserId: currentUserId)).toList();
      // `chat_feed` returns newest-first for paging; the thread renders oldest →
      // newest, and the screen simply prepends when loading older history.
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return messages;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// The row the app inserts for a new message, returned as a [MessageItem].
  Future<MessageItem> send({
    required String chatId,
    required MessageKind kind,
    required String clientMessageId,
    required String currentUserId,
    String? body,
    Map<String, Object?>? media,
    String? replyToId,
  }) async {
    try {
      final row = await _client.rpc<dynamic>('send_message', params: <String, Object?>{
        'p_chat_id': chatId,
        'p_kind': kind.wire,
        'p_body': body,
        'p_media': media,
        'p_reply_to_id': replyToId,
        'p_client_message_id': clientMessageId,
      });
      if (row is! Map) {
        throw const AppException('database', 'The server accepted the message but returned no row.');
      }
      return MessageItem.fromMap(Map<String, dynamic>.from(row), currentUserId: currentUserId);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> markRead(String chatId) async {
    try {
      await _client.rpc<dynamic>('mark_chat_read', params: <String, Object?>{'p_chat_id': chatId});
    } catch (error) {
      // A failed read receipt is cosmetic: never surface it, but do not swallow
      // an auth failure, which would hide a real problem from the user.
      if (error is AppException && error.code == '42501') rethrow;
    }
  }

  /// The RLS policy only lets a participant update their own row. The notice
  /// trigger cancels any queued Saved Messages delivery in the same transaction
  /// when this is muted; the foreground banner host reads the same row.
  Future<void> setMuted(String chatId, bool muted) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const AppException('auth', 'Sign in first.');
    try {
      await _client.from('chat_participants').update(<String, Object?>{
        'muted_until': muted ? DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String() : null,
      }).eq('user_id', userId).eq('chat_id', chatId);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Called when the thread is visible: the server only promotes `sent → delivered`
  /// for rows that belong to somebody else, so this is safe to call aggressively.
  Future<void> markDelivered(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    try {
      await _client.rpc<dynamic>('mark_messages_delivered', params: <String, Object?>{
        'p_message_ids': messageIds,
      });
    } catch (_) {
      // Ignored on purpose: delivery receipts are advisory and the next focus
      // event retries them.
    }
  }

  Future<void> retry(String messageId) => _guard(() => _client.rpc<dynamic>(
        'retry_message',
        params: <String, Object?>{'p_message_id': messageId},
      ));

  Future<void> delete(String messageId) => _guard(() => _client.rpc<dynamic>(
        'delete_message',
        params: <String, Object?>{'p_message_id': messageId},
      ));

  Future<int> unreadTotal() async {
    try {
      final value = await _client.rpc<dynamic>('unread_total');
      return asInt(value);
    } catch (_) {
      return 0;
    }
  }

  Future<void> setTyping({required String chatId, required bool on, String action = 'typing'}) async {
    try {
      await _client.rpc<dynamic>('set_typing', params: <String, Object?>{
        'p_chat_id': chatId,
        'p_on': on,
        'p_action': action,
      });
    } catch (_) {
      // Presence is the least important write in the app; a failure here must
      // never reach the composer. The server also throttles, so silence means
      // "someone is typing too fast", not "broken".
    }
  }

  Future<List<TypingPresence>> typingState(String chatId) async {
    try {
      final rows = await _client.rpc<dynamic>('chat_typing_state', params: <String, Object?>{'p_chat_id': chatId});
      return _rows(rows).map(TypingPresence.fromMap).toList(growable: false);
    } catch (_) {
      return const <TypingPresence>[];
    }
  }

  Future<String> createDirectChat({String? peerId, String? peerUsername}) async {
    try {
      final chatId = await _client.rpc<dynamic>('create_direct_chat', params: <String, Object?>{
        'p_peer_id': peerId,
        'p_peer_username': peerUsername,
      });
      if (chatId is! String || chatId.isEmpty) {
        throw const AppException('database', 'Could not open that conversation.');
      }
      return chatId;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<DirectoryEntry>> searchPeople(String query) async {
    // PostgREST's `or=` grammar is comma-separated, so a name containing a comma
    // or parenthesis would otherwise become a syntax error (400) instead of a
    // result set. User-visible search must never fail on punctuation.
    final trimmed = query.trim().replaceAll(RegExp(r'[,()]'), ' ').trim();
    if (trimmed.length < 2) return const <DirectoryEntry>[];
    try {
      final rows = await _client
          .from('directory')
          .select('id, username, display_name, avatar_path, avatar_external_url, bio, telegram_username, is_online, last_seen_at')
          .or('username.ilike.%$trimmed%,display_name.ilike.%$trimmed%')
          .limit(20)
          .order('username');
      return rows.map(DirectoryEntry.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<List<MessageItem>> searchMessages({
    required String query,
    String? chatId,
    required String currentUserId,
    int limit = 40,
  }) async {
    try {
      final rows = await _client.rpc<dynamic>('search_messages', params: <String, Object?>{
        'p_query': query,
        'p_chat_id': chatId,
        'p_limit': limit,
      });
      return _rows(rows).map((row) => MessageItem.fromMap(row, currentUserId: currentUserId)).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Uploads a picked photo into the chat's folder. The first path segment is the
  /// chat id because the storage policy resolves membership from it, exactly like
  /// the Telegram bridge does for mirrored media.
  Future<ImageMedia> uploadImage({required String chatId, required XFile file, String? caption}) async {
    final size = await file.length();
    if (size > 20 * 1024 * 1024) {
      throw const AppException('storage', 'Photos must stay under 20 MB.');
    }
    final extension = _extensionOf(file.name, fallback: '.jpg');
    final objectPath = '$chatId/app/${DateTime.now().microsecondsSinceEpoch}$extension';
    try {
      await _client.storage
          .from('images')
          .uploadBinary(objectPath, await file.readAsBytes(), fileOptions: FileOptions(contentType: _mimeFor(extension)));
      return ImageMedia(
        bucket: 'images',
        storagePath: objectPath,
        mime: _mimeFor(extension),
        sizeBytes: size,
        caption: caption,
      );
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<VoiceMedia> uploadVoice({required String chatId, required Uint8List bytes, required Duration duration, required List<int> waveform}) async {
    final size = bytes.length;
    if (size > 10 * 1024 * 1024) {
      throw const AppException('storage', 'Voice notes must stay under 10 MB.');
    }
    final objectPath = '$chatId/app/${DateTime.now().microsecondsSinceEpoch}.wav';
    try {
      await _client.storage
          .from('voice-notes')
          .uploadBinary(objectPath, bytes, fileOptions: const FileOptions(contentType: 'audio/wav'));
      return VoiceMedia(
        bucket: 'voice-notes',
        storagePath: objectPath,
        mime: 'audio/wav',
        duration: duration,
        sizeBytes: size,
        waveform: waveform,
      );
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> deleteUploaded(MessageMedia? media) async {
    final attached = media;
    if (attached == null || attached.isExternal) return;
    final bucket = attached.bucket;
    final path = attached.storagePath;
    if (bucket == null || path == null) return;
    try {
      await _client.storage.from(bucket).remove(<String>[path]);
    } catch (_) {
      // An orphaned object is a billing detail, not a user-visible failure; the
      // nightly sweep in the runbook reclaims these.
    }
  }

  /// Signed URL for a private bucket object, cached until it is about to expire.
  ///
  /// Signed (not public) because the buckets are private by design: membership is
  /// the authorization, and a public URL would leak a chat photo into a link
  /// preview. The cache exists because a thread renders the same image on every
  /// rebuild, and each signature is a round trip.
  Future<String?> urlFor(MessageMedia? media) async {
    final attached = media;
    if (attached == null) return null;
    if (!attached.isExternal) {
      final bucket = attached.bucket;
      final path = attached.storagePath;
      if (bucket == null || path == null) return null;
      final cached = _urls[path];
      if (cached != null && cached.expires.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
        return cached.url;
      }
      try {
        final url = await _client.storage.from(bucket).createSignedUrl(path, 3600);
        _urls[path] = _SignedUrl(url, DateTime.now().add(const Duration(minutes: 50)));
        return url;
      } catch (_) {
        return null;
      }
    }
    if (attached is ImageMedia) return attached.url;
    if (attached is VoiceMedia) return attached.url;
    return null;
  }

  final Map<String, _SignedUrl> _urls = <String, _SignedUrl>{};

  /// Postgres-changes subscription for one chat: inserts (new messages from the
  /// peer or another device), updates (state and edits) and deletes.
  /// [onEvent] receives the change type as a plain string plus the row: for a
  /// delete that is the `oldRecord`, which is the only id we still have.
  RealtimeChannel watchMessages({
    required String chatId,
    required void Function(String eventType, Map<String, dynamic> row) onEvent,
  }) {
    final channel = _client.channel('chat:$chatId');
    void listen(PostgresChangeEvent event, String label) {
      channel.onPostgresChanges(
        event: event,
        schema: 'public',
        table: 'messages',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'chat_id', value: chatId),
        callback: (payload) {
          final row = payload.newRecord.isEmpty ? payload.oldRecord : payload.newRecord;
          onEvent(label, row);
        },
      );
    }

    listen(PostgresChangeEvent.insert, 'INSERT');
    listen(PostgresChangeEvent.update, 'UPDATE');
    listen(PostgresChangeEvent.delete, 'DELETE');
    return channel.subscribe();
  }

  /// Typing is polled off the `chat_typing` table with a short interval, plus a
  /// realtime listener for immediacy. The 6-second TTL in the database is the real
  /// authority — a missed "stopped typing" event self-heals within one interval.
  TypingSubscription watchTyping({required String chatId, required Future<List<TypingPresence>> Function() load}) {
    return TypingSubscription(
      client: _client,
      chatId: chatId,
      load: load,
    );
  }

  static String _extensionOf(String path, {required String fallback}) {
    final index = path.lastIndexOf('.');
    if (index < 0 || index < path.length - 6) return fallback;
    final extension = path.substring(index).toLowerCase();
    return const <String>{'.jpg', '.jpeg', '.png', '.gif', '.webp', '.avif'}.contains(extension)
        ? extension : fallback;
  }

  static String _mimeFor(String extension) => switch (extension) {
        '.png' => 'image/png',
        '.avif' => 'image/avif',
        '.jpeg' => 'image/jpeg',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        _ => 'image/jpeg',
      };

  static List<Map<String, dynamic>> _rows(Object? value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    return value.whereType<Map<dynamic, dynamic>>().map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _guard(Future<Object?> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}

class _SignedUrl {
  const _SignedUrl(this.url, this.expires);
  final String url;
  final DateTime expires;
}

/// Keeps the realtime event and the fallback poll in one object so a screen only
/// has to `await subscription.cancel()`.
class TypingSubscription {
  TypingSubscription({
    required SupabaseClient client,
    required this.chatId,
    required this.load,
    this.fallbackInterval = const Duration(seconds: 4),
  }) : _client = client {
    _emit();
    _channel = _client.channel('typing:$chatId').onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'chat_typing',
      filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'chat_id', value: chatId),
      callback: (_) => _emit(),
    )..subscribe();
    _timer = Timer.periodic(fallbackInterval, (_) => _emit());
  }

  final SupabaseClient _client;
  final String chatId;
  final Future<List<TypingPresence>> Function() load;
  final Duration fallbackInterval;

  final StreamController<List<TypingPresence>> _controller = StreamController<List<TypingPresence>>.broadcast();
  RealtimeChannel? _channel;
  Timer? _timer;
  List<TypingPresence> _last = const <TypingPresence>[];

  Stream<List<TypingPresence>> get stream => _controller.stream;

  void _emit() {
    unawaited(
      load().then((presences) {
        if (_controller.isClosed) return;
        if (_sameAs(presences, _last)) return;
        _last = presences;
        _controller.add(presences);
      }).catchError((Object _) {
        // Presence is best-effort; the next tick retries.
      }),
    );
  }

  static bool _sameAs(List<TypingPresence> a, List<TypingPresence> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].userId != b[i].userId || a[i].action != b[i].action) return false;
    }
    return true;
  }

  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    await _channel?.unsubscribe();
    _channel = null;
    await _controller.close();
  }
}
