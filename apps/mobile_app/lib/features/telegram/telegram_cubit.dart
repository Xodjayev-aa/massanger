import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';

enum TelegramLoadStatus { initial, loading, ready, failure }

class TelegramPanel extends Equatable {
  const TelegramPanel({
    this.status = TelegramLoadStatus.initial,
    this.account,
    this.chats = const <MirroredChat>[],
    this.pushPreferences,
    this.busy = false,
    this.error,
  });

  final TelegramLoadStatus status;
  final TelegramStatus? account;
  final List<MirroredChat> chats;
  final PushPreferences? pushPreferences;
  final bool busy;
  final Object? error;

  bool get isLinked => account?.isLinked ?? false;

  TelegramPanel copyWith({
    TelegramLoadStatus? status,
    TelegramStatus? account,
    List<MirroredChat>? chats,
    PushPreferences? pushPreferences,
    bool? busy,
    Object? error = _keep,
  }) =>
      TelegramPanel(
        status: status ?? this.status,
        account: account ?? this.account,
        chats: chats ?? this.chats,
        pushPreferences: pushPreferences ?? this.pushPreferences,
        busy: busy ?? this.busy,
        error: identical(error, _keep) ? this.error : error,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[status, account, chats, pushPreferences, busy, error];
}

class TelegramCubit extends Cubit<TelegramPanel> {
  TelegramCubit(this._repository) : super(const TelegramPanel());

  final TelegramRepository _repository;

  Future<void> load() async {
    emit(state.copyWith(status: TelegramLoadStatus.loading, error: null));
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.status(),
        _repository.mirroredChats(),
        _repository.pushPreferences(),
      ]);
      emit(state.copyWith(
        status: TelegramLoadStatus.ready,
        account: results[0] as TelegramStatus,
        chats: results[1] as List<MirroredChat>,
        pushPreferences: results[2] as PushPreferences,
      ));
    } catch (error) {
      emit(state.copyWith(status: TelegramLoadStatus.failure, error: error));
    }
  }

  /// Prefs are written through the definer RPC, which returns nothing: the panel is
  /// re-read rather than guessed at, because `sync_direction` also decides whether
  /// the composer may send to Telegram at all.
  Future<void> setPreferences({String? syncDirection, bool? autoDownloadVoice, bool? autoDownloadMedia, bool? mirrorToApp}) async {
    emit(state.copyWith(busy: true, error: null));
    try {
      await _repository.setPreferences(
        syncDirection: syncDirection,
        autoDownloadVoice: autoDownloadVoice,
        autoDownloadMedia: autoDownloadMedia,
        mirrorToApp: mirrorToApp,
      );
      await load();
    } catch (error) {
      emit(state.copyWith(busy: false, error: error));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  Future<void> setPushPreferences({bool? telegram, bool? preview}) async {
    emit(state.copyWith(busy: true, error: null));
    try {
      // Do not optimistically show a preview switch that the server refused.
      final saved = await _repository.setPushPreferences(telegram: telegram, preview: preview);
      emit(state.copyWith(pushPreferences: saved, busy: false));
    } catch (error) {
      emit(state.copyWith(busy: false, error: AppException.wrap(error)));
    }
  }

  Future<void> setChatSync({required String chatId, required String direction}) async {
    emit(state.copyWith(busy: true));
    try {
      await _repository.setChatSync(chatId: chatId, direction: direction);
      await load();
    } catch (error) {
      emit(state.copyWith(busy: false, error: AppException.wrap(error)));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  Future<void> unlink() async {
    emit(state.copyWith(busy: true));
    try {
      await _repository.unlink();
      await load();
    } catch (error) {
      emit(state.copyWith(busy: false, error: AppException.wrap(error)));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }
}
