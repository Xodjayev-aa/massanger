import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import '../core/formatting.dart';
import 'models.dart';

/// Sign-in, the own-profile row, the age gate, and the presence heartbeat.
///
/// The age gate is the one security-critical call the app makes: it is *not*
/// trusted from the client. `profiles.access_state` is what the database and the
/// bridge consult, and only the edge function may flip it — so a tampered client
/// can delay its own check at worst, never skip it.
class AccountRepository {
  AccountRepository(this._client);

  final SupabaseClient _client;

  Stream<AuthState> get authChanges => _client.auth.onAuthStateChange;

  Session? get session => _client.auth.currentSession;

  String? get currentUserId => _client.auth.currentUser?.id;

  String get currentUserIdOrThrow {
    final uid = currentUserId;
    if (uid == null) throw const AppException('auth', 'Sign in first.');
    return uid;
  }

  /// Google is the only identity provider, because the age rule is defined on a
  /// Google account. `signInWithOAuth` returns once the redirect completes; the
  /// provider token rides along in the session for the eligibility check below.
  Future<void> signInWithGoogle() async {
    try {
      // `access_type=offline` + `prompt=consent` makes Google return a refresh
      // token, which the server stores so the age check can be re-run later
      // without asking the user to sign in again.
      await _client.auth.signInWithOAuth(
        OAuthProvider.google,
        queryParameters: <String, String>{
          'access_type': 'offline',
          'prompt': 'consent',
        },
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
            'google_account_created_at, google_account_age_days, eligibility_verified_at, '
            'eligibility_method, eligibility_attempts, last_seen_at',
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
      if (row == null) throw const AppException('not_found', 'No such person in Massanger.');
      return DirectoryEntry.fromMap(Map<String, dynamic>.from(row));
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  /// `update_profile` is a definer function on purpose: `guard_profile_update`
  /// refuses client writes to the eligibility columns, so the editable fields go
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
  Future<String> uploadAvatar(File file) async {
    final uid = currentUserIdOrThrow;
    final size = await file.length();
    if (size > 5 * 1024 * 1024) throw const AppException('storage', 'Avatars must stay under 5 MB.');
    final path = '$uid/avatar-${DateTime.now().millisecondsSinceEpoch}.jpg';
    try {
      await _client.storage.from('avatars').upload(path, file, fileOptions: const FileOptions(contentType: 'image/jpeg'));
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

  /// Runs the Google account-age check. [providerToken] is `session.providerToken`
  /// right after the OAuth redirect; without it the function falls back to the
  /// credentials it stored earlier, and if there are none it tells the user to
  /// re-consent rather than guessing.
  Future<EligibilityResult> checkEligibility({bool recheck = false}) async {
    final session = _client.auth.currentSession;
    if (session == null) throw const AppException('auth', 'Sign in first.');
    try {
      final response = await _client.functions
          .invoke(
            'account-age-gate',
            body: <String, Object?>{
              'requestId': '${DateTime.now().microsecondsSinceEpoch}',
              if (session.providerToken != null) 'providerToken': session.providerToken,
              'accessToken': session.accessToken,
              'recheck': recheck,
            },
          )
          .timeout(const Duration(seconds: 20));
      final envelope = response.data;
      final data = envelope is Map ? envelope['data'] : null;
      if (data is! Map) {
        throw const AppException('function', 'The age check returned no result.');
      }
      return EligibilityResult.fromMap(Map<String, dynamic>.from(data));
    } on TimeoutException {
      throw const AppException('timeout', 'Google did not answer in time. Try again in a moment.');
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
  }

  Future<EligibilityResult?> eligibility() async {
    try {
      final raw = await _client.rpc<dynamic>('eligibility_status');
      if (raw is! Map) return null;
      return EligibilityResult.fromMap(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
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

/// The `account-age-gate` reply, plus `eligibility_status()`'s cached shape.
class EligibilityResult {
  const EligibilityResult({
    required this.passed,
    required this.accessState,
    required this.reason,
    this.method,
    this.accountCreatedAt,
    this.accountAgeDays,
    this.minAgeDays = 366,
    this.checkedAt,
    this.attempts,
    this.sealingEnabled = true,
  });

  final bool passed;
  final String accessState;
  final String reason;
  final String? method;
  final DateTime? accountCreatedAt;
  final int? accountAgeDays;
  final int minAgeDays;
  final DateTime? checkedAt;
  final int? attempts;
  final bool sealingEnabled;

  bool get isBlocked => accessState == 'restricted' || accessState == 'banned';

  bool get needsRecheck => accessState == 'pending_verification';

  /// Copy for the gate screen. The server phrased `reason`, so the app adds only
  /// what it knows locally (how many tries are left, when to come back).
  String get headline {
    if (passed) return 'Account verified';
    if (accountAgeDays != null) {
      return 'Your Google account is $accountAgeDays day${accountAgeDays == 1 ? '' : 's'} old. '
          'Massanger needs at least $minAgeDays days.';
    }
    return reason.isEmpty ? 'We could not confirm your account age yet.' : reason;
  }

  factory EligibilityResult.fromMap(Map<String, dynamic> map) => EligibilityResult(
        passed: map['passed'] == true || map['verdict'] == 'passed',
        accessState: asString(map['access_state'], fallback: 'pending_verification'),
        reason: asString(map['reason']),
        method: map['method'] as String?,
        accountCreatedAt: parseTimestamp(map['account_created_at']),
        accountAgeDays: map['account_age_days'] == null ? null : asInt(map['account_age_days']),
        minAgeDays: asInt(map['min_age_days'], 366),
        checkedAt: parseTimestamp(map['checked_at'] ?? map['verified_at']),
        attempts: map['attempts'] == null ? null : asInt(map['attempts']),
        sealingEnabled: map['sealing'] != false,
      );
}
