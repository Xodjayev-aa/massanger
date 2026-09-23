import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/di.dart';
import '../../core/errors.dart';
import '../../data/voice_service.dart';
import 'chat_bloc.dart';

/// The message input: text, photo, and a hold-to-record voice note.
///
/// Recording is a long-press because that is the gesture that carries intent — a tap
/// would send a 0.2 s clip. Sliding the finger off the button cancels, and the level
/// meter plus the countdown make the 120 s cap visible before it bites.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.bloc, required this.chatId});

  final ChatBloc bloc;
  final String chatId;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  late final VoiceService _voices = sl<VoiceService>();

  Timer? _typingStop;
  Timer? _recordTicker;
  bool _micPressed = false;
  bool _cancelling = false;
  double _level = 0;
  Duration _recorded = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _typingStop?.cancel();
    _recordTicker?.cancel();
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _text.dispose();
    unawaited(_voices.cancel());
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) widget.bloc.notifyTyping(on: false);
  }

  bool get _canSend => _text.text.trim().isNotEmpty && !widget.bloc.state.sending;

  void _onTextChanged(String value) {
    if (value.trim().isEmpty) {
      widget.bloc.notifyTyping(on: false);
      _typingStop?.cancel();
      _typingStop = null;
      return;
    }
    widget.bloc.notifyTyping();
    // Stop asserting presence when the user pauses: the bubble has to disappear on
    // its own, not six seconds after the last keystroke.
    _typingStop?.cancel();
    _typingStop = Timer(const Duration(seconds: 3), () => widget.bloc.notifyTyping(on: false));
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    _typingStop?.cancel();
    widget.bloc.notifyTyping(on: false);
    widget.bloc.add(ChatTextSent(text));
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2560,
        imageQuality: 88,
      );
      if (picked == null) return;
      // The caption is the message body, so ask once, up front, rather than
      // sending a photo and offering an afterthought.
      if (!mounted) return;
      final caption = await showDialog<String>(
        context: context,
        builder: (dialogContext) => _CaptionDialog(fileName: picked.name),
      );
      widget.bloc.add(ChatImageSent(File(picked.path), caption: caption));
    } on AppException catch (error) {
      _show(error.message);
    } catch (error) {
      _show('That image could not be read.');
    }
  }

  Future<void> _startRecording() async {
    setState(() {
      _micPressed = true;
      _cancelling = false;
      _recorded = Duration.zero;
      _level = 0;
      _error = null;
    });
    try {
      await _voices.start();
      _levels();
      _recordTicker?.cancel();
      _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _recorded = _voices.elapsed);
        if (_voices.isAtLimit) _finishRecording();
      });
    } on AppException catch (error) {
      setState(() => _error = error.message);
      _reset();
    }
  }

  void _levels() {
    _voiceLevels?.cancel();
    _voiceLevels = _voices.levels.listen(
      (event) {
        if (mounted) setState(() => _level = event.level);
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = AppException.wrap(error).message);
      },
    );
  }

  StreamSubscription<VoiceLevelEvent>? _voiceLevels;

  void _reset() {
    setState(() {
      _micPressed = false;
      _level = 0;
    });
    _recordTicker?.cancel();
    _recordTicker = null;
    unawaited(_voiceLevels?.cancel() ?? Future<void>.value());
    _voiceLevels = null;
  }

  Future<void> _finishRecording() async {
    if (!_micPressed) return;
    _reset();
    try {
      final take = await _voices.stop();
      if (take == null) {
        _show('That recording was too short to send.');
        return;
      }
      widget.bloc.add(ChatVoiceSent(take));
    } on AppException catch (error) {
      _show(error.message);
    }
  }

  Future<void> _cancelRecording() async {
    if (!_micPressed) return;
    _reset();
    await _voices.cancel();
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final replyTo = context.select<ChatBloc, MessageItem?>((bloc) => bloc.state.replyTo);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
        if (replyTo != null)
          Material(
            color: theme.colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 8, 2),
              child: Row(
                children: <Widget>[
                  Container(width: 3, height: 30, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${replyTo.senderName}: ${replyTo.preview}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    onPressed: () => widget.bloc.add(ChatReplyChosen(null)),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(top: BorderSide(color: theme.dividerColor.withAlpha(60))),
            ),
            child: _micPressed ? _recordingRow(context) : _inputRow(context),
          ),
        ),
      ],
    );
  }

  Widget _inputRow(BuildContext context) {
    final replyTo = widget.bloc.state.replyTo;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        IconButton(
          tooltip: 'Attach a photo',
          onPressed: _pickImage,
          icon: const Icon(Icons.attach_file_rounded),
        ),
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            onChanged: _onTextChanged,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              hintText: replyTo == null ? 'Message' : 'Reply to ${replyTo.senderName}',
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 4),
        BlocBuilder<ChatBloc, ChatState>(
          buildWhen: (previous, next) => previous.sending != next.sending || previous.messages.length != next.messages.length,
          builder: (context, state) {
            final hasText = _text.text.trim().isNotEmpty;
            if (hasText) {
              return IconButton.filled(
                onPressed: state.sending ? null : _send,
                icon: state.sending
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_upward_rounded),
              );
            }
            // The mic owns the long press: press-and-hold records, release sends,
            // and sliding left discards.
            return GestureDetector(
              onLongPressStart: (_) => _startRecording(),
              onLongPressMoveUpdate: (details) => setState(() => _cancelling = details.offsetFromOrigin.dx < -60),
              onLongPressEnd: (_) => _finishRecording(),
              onLongPressCancel: _cancelRecording,
              child: IconButton(
                tooltip: 'Hold to record a voice note',
                onPressed: () => _show('Hold the microphone to record.'),
                icon: const Icon(Icons.mic_rounded),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _recordingRow(BuildContext context) {
    final theme = Theme.of(context);
    final total = const Duration(seconds: 120);
    final left = total - _recorded;
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: 'Slide left to cancel',
          onPressed: _cancelRecording,
          icon: Icon(Icons.delete_outline_rounded, color: _cancelling ? theme.colorScheme.error : null),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _cancelling ? 'Release to discard' : '${ChatFormatCompact.left(left)} left · ${ChatFormatCompact.recorded(_recorded)}',
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              _LevelMeter(level: _level),
            ],
          ),
        ),
        IconButton.filled(onPressed: _finishRecording, icon: const Icon(Icons.stop_rounded)),
      ],
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final bars = 24;
    final lit = (level * bars).round();
    final theme = Theme.of(context);
    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (var i = 0; i < bars; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  height: 4 + (i <= lit ? 14.0 : 0.0),
                  decoration: BoxDecoration(
                    color: i <= lit ? theme.colorScheme.error : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CaptionDialog extends StatefulWidget {
  const _CaptionDialog({required this.fileName});

  final String fileName;

  @override
  State<_CaptionDialog> createState() => _CaptionDialogState();
}

class _CaptionDialogState extends State<_CaptionDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'Add a caption (optional)'),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Send without caption')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text.trim()), child: const Text('Send')),
      ],
    );
  }
}

class ChatFormatCompact {
  const ChatFormatCompact._();

  static String left(Duration value) {
    if (value.isNegative) return '0:00';
    return '${value.inMinutes}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  static String recorded(Duration value) => left(value);
}
