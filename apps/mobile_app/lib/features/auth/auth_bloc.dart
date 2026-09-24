import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../data/account_repository.dart';
import '../../data/models.dart';

/// Where the app is, from the point of view of navigation.
///
/// `verificationRequired` is a legacy server state, not a Google-age check.
/// Only the server can move an account to active (or ban it).
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

class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

class AuthUiState extends Equatable {
  const AuthUiState({
    this.status = AppStatus.unknown,
    this.profile,
    this.error,
    this.busy = false,
    this.userId,
  });

  final AppStatus status;
  final AccountProfile? profile;
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
    bool? busy,
    String? userId,
    Object? error = _keep,
  }) =>
      AuthUiState(
        status: status ?? this.status,
        profile: profile ?? this.profile,
        // `error` defaults to a sentinel so omitting it preserves the current
        // error, while `error: null` clears it. A plain null-default could not
        // express "clear the error".
        error: identical(error, _keep) ? this.error : error,
        busy: busy ?? this.busy,
        userId: userId ?? this.userId,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[status, profile, error, busy, userId];
}

class AuthBloc extends Bloc<AuthEvent, AuthUiState> {
  AuthBloc(this._accounts) : super(const AuthUiState()) {
    on<AuthStarted>(_onStarted);
    on<AuthSessionChanged>(_onSessionChanged);
    on<AuthProfileRefreshRequested>(_onProfileRefresh);
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
  /// account may use MessengerX; the UI cannot grant its own access.
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
          busy: false,
        ));
        return;
      }
      // A pending legacy/moderation state cannot be cleared by a client-side
      // Google token. Offer a refresh; migration 00013 activates old age-gated
      // accounts and leaves manually restricted/banned users alone.
      emit(AuthUiState(
        status: AppStatus.verificationRequired,
        profile: profile,
        userId: userId,
        busy: false,
      ));
    } catch (error) {
      // A network failure must not read as "you are not allowed here": stay on the
      // gate with a retry affordance rather than emitting `blocked`.
      emit(AuthUiState(status: AppStatus.verificationRequired, userId: userId, error: error, busy: false));
    }
  }

  Future<void> _onSignOut(AuthSignOutRequested event, Emitter<AuthUiState> emit) async {
    // Sign-out is local to this device. Unlinking Telegram here would revoke
    // the TDLib session for every device, violating cross-device sign-in.
    // The explicit "Unlink" control on the Telegram page does that instead.
    try {
      await _accounts.signOut();
    } catch (error) {
      emit(state.copyWith(error: error));
      return;
    }
    emit(AuthUiState(status: AppStatus.signedOut));
  }

  /// The bloc keeps sign-in errors out of the router and in the sign-in UI.
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
