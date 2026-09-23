import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';

/// State of the three-step handshake: phone → code → (2FA password).
///
/// The wizard never holds a credential longer than one request. `code` and
/// `password` are handed straight to [TelegramRepository], which POSTs them to the
/// edge function; nothing is cached here, nothing is printed, and the fields are
/// cleared as soon as the call returns.
class LinkState extends Equatable {
  const LinkState({
    this.prompt = LinkPrompt.phone,
    this.requestId,
    this.note,
    this.error,
    this.busy = false,
    this.qrCode,
    this.expiresAt,
    this.sealed = true,
    this.linked = false,
  });

  final LinkPrompt prompt;
  final String? requestId;
  final String? note;
  final String? error;
  final bool busy;
  final String? qrCode;
  final DateTime? expiresAt;
  final bool sealed;
  final bool linked;

  bool get isBusy => busy;

  Duration? get timeLeft {
    final expiry = expiresAt;
    if (expiry == null) return null;
    final left = expiry.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  LinkState copyWith({
    LinkPrompt? prompt,
    String? requestId,
    String? note,
    bool? busy,
    String? qrCode,
    DateTime? expiresAt,
    bool? sealed,
    bool? linked,
    Object? error = _keep,
  }) =>
      LinkState(
        prompt: prompt ?? this.prompt,
        requestId: requestId ?? this.requestId,
        note: note ?? this.note,
        qrCode: qrCode ?? this.qrCode,
        expiresAt: expiresAt ?? this.expiresAt,
        sealed: sealed ?? this.sealed,
        linked: linked ?? this.linked,
        busy: busy ?? this.busy,
        error: identical(error, _keep) ? this.error : error,
      );

  static const Object _keep = Object();

  @override
  List<Object?> get props => <Object?>[prompt, requestId, note, error, busy, qrCode, expiresAt, sealed, linked];
}

class LinkCubit extends Cubit<LinkState> {
  LinkCubit(this._repository) : super(const LinkState()) {
    unawaited(_syncFromServer());
  }

  final TelegramRepository _repository;
  StreamSubscription<LinkProgress>? _watch;

  @override
  Future<void> close() async {
    await _watch?.cancel();
    _watch = null;
    return super.close();
  }

  /// If a request is already in flight (the app was killed mid-handshake), resume it
  /// instead of starting a second one — Telegram invalidates the previous code when
  /// a new request begins, which is exactly the bug that makes people give up.
  Future<void> _syncFromServer() async {
    try {
      final status = await _repository.status();
      final request = status.pendingRequest;
      if (request == null) {
        emit(state.copyWith(linked: status.isLinked, prompt: status.isLinked ? LinkPrompt.waiting : LinkPrompt.phone));
        return;
      }
      emit(state.copyWith(
        requestId: request.id,
        prompt: request.prompt,
        qrCode: request.qrCode,
        note: request.error ?? status.note,
        expiresAt: request.expiresAt,
        linked: status.isLinked,
      ));
    } catch (_) {
      emit(state.copyWith(error: 'Could not read your Telegram status. Check the connection and retry.'));
    }
  }

  Future<void> submitPhone(String phone) => _run(() async {
        final result = await _repository.start(phone: phone.trim());
        return LinkResultAdapter.from(result);
      });

  Future<void> startWithQr() => _run(() async {
        final result = await _repository.startWithQr();
        return LinkResultAdapter.from(result);
      });

  Future<void> submitCode(String code) {
    final requestId = state.requestId;
    if (requestId == null) return Future<void>.value();
    return _run(() async {
      final result = await _repository.submitCode(requestId: requestId, code: code.trim());
      return LinkResultAdapter.from(result);
    });
  }

  Future<void> submitPassword(String password) {
    final requestId = state.requestId;
    if (requestId == null) return Future<void>.value();
    return _run(() async {
      final result = await _repository.submitPassword(requestId: requestId, password: password);
      return LinkResultAdapter.from(result);
    });
  }

  Future<void> cancel() async {
    final requestId = state.requestId;
    await _watch?.cancel();
    _watch = null;
    if (requestId == null) return;
    try {
      await _repository.cancel(requestId);
    } catch (error) {
      emit(state.copyWith(error: AppException.wrap(error).message));
    }
    emit(state.copyWith(requestId: null, prompt: LinkPrompt.phone, qrCode: null, note: null));
  }

  /// Runs one handshake step and then watches until Telegram asks for the next
  /// input, so the UI never has to guess which field to show.
  Future<void> _run(Future<HandshakeStep> Function() action) async {
    emit(state.copyWith(busy: true, error: null));
    try {
      final step = await action();
      emit(state.copyWith(
        busy: false,
        requestId: step.requestId ?? state.requestId,
        prompt: step.prompt,
        qrCode: step.qrCode,
        note: step.note,
        expiresAt: step.expiresAt,
        sealed: step.sealed,
      ));
      if (step.prompt == LinkPrompt.waiting) _watchProgress();
    } catch (error) {
      emit(state.copyWith(busy: false, error: AppException.wrap(error).message));
    }
  }

  void _watchProgress() {
    unawaited(_watch?.cancel() ?? Future<void>.value());
    _watch = _repository.watchHandshake().listen(
      (progress) {
        if (progress.isLinked) {
          emit(state.copyWith(linked: true, prompt: LinkPrompt.waiting, requestId: null, note: null));
          return;
        }
        final request = progress.request;
        if (request == null) return;
        emit(state.copyWith(prompt: request.prompt, note: request.error ?? progress.note, expiresAt: request.expiresAt));
      },
      onError: (Object error) => emit(state.copyWith(error: AppException.wrap(error).message)),
      onDone: () => emit(state.copyWith(busy: false)),
    );
  }
}

/// The function's reply, normalised into "what the wizard should ask for next".
class HandshakeStep {
  const HandshakeStep({
    this.requestId,
    this.prompt = LinkPrompt.waiting,
    this.qrCode,
    this.note,
    this.expiresAt,
    this.sealed = true,
  });

  final String? requestId;
  final LinkPrompt prompt;
  final String? qrCode;
  final String? note;
  final DateTime? expiresAt;
  final bool sealed;
}

class LinkResultAdapter {
  const LinkResultAdapter._();

  static HandshakeStep from(LinkResult result) {
    final step = result.step;
    return HandshakeStep(
      requestId: result.requestId,
      qrCode: result.qrCode,
      note: result.message.isEmpty ? null : result.message,
      expiresAt: result.expiresAt,
      sealed: result.sealingEnabled,
      prompt: switch (step) {
        'awaiting_code' => LinkPrompt.code,
        'awaiting_password' => LinkPrompt.password,
        'awaiting_phone' => LinkPrompt.phone,
        'awaiting_registration' => LinkPrompt.registration,
        _ => LinkPrompt.waiting,
      },
    );
  }
}
