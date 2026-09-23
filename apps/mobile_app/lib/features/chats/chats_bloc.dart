import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../core/errors.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../auth/auth_bloc.dart';

enum ChatsStatus { initial, loading, ready, failure }

class ChatsEvent {
  const ChatsEvent();
}

class ChatsOpened extends ChatsEvent {
  const ChatsOpened();
}

class ChatsRefreshRequested extends ChatsEvent {
  const ChatsRefreshRequested();
}

class ChatsUnreadCleared extends ChatsEvent {
  const ChatsUnreadCleared(this.chatId);

  final String chatId;
}

class ChatsQueryChanged extends ChatsEvent {
  const ChatsQueryChanged(this.query);

  final String query;
}

class ChatsState extends Equatable {
  const ChatsState({
    this.status = ChatsStatus.initial,
    this.chats = const <ChatSummary>[],
    this.query = '',
    this.unreadTotal = 0,
    this.error,
  });

  final ChatsStatus status;
  final List<ChatSummary> chats;
  final String query;
  final int unreadTotal;
  final Object? error;

  bool get isLoading => status == ChatsStatus.loading && chats.isEmpty;

  /// Filtering happens locally: `chat_summaries` already returned the preview text,
  /// and a second round trip per keystroke is not what a list filter should cost.
  List<ChatSummary> get visible {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return chats;
    return chats
        .where((chat) =>
            chat.displayName.toLowerCase().contains(needle) || (chat.previewBody ?? '').toLowerCase().contains(needle))
        .toList(growable: false);
  }

  ChatsState copyWith({
    ChatsStatus? status,
    List<ChatSummary>? chats,
    String? query,
    int? unreadTotal,
    Object? error = _keep,
  }) =>
      ChatsState(
        status: status ?? this.status,
        chats: chats ?? this.chats,
        query: query ?? this.query,
        unreadTotal: unreadTotal ?? this.unreadTotal,
        error: identical(error, _keep) ? this.error : error,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[status, chats, query, unreadTotal, error];
}

class ChatsBloc extends Bloc<ChatsEvent, ChatsState> {
  ChatsBloc(this._chats, {required AuthBloc auth}) : super(const ChatsState()) {
    _auth = auth;
    on<ChatsOpened>(_onOpened);
    on<ChatsRefreshRequested>((_, emit) => _load(emit));
    on<ChatsQueryChanged>((event, emit) => emit(state.copyWith(query: event.query)));
    on<ChatsUnreadCleared>(_onUnreadCleared);

    // Wait for a validated session before the first read: a query fired during the
    // cold-start restore carries no JWT and would fail the whole list.
    _authSub = auth.stream.listen((authState) {
      if (authState.isReady && !_started) {
        _started = true;
        add(const ChatsOpened());
      } else if (!authState.isReady && _started) {
        _started = false;
        unawaited(_unsubscribe());
      }
    });
  }

  final ChatRepository _chats;
  late final AuthBloc _auth;
  StreamSubscription<AuthUiState>? _authSub;
  sb.RealtimeChannel? _channel;
  Timer? _debounce;
  bool _started = false;

  @override
  Future<void> close() async {
    _debounce?.cancel();
    await _authSub?.cancel();
    _authSub = null;
    await _unsubscribe();
    return super.close();
  }

  Future<void> _onOpened(ChatsOpened event, Emitter<ChatsState> emit) async {
    await _load(emit);
    _subscribeToReceipts();
  }

  /// The list listens to its own `chat_participants` rows, not to `messages`.
  /// A message firehose would push every chat in the world through this isolate;
  /// the participant rows change exactly when a badge or a preview must change.
  void _subscribeToReceipts() {
    final previous = _channel;
    if (previous != null) unawaited(previous.unsubscribe());
    _channel = sb.Supabase.instance.client
        .channel('chat-participants')
        .onPostgresChanges(
          event: sb.PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_participants',
          filter: sb.PostgresChangeFilter(
            type: sb.PostgresChangeFilterType.eq,
            column: 'user_id',
            value: _auth.state.userId ?? '',
          ),
          callback: (_) => _refreshSoon(),
        )
        .subscribe();
  }

  Future<void> _unsubscribe() async {
    await _channel?.unsubscribe();
    _channel = null;
  }

  void _refreshSoon() {
    // Five incoming messages are one list reload, not five.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (_started) unawaited(_load(null, silent: true));
    });
  }

  Future<void> _load(Emitter<ChatsState>? emit, {bool silent = false}) async {
    final userId = _auth.state.userId;
    if (userId == null) {
      emit?.call(state.copyWith(status: ChatsStatus.failure, error: const AppException('auth', 'Sign in first.')));
      return;
    }
    if (!silent) emit?.call(state.copyWith(status: ChatsStatus.loading, error: null));
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _chats.summaries(),
        _chats.unreadTotal(),
      ]);
      emit?.call(
        state.copyWith(
          status: ChatsStatus.ready,
          chats: results[0] as List<ChatSummary>,
          unreadTotal: results[1] as int,
          error: null,
        ),
      );
    } catch (error) {
      emit?.call(state.copyWith(status: ChatsStatus.failure, error: error));
    }
  }

  /// Called by the widget layer when the app returns to the foreground.
  Future<void> refresh() async {
    if (_started) _refreshSoon();
  }

  /// Called when the app is backgrounded: an idle socket costs battery, and the
  /// resume path resubscribes.
  Future<void> pause() async {
    _debounce?.cancel();
    _debounce = null;
    await _unsubscribe();
  }

  /// A thread the user opened has already been read: fold the badge down locally
  /// instead of waiting for the next `chat_summaries` round trip.
  ///
  /// It goes through an event rather than calling `emit` here: in bloc 8 `emit` is
  /// only public inside an `on` handler, and state that changes off-book is state an
  /// observer never sees.
  void clearUnread(String chatId) => add(ChatsUnreadCleared(chatId));

  void _onUnreadCleared(ChatsUnreadCleared event, Emitter<ChatsState> emit) {
    final chatId = event.chatId;
    if (!state.chats.any((chat) => chat.chatId == chatId && chat.unreadCount != 0)) return;
    final chats = state.chats.map((chat) => chat.chatId == chatId ? chat.withUnread(0) : chat).toList(growable: false);
    emit(state.copyWith(chats: chats));
  }
}
