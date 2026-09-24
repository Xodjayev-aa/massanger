import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import '../core/formatting.dart';
import 'models.dart';

/// Supabase Auth, own profile and presence. Access state is server-managed by
/// RLS and moderation; it is not inferred from Gmail or Drive content.
class AccountRepository {
  AccountRepository(this._client, {this.telegramLoginEnabled = false});

  final SupabaseClient _client;
  final bool telegramLoginEnabled;

  Stream<AuthState> get authChanges => _client.auth.onAuthStateChange;

  Session? get session => _client.auth.currentSession;

  String? get currentUserId => _client.auth.currentUser?.id;

  String get currentUserIdOrThrow {
    final uid = currentUserId;
    if (uid == null) throw const AppException('auth', 'Sign in first.');
    return uid;
  }

  /// Basic Google OAuth scopes only (openid, email, profile). On the web
  /// Supabase redirects back to the configured public site URL; native builds
  /// use the callback registered in Android/iOS and the Auth redirect allowlist.
  static const String _nativeCallback = 'com.messengerx.app://login-callback';

  Future<void> signInWithGoogle() async {
    try {
      await _client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : _nativeCallback,
      );
    } on AuthException catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Independent Supabase identity via Telegram's OIDC approval flow. The
  /// hosted Auth service validates Telegram's signed ID token; no bot secret or
  /// service-role key is ever in the client. This is NOT TDLib phone/code login:
  /// users still need to connect their own Telegram account in Settings to send
  /// and receive Telegram conversations. Do not enable until the custom provider
  /// and its redirect URLs have been verified on the real hosted project.
  Future<void> signInWithTelegram() async {
    if (!telegramLoginEnabled) {
      throw const AppException('configuration', 'Telegram sign-in is not configured on this server yet.');
    }
    try {
      await _client.auth.signInWithOAuth(
        const OAuthProvider('custom:telegram'),
        scopes: 'openid profile phone',
        redirectTo: kIsWeb ? Uri.base.origin : _nativeCallback,
      );
    } on AuthException catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<AccountProfile> profile() async {
    final uid = currentUserIdOrThrow;
    try {
      final row = await _client
          .from('profiles')
          .select(
            'id, username, display_name, avatar_path, avatar_external_url, bio, phone_e164, '
            'telegram_username, access_state, access_state_reason, google_email, '
            'last_seen_at',
          )
          .eq('id', uid)
          .maybeSingle();
      if (row == null) {
        throw const AppException('not_found', 'Your profile row is missing. Reinstall or contact support.');
      }
      return AccountProfile.fromMap(Map<String, dynamic>.from(row));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<DirectoryEntry> directoryEntry(String userId) async {
    try {
      final row = await _client
          .from('directory')
          .select('id, username, display_name, avatar_path, avatar_external_url, bio, telegram_username, is_online, last_seen_at')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) throw const AppException('not_found', 'No such person in MessengerX.');
      return DirectoryEntry.fromMap(Map<String, dynamic>.from(row));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// `update_profile` is a definer function on purpose: `guard_profile_update`
  /// refuses client writes to server-managed columns, so the editable fields go
  /// through an RPC that only forwards the safe ones.
  /// [clearAvatar] is the only supported way to remove a picture: `p_avatar_path: ''`
  /// is refused by the storage-prefix guard server-side, so an empty string would be a
  /// 42501 rather than a no-op (see migration 00011).
  Future<AccountProfile> updateProfile({
    String? displayName,
    String? bio,
    String? avatarPath,
    bool clearAvatar = false,
  }) async {
    currentUserIdOrThrow;
    try {
      final row = await _client.rpc<dynamic>('update_profile', params: <String, Object?>{
        'p_display_name': displayName,
        'p_bio': bio,
        'p_avatar_path': avatarPath,
        if (clearAvatar) 'p_clear_avatar': true,
      });
      if (row is Map) return AccountProfile.fromMap(Map<String, dynamic>.from(row));
      return profile();
    } on AuthException catch (error, stack) {
      throw AppException.wrap(error, stack);
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// Replaces the avatar: upload first, then point the profile at the new object.
  /// The old object is removed only after the row is updated, so a failed upload
  /// can never leave the profile pointing at a deleted file.
  Future<String> uploadAvatar(XFile file) async {
    final uid = currentUserIdOrThrow;
    final size = await file.length();
    if (size > 5 * 1024 * 1024) throw const AppException('storage', 'Avatars must stay under 5 MB.');
    final path = '$uid/avatar-${DateTime.now().millisecondsSinceEpoch}.jpg';
    try {
      await _client.storage.from('avatars').uploadBinary(
        path, await file.readAsBytes(), fileOptions: const FileOptions(contentType: 'image/jpeg'));
      return path;
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<void> removeAvatarObject(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      await _client.storage.from('avatars').remove(<String>[path]);
    } catch (_) {
      // Orphaned bytes are swept by the nightly job in the runbook.
    }
  }

  /// Bumps `last_seen_at`, which `directory.is_online` derives from. Called on
  /// resume and on a timer; deliberately not in the background, where a wake would
  /// make every contact look online at 3 a.m.
  Future<void> heartbeat() async {
    try {
      await _client.rpc<dynamic>('heartbeat');
    } catch (_) {
      // Presence is advisory.
    }
  }
}
