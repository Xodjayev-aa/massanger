import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../../data/voice_service.dart';
import '../auth/auth_bloc.dart';

enum ChatStatus { loading, ready, failure }

class ChatEvent {
  const ChatEvent();
}

class ChatOpened extends ChatEvent {
  const ChatOpened(this.chatId);

  final String chatId;
}

class ChatOlderRequested extends ChatEvent {
  const ChatOlderRequested();
}

class ChatTextSent extends ChatEvent {
  const ChatTextSent(this.text);

  final String text;
}

class ChatImageSent extends ChatEvent {
  const ChatImageSent(this.file, {this.caption});

  final XFile file;
  final String? caption;
}

class ChatVoiceSent extends ChatEvent {
  const ChatVoiceSent(this.take);

  final VoiceTake take;
}

class ChatReplyChosen extends ChatEvent {
  const ChatReplyChosen(this.message);

  /// null clears the reply.
  final MessageItem? message;
}

class ChatRetryRequested extends ChatEvent {
  const ChatRetryRequested(this.messageId);

  final String messageId;
}

class ChatDeleteRequested extends ChatEvent {
  const ChatDeleteRequested(this.messageId);

  final String messageId;
}

class ChatTypingChanged extends ChatEvent {
  const ChatTypingChanged(this.presences);

  final List<TypingPresence> presences;
}

class ChatRealtimeChanged extends ChatEvent {
  const ChatRealtimeChanged(this.kind, this.row);

  final String kind;
  final Map<String, dynamic> row;
}

class ChatState extends Equatable {
  const ChatState({
    this.chatId = '',
    this.status = ChatStatus.loading,
    this.messages = const <MessageItem>[],
    this.replyTo,
    this.typing = const <TypingPresence>[],
    this.loadingOlder = false,
    this.hasMore = true,
    this.sending = false,
    this.error,
  });

  final String chatId;
  final ChatStatus status;
  final List<MessageItem> messages;
  final MessageItem? replyTo;
  final List<TypingPresence> typing;
  final bool loadingOlder;
  final bool hasMore;
  final bool sending;
  final Object? error;

  /// Newest first for the reversed list view: index 0 is the bubble at the bottom.
  List<MessageItem> get rendered => messages.reversed.toList(growable: false);

  String? get typingLabel {
    if (typing.isEmpty) return null;
    if (typing.length == 1) {
      final who = typing.first;
      return who.isFromTelegram ? '${who.name} is typing on Telegram' : '${who.name} is typing…';
    }
    return '${typing.length} people are typing…';
  }

  ChatState copyWith({
    String? chatId,
    ChatStatus? status,
    List<MessageItem>? messages,
    MessageItem? Function()? replyTo,
    List<TypingPresence>? typing,
    bool? loadingOlder,
    bool? hasMore,
    bool? sending,
    Object? error = _keep,
  }) =>
      ChatState(
        chatId: chatId ?? this.chatId,
        status: status ?? this.status,
        messages: messages ?? this.messages,
        // A nullable field needs a thunk: `replyTo: () => null` means "clear it".
        replyTo: replyTo == null ? this.replyTo : replyTo(),
        typing: typing ?? this.typing,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        hasMore: hasMore ?? this.hasMore,
        sending: sending ?? this.sending,
        error: identical(error, _keep) ? this.error : error,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[chatId, status, messages, replyTo, typing, loadingOlder, hasMore, sending, error];
}

/// One open thread.
///
/// The three things this class exists to get right:
///   * **optimistic sends** keyed by `client_message_id`, so the bubble the user
///     typed is *replaced* by the server row (same id) rather than duplicated, and a
///     slow realtime event cannot reorder anything;
///   * **read receipts** only while the thread is actually open, and only for peer
///     messages — the database enforces both, the client just avoids the traffic;
///   * **typing**, which is fire-and-forget with a server-side TTL, so a missed
///     "stopped typing" is impossible to notice.
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc(this._repository, this._voices, {required this.auth, required this.player}) : super(const ChatState()) {
    on<ChatOpened>(_onOpened);
    on<ChatOlderRequested>(_onOlder);
    on<ChatTextSent>(_onText);
    on<ChatImageSent>(_onImage);
    on<ChatVoiceSent>(_onVoice);
    on<ChatReplyChosen>((event, emit) => emit(state.copyWith(replyTo: () => event.message)));
    on<ChatRetryRequested>(_onRetry);
    on<ChatDeleteRequested>(_onDelete);
    on<ChatTypingChanged>(_onTyping);
    on<ChatRealtimeChanged>(_onRealtime);
  }

  final ChatRepository _repository;
  final VoiceService _voices;
  final AuthBloc auth;
  final VoicePlayer player;

  static const int _pageSize = ChatRepository.feedPageSize;
  static const Uuid _uuid = Uuid();

  sb.RealtimeChannel? _channel;
  TypingSubscription? _typing;
  StreamSubscription<AuthUiState>? _authSub;
  Timer? _typingThrottle;
  bool _typingActive = false;
  final Set<String> _deliveredIds = <String>{};
  String? _chatId;

  String get _uid => auth.state.userId ?? '';

  String get _myName => auth.state.displayName;

  @override
  Future<void> close() async {
    _typingThrottle?.cancel();
    _typingThrottle = null;
    await _typingSub?.cancel();
    _typingSub = null;
    await _authSub?.cancel();
    _authSub = null;
    await _typing?.cancel();
    _typing = null;
    await _channel?.unsubscribe();
    _channel = null;
    await _voices.cancel();
    return super.close();
  }

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    _chatId = event.chatId;
    emit(ChatState(chatId: event.chatId, status: ChatStatus.loading));
    if (_uid.isEmpty) {
      emit(state.copyWith(status: ChatStatus.failure, error: const AppException('auth', 'Sign in first.')));
      return;
    }
    try {
      final messages = await _repository.feed(chatId: event.chatId, currentUserId: _uid);
      emit(state.copyWith(
        status: ChatStatus.ready,
        messages: messages,
        hasMore: messages.length >= _pageSize,
        error: null,
      ));
      _subscribe();
      unawaited(_markVisibleRead(messages));
    } catch (error) {
      emit(state.copyWith(status: ChatStatus.failure, error: error));
    }
  }

  void _subscribe() {
    final chatId = _chatId;
    if (chatId == null) return;

    final previous = _channel;
    if (previous != null) unawaited(previous.unsubscribe());
    _channel = _repository.watchMessages(
      chatId: chatId,
      onEvent: (kind, row) {
        if (row.isEmpty) return;
        add(ChatRealtimeChanged(kind, row));
      },
    );

    unawaited(_typing?.cancel());
    _typing = _repository.watchTyping(chatId: chatId, load: () => _repository.typingState(chatId));
    _typingSub = _typing!.stream.listen((presences) => add(ChatTypingChanged(presences)));
  }

  StreamSubscription<List<TypingPresence>>? _typingSub;

  Future<void> _onOlder(ChatOlderRequested event, Emitter<ChatState> emit) async {
    if (state.loadingOlder || !state.hasMore) return;
    final oldest = state.messages.isEmpty ? null : state.messages.first.id;
    emit(state.copyWith(loadingOlder: true));
    try {
      final older = await _repository.feed(chatId: state.chatId, beforeId: oldest, currentUserId: _uid);
      // `chat_feed` pages by id, so an empty page is the end of the thread.
      final merged = <MessageItem>[...older, ...state.messages.where((m) => !older.any((o) => o.id == m.id))];
      emit(state.copyWith(messages: merged, loadingOlder: false, hasMore: older.length >= _pageSize));
    } catch (error) {
      emit(state.copyWith(loadingOlder: false, error: error));
    }
  }

  Future<void> _onText(ChatTextSent event, Emitter<ChatState> emit) async {
    final text = event.text.trim();
    if (text.isEmpty) return;
    final replyTo = state.replyTo;
    final clientId = _uuid.v4();
    final optimistic = MessageItem.local(
      chatId: state.chatId,
      kind: MessageKind.text,
      clientMessageId: clientId,
      senderName: _myName,
      body: text,
      replyToId: replyTo?.id,
      replySenderName: replyTo?.senderName,
      replyBody: replyTo?.preview,
    );
    emit(state.copyWith(messages: <MessageItem>[...state.messages, optimistic], replyTo: () => null, sending: true));
    await _deliver(optimistic, emit, body: text);
  }

  Future<void> _onImage(ChatImageSent event, Emitter<ChatState> emit) async {
    final clientId = _uuid.v4();
    try {
      final media = await _repository.uploadImage(chatId: state.chatId, file: event.file, caption: event.caption);
      final optimistic = MessageItem.local(
        chatId: state.chatId,
        kind: MessageKind.image,
        clientMessageId: clientId,
        senderName: _myName,
        body: event.caption,
        media: media,
      );
      emit(state.copyWith(messages: <MessageItem>[...state.messages, optimistic], sending: true));
      await _deliver(optimistic, emit, mediaMap: media.toMap());
    } catch (error) {
      emit(state.copyWith(sending: false, error: error));
    }
  }

  Future<void> _onVoice(ChatVoiceSent event, Emitter<ChatState> emit) async {
    final clientId = _uuid.v4();
    try {
      final media = await _repository.uploadVoice(
        chatId: state.chatId,
        bytes: event.take.bytes,
        duration: event.take.duration,
        waveform: event.take.waveform,
      );
      final optimistic = MessageItem.local(
        chatId: state.chatId,
        kind: MessageKind.voice,
        clientMessageId: clientId,
        senderName: _myName,
        media: media,
      );
      emit(state.copyWith(messages: <MessageItem>[...state.messages, optimistic], sending: true));
      await _deliver(optimistic, emit, mediaMap: media.toMap());
    } catch (error) {
      emit(state.copyWith(sending: false, error: error));
    }
  }

  /// The single write path. `send_message` returns the stored row, so the optimistic
  /// bubble is replaced by the real one here; realtime may deliver the same row first
  /// (own-device events are not suppressed by Postgres), and whichever arrives last
  /// is the one that wins, because both key off `client_message_id`.
  Future<void> _deliver(MessageItem optimistic, Emitter<ChatState> emit, {String? body, Map<String, Object?>? mediaMap}) async {
    try {
      final stored = await _repository.send(
        chatId: state.chatId,
        kind: optimistic.kind,
        clientMessageId: optimistic.clientMessageId!,
        currentUserId: _uid,
        body: body,
        media: mediaMap,
        replyToId: optimistic.replyToId,
      );
      emit(state.copyWith(messages: _replaceByClientKey(state.messages, optimistic.clientMessageId!, stored), sending: false, error: null));
    } catch (error) {
      emit(state.copyWith(
        messages: state.messages
            .map((message) => message.id == optimistic.id
                ? message.copyWith(state: DeliveryState.failed)
                : message)
            .toList(growable: false),
        sending: false,
        error: AppException.wrap(error),
      ));
    }
  }

  static List<MessageItem> _replaceByClientKey(List<MessageItem> messages, String clientMessageId, MessageItem stored) {
    // Keep the position of the local bubble: a thread must not reorder under the
    // user's thumb when the server answer lands.
    var replaced = false;
    final result = <MessageItem>[];
    for (final message in messages) {
      if (message.clientMessageId == clientMessageId) {
        result.add(stored);
        replaced = true;
        continue;
      }
      // Realtime can win the race and deliver the same row first; adding it twice
      // would show a duplicate bubble until the next reload.
      if (message.id == stored.id) continue;
      result.add(message);
    }
    return replaced ? result : <MessageItem>[...result, stored];
  }

  Future<void> _onRealtime(ChatRealtimeChanged event, Emitter<ChatState> emit) async {
    final row = event.row;
    final id = '${row['id']}';
    if (id.isEmpty || id == 'null') return;

    if (event.kind == 'DELETE') {
      emit(state.copyWith(messages: state.messages.where((message) => message.id != id).toList(growable: false)));
      return;
    }

    // A mirrored Telegram message has no `is_mine`; the sender id decides, which is
    // exactly what `MessageItem.fromMap` falls back to.
    final message = MessageItem.fromMap(row, currentUserId: _uid);
    if (event.kind == 'UPDATE') {
      final index = state.messages.indexWhere((existing) => existing.id == id);
      if (index < 0) {
        // An update for a row we do not have yet (opened the thread mid-scroll).
        emit(state.copyWith(messages: <MessageItem>[...state.messages, message]));
        return;
      }
      final next = <MessageItem>[...state.messages];
      next[index] = message;
      emit(state.copyWith(messages: next));
      return;
    }

    if (state.messages.any((existing) => existing.id == id)) return;
    final clientId = row['client_message_id'];
    if (clientId != null && state.messages.any((existing) => existing.clientMessageId == '$clientId')) {
      // `_deliver` already put the stored row in; realtime is the slower path here.
      return;
    }
    emit(state.copyWith(messages: <MessageItem>[...state.messages, message]));
    unawaited(_acknowledge(message));
  }

  Future<void> _onTyping(ChatTypingChanged event, Emitter<ChatState> emit) async {
    final others = event.presences.where((presence) => presence.userId != _uid).toList(growable: false);
    emit(state.copyWith(typing: others));
  }

  /// The composer calls this on every keystroke burst; the RPC itself throttles to
  /// 2.5 s, and the local timer keeps us from even making the call.
  void notifyTyping({bool on = true}) {
    if (state.chatId.isEmpty) return;
    if (on && !_typingActive) {
      _typingActive = true;
      unawaited(_repository.setTyping(chatId: state.chatId, on: true));
      _typingThrottle?.cancel();
      // Telegram clears "typing" after ~6 s; re-assert a little before that.
      _typingThrottle = Timer(const Duration(seconds: 5), () {
        if (_typingActive) notifyTyping();
      });
      return;
    }
    if (!on && _typingActive) {
      _typingActive = false;
      _typingThrottle?.cancel();
      _typingThrottle = null;
      unawaited(_repository.setTyping(chatId: state.chatId, on: false));
    }
  }

  Future<void> _onRetry(ChatRetryRequested event, Emitter<ChatState> emit) async {
    final index = state.messages.indexWhere((message) => message.id == event.messageId);
    if (index < 0) return;
    final failed = state.messages[index];
    if (!failed.isLocal) {
      try {
        await _repository.retry(event.messageId);
      } catch (error) {
        emit(state.copyWith(error: error));
      }
      return;
    }
    // A local bubble never reached the database, so "retry" means resend it whole.
    final next = <MessageItem>[...state.messages];
    next[index] = failed.copyWith(state: DeliveryState.pending);
    emit(state.copyWith(messages: next));
    await _deliver(next[index], emit, body: failed.body, mediaMap: failed.media?.toMap());
  }

  Future<void> _onDelete(ChatDeleteRequested event, Emitter<ChatState> emit) async {
    final previous = state.messages;
    final target = previous.firstWhere((message) => message.id == event.messageId);
    emit(state.copyWith(messages: previous.where((message) => message.id != event.messageId).toList(growable: false)));
    try {
      await _repository.delete(event.messageId);
      // Only a local bubble needs storage cleanup: deleting the server row cascades
      // to its object through the same-owner policy the bucket already enforces.
      if (target.isLocal && target.media != null) await _repository.deleteUploaded(target.media);
    } catch (error) {
      emit(state.copyWith(messages: previous, error: error));
    }
  }

  Future<void> _markVisibleRead(List<MessageItem> messages) async {
    await _repository.markRead(state.chatId);
    await _repository.markDelivered(
      messages
          .where((message) => !message.isMine && !_deliveredIds.contains(message.id))
          .map((message) => message.id)
          .toList(growable: false)
          .reversed
          .take(30)
          .toList(growable: false),
    );
    for (final message in messages) {
      if (!message.isMine) _deliveredIds.add(message.id);
    }
  }

  Future<void> _acknowledge(MessageItem message) async {
    if (message.isMine || _deliveredIds.contains(message.id)) return;
    _deliveredIds.add(message.id);
    await _repository.markDelivered(<String>[message.id]);
  }
}
