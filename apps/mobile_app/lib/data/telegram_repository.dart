import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import '../core/formatting.dart';
import 'models.dart';

/// Talks to the `telegram-link` edge function and reads Telegram state.
///
/// The client never trusts itself with credentials in transit: the phone number,
/// the login code and the 2FA password are POSTed to the function over TLS, the
/// function seals them (AES-256-GCM) into the link-request row, and only the
/// bridge — which holds the same key — can open them. That is why this class calls
/// a function instead of the `telegram_link_*` RPCs directly, and why no
/// credential is ever written to local storage, logs, or crash reports.
class TelegramRepository {
  TelegramRepository(this._client);

  final SupabaseClient _client;

  Future<TelegramStatus> status() async {
    try {
      final raw = await _client.rpc<dynamic>('telegram_link_state');
      if (raw is! Map) return const TelegramStatus();
      return TelegramStatus.fromMap(Map<String, dynamic>.from(raw));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Asks the bridge to start a handshake. The reply carries the request id that
  /// every following step must reference, plus the expiry the UI counts down.
  Future<LinkResult> start({String? phone}) => _call(<String, Object?>{
        'action': 'start',
        if (phone != null) 'phone': phone,
      });

  /// QR login: the bridge returns a `login_token` the user scans with an existing
  /// Telegram session, which skips the SMS round trip entirely.
  Future<LinkResult> startWithQr() => _call(<String, Object?>{'action': 'start', 'useQr': true});

  Future<LinkResult> submitCode({required String requestId, required String code}) => _call(<String, Object?>{
        'action': 'submit',
        'requestId': requestId,
        'code': code,
      });

  Future<LinkResult> submitPassword({required String requestId, required String password}) => _call(<String, Object?>{
        'action': 'submit',
        'requestId': requestId,
        'password': password,
      });

  Future<void> cancel(String requestId) => _call(<String, Object?>{'action': 'cancel', 'requestId': requestId});

  Future<void> unlink() => _call(<String, Object?>{'action': 'unlink'});

  /// Chats the bridge discovered for this account, with the per-chat switch state.
  /// `telegram_chats` is owner-scoped by RLS, so the panel can read it directly.
  Future<List<MirroredChat>> mirroredChats({int limit = 200}) async {
    try {
      final rows = await _client
          .from('telegram_chats')
          .select(
            'chat_id, tg_chat_id, tg_chat_type, title, sync_direction, muted, peer_user_id, '
            'last_inbound_at, last_outbound_at',
          )
          .eq('owner_user_id', _currentUid())
          .order('last_inbound_at', ascending: false, nullsFirst: false)
          .limit(limit);
      return rows.map(MirroredChat.fromMap).toList(growable: false);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// These preferences live on the signed-in profile, not the Telegram session:
  /// preview privacy also applies to banners while the app is in the foreground.
  Future<PushPreferences> pushPreferences() async {
    try {
      final row = await _client
          .from('profiles')
          .select('push_telegram, push_preview')
          .eq('id', _currentUid())
          .single();
      return PushPreferences.fromMap(Map<String, dynamic>.from(row));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<PushPreferences> setPushPreferences({bool? telegram, bool? preview}) async {
    try {
      final raw = await _client.rpc<dynamic>('set_push_preferences', params: <String, Object?>{
        'p_push_telegram': telegram,
        'p_push_preview': preview,
      });
      if (raw is! Map) throw const AppException('database', 'Could not save your notification preferences.');
      return PushPreferences.fromMap(Map<String, dynamic>.from(raw));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> setChatSync({required String chatId, required String direction}) async {
    try {
      await _client.rpc<dynamic>('telegram_set_chat_sync', params: <String, Object?>{
        'p_chat_id': chatId,
        'p_direction': direction,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> setPreferences({
    String? syncDirection,
    bool? autoDownloadVoice,
    bool? autoDownloadMedia,
    bool? mirrorToApp,
  }) async {
    try {
      await _client.rpc<dynamic>('telegram_set_preferences', params: <String, Object?>{
        'p_sync_direction': syncDirection,
        'p_auto_download_voice': autoDownloadVoice,
        'p_auto_download_media': autoDownloadMedia,
        'p_mirror_to_app': mirrorToApp,
      });
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Watches the handshake until it settles.
  ///
  /// Polling rather than a realtime subscription is deliberate: the link-request
  /// row is written by the service role only, and giving a client read access to it
  /// would need a policy the schema intentionally does not have. `telegram_link_state()`
  /// already exposes exactly the projection the wizard needs, owner-scoped.
  Stream<LinkProgress> watchHandshake({
    Duration interval = const Duration(milliseconds: 900),
    Duration timeout = const Duration(minutes: 4),
  }) async* {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final state = await status();
      final request = state.pendingRequest;
      yield LinkProgress(status: state, request: request);
      if (request == null) {
        // Nothing in flight: linked already, or the handshake was never started.
        return;
      }
      if (request.isFinished || request.isAwaitingUser) return;
      await Future<void>.delayed(interval);
    }
  }

  String _currentUid() {
    final uid = _client.auth.currentSession?.user.id;
    if (uid == null) throw const AppException('auth', 'Sign in first.');
    return uid;
  }

  /// Invokes the edge function through the SDK so the Authorization and apikey
  /// headers come from the live session (a token refresh is applied for us). A
  /// non-2xx answer surfaces as [FunctionsException], which [AppException.wrap]
  /// already understands — including `retry_after_seconds` for rate limits.
  Future<LinkResult> _call(Map<String, Object?> body) async {
    if (_client.auth.currentSession == null) throw const AppException('auth', 'Sign in first.');
    try {
      final response = await _client.functions.invoke('telegram-link', body: body).timeout(const Duration(seconds: 15));
      final envelope = response.data;
      final data = envelope is Map ? envelope['data'] : null;
      return LinkResult(data is Map ? Map<String, dynamic>.from(data) : const <String, dynamic>{});
    } on TimeoutException {
      throw const AppException('timeout', 'Telegram did not answer in time. Try again.');
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }
}

/// Shared by the Telegram settings panel and the foreground banner host.
/// Previews fail closed (false) if a response lacks the field.
class PushPreferences {
  const PushPreferences({required this.telegram, required this.preview});

  final bool telegram;
  final bool preview;

  factory PushPreferences.fromMap(Map<String, dynamic> row) => PushPreferences(
        telegram: row['push_telegram'] == true,
        preview: row['push_preview'] == true,
      );
}

class LinkResult {
  const LinkResult(this.data);

  final Map<String, dynamic> data;

  String? get requestId => data['request_id'] as String?;
  String? get step => data['step'] as String?;
  String? get qrCode => data['qr_code'] as String?;
  DateTime? get expiresAt => parseTimestamp(data['expires_at']);

  /// False only in development, where sealing is unavailable and the function says
  /// so — the wizard then warns that this build cannot carry a real password.
  bool get sealingEnabled => data['sealed'] != false;

  String get message => asString(data['message'], fallback: '');
}

class LinkProgress {
  const LinkProgress({required this.status, this.request});

  final TelegramStatus status;
  final LinkRequest? request;

  LinkPrompt get prompt => request?.prompt ?? (status.isLinked ? LinkPrompt.waiting : LinkPrompt.phone);

  bool get isLinked => status.isLinked;

  String? get note => request?.error ?? status.note;
}
