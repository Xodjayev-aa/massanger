import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../data/account_repository.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';

/// Where the app is, from the point of view of navigation.
///
/// `verificationRequired` and `blocked` are separate because the UI and the retry
/// policy differ: a pending check offers "check again", a restricted account offers
/// an appeal path and must not keep hammering Google.
enum AppStatus { unknown, signedOut, verificationRequired, blocked, ready }

class AuthEvent {
  const AuthEvent();
}

class AuthStarted extends AuthEvent {
  const AuthStarted();
}

class AuthSessionChanged extends AuthEvent {
  const AuthSessionChanged({required this.change, this.userId});

  final sb.AuthChangeEvent change;
  final String? userId;
}

class AuthProfileRefreshRequested extends AuthEvent {
  const AuthProfileRefreshRequested();
}

class AuthEligibilityRequested extends AuthEvent {
  const AuthEligibilityRequested({this.force = false});

  /// `true` only from the button on the gate screen — the server rate-limits
  /// rechecks per user, so nothing else in the app forces one.
  final bool force;
}

class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

class AuthUiState extends Equatable {
  const AuthUiState({
    this.status = AppStatus.unknown,
    this.profile,
    this.eligibility,
    this.error,
    this.busy = false,
    this.userId,
  });

  final AppStatus status;
  final AccountProfile? profile;
  final EligibilityResult? eligibility;
  final Object? error;
  final bool busy;
  final String? userId;

  bool get isReady => status == AppStatus.ready;

  String get displayName => (profile?.displayName.isNotEmpty ?? false)
      ? profile!.displayName
      : (profile?.username ?? 'You');

  /// `profiles.avatar_path` is a storage object key, resolved to a signed URL by
  /// [AccountRepository]; `avatar_external_url` (e.g. a Telegram photo) is used as
  /// stored, because Google and Telegram both hand out directly fetchable URLs.
  String? get avatarPath => profile?.avatar;

  AuthUiState copyWith({
    AppStatus? status,
    AccountProfile? profile,
    EligibilityResult? eligibility,
    bool? busy,
    String? userId,
    Object? error = _keep,
  }) =>
      AuthUiState(
        status: status ?? this.status,
        profile: profile ?? this.profile,
        eligibility: eligibility ?? this.eligibility,
        // `error` defaults to a sentinel so omitting it preserves the current
        // error, while `error: null` clears it. A plain null-default could not
        // express "clear the error".
        error: identical(error, _keep) ? this.error : error,
        busy: busy ?? this.busy,
        userId: userId ?? this.userId,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[status, profile, eligibility, error, busy, userId];
}

class AuthBloc extends Bloc<AuthEvent, AuthUiState> {
  AuthBloc(this._accounts, this._telegram) : super(const AuthUiState()) {
    on<AuthStarted>(_onStarted);
    on<AuthSessionChanged>(_onSessionChanged);
    on<AuthProfileRefreshRequested>(_onProfileRefresh);
    on<AuthEligibilityRequested>(_onEligibility);
    on<AuthSignOutRequested>(_onSignOut);

    // One listener for the whole app: sign-in, token refresh, an expired session and
    // a sign-out from another tab all arrive here and re-run the router redirect.
    _subscription = _accounts.authChanges.listen((authState) {
      add(AuthSessionChanged(
        change: authState.event,
        userId: authState.session?.user.id,
      ));
    });
  }

  final AccountRepository _accounts;
  final TelegramRepository _telegram;
  StreamSubscription<sb.AuthState>? _subscription;
  DateTime? _lastPresencePing;

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    return super.close();
  }

  Future<void> _onStarted(AuthStarted event, Emitter<AuthUiState> emit) async {
    if (_accounts.session == null) {
      emit(state.copyWith(status: AppStatus.signedOut, error: null));
      return;
    }
    await _bootstrap(emit);
  }

  Future<void> _onSessionChanged(AuthSessionChanged event, Emitter<AuthUiState> emit) async {
    switch (event.change) {
      case sb.AuthChangeEvent.signedOut:
        emit(AuthUiState(status: AppStatus.signedOut));
        return;
      case sb.AuthChangeEvent.tokenRefreshed:
        // Nothing about access changed; keep the profile we already validated.
        return;
      case sb.AuthChangeEvent.signedIn:
      case sb.AuthChangeEvent.initialSession:
      case sb.AuthChangeEvent.userUpdated:
      case sb.AuthChangeEvent.passwordRecovery:
        // A fresh sign-in must reload the profile before the router lets the user
        // in: `access_state` decides the destination.
        if (state.isReady && event.change == sb.AuthChangeEvent.userUpdated) return;
        await _bootstrap(emit);
        return;
      default:
        // `mfaChallengeVerified`, and the deprecated `userDeleted` that the library
        // documents as never emitted: nothing the session UI needs to react to.
        return;
    }
  }

  Future<void> _onProfileRefresh(AuthProfileRefreshRequested event, Emitter<AuthUiState> emit) => _bootstrap(emit);

  /// Profile → gate decision. The profile row is authoritative for whether this
  /// account may use Massanger; the eligibility result only explains the state.
  Future<void> _bootstrap(Emitter<AuthUiState> emit) async {
    final userId = _accounts.currentUserId;
    if (userId == null) {
      emit(AuthUiState(status: AppStatus.signedOut));
      return;
    }
    emit(state.copyWith(busy: true, userId: userId));
    try {
      final profile = await _accounts.profile();
      if (profile.accessState == 'active') {
        emit(AuthUiState(status: AppStatus.ready, profile: profile, userId: userId, busy: false));
        unawaited(refreshPresence());
        return;
      }
      if (profile.isBlocked) {
        emit(AuthUiState(
          status: AppStatus.blocked,
          profile: profile,
          userId: userId,
          eligibility: await _accounts.eligibility(),
          busy: false,
        ));
        return;
      }
      // pending_verification: try to clear it now. If Google already answered for
      // this account the function short-circuits off the cached verdict, so the cost
      // is one request, not a consent round trip.
      final eligibility = await _accounts.checkEligibility();
      emit(AuthUiState(
        status: eligibility.passed ? AppStatus.ready : AppStatus.verificationRequired,
        profile: profile,
        eligibility: eligibility,
        userId: userId,
        busy: false,
      ));
    } catch (error) {
      // A network failure must not read as "you are not allowed here": stay on the
      // gate with a retry affordance rather than emitting `blocked`.
      emit(AuthUiState(status: AppStatus.verificationRequired, userId: userId, error: error, busy: false));
    }
  }

  Future<void> _onEligibility(AuthEligibilityRequested event, Emitter<AuthUiState> emit) async {
    emit(state.copyWith(busy: true, error: null));
    try {
      final eligibility = await _accounts.checkEligibility(recheck: event.force);
      final profile = await _accounts.profile();
      emit(AuthUiState(
        status: profile.accessState == 'active'
            ? AppStatus.ready
            : (profile.isBlocked ? AppStatus.blocked : AppStatus.verificationRequired),
        profile: profile,
        eligibility: eligibility,
        userId: state.userId,
      ));
    } catch (error) {
      emit(state.copyWith(error: error));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  Future<void> _onSignOut(AuthSignOutRequested event, Emitter<AuthUiState> emit) async {
    try {
      // Unlinking Telegram first means a later install on another device cannot
      // resume a bridge session that its owner just ended.
      final status = await _telegram.status();
      if (status.isLinked) await _telegram.unlink();
    } catch (_) {
      // A failed unlink must never block a sign-out — the bridge lease expires on
      // its own, and the user's intent (end this session) still wins.
    }
    try {
      await _accounts.signOut();
    } catch (error) {
      emit(state.copyWith(error: error));
    }
    emit(AuthUiState(status: AppStatus.signedOut));
  }

  /// The sign-in path itself lives here so the page owns no repository: the bloc
  /// is the only place that knows what a failed OAuth should mean for the session.
  Future<void> signInWithGoogle() => _accounts.signInWithGoogle();

  /// `heartbeat()` writes `profiles.last_seen_at`, from which `directory.is_online`
  /// is derived. Throttled because the app also calls it on resume; the periodic
  /// timer in the widget layer is the only other caller.
  Future<void> refreshPresence() async {
    final now = DateTime.now();
    if (_lastPresencePing != null && now.difference(_lastPresencePing!) < const Duration(seconds: 20)) return;
    _lastPresencePing = now;
    await _accounts.heartbeat();
  }
}
