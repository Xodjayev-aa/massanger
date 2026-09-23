import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/di.dart';
import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../../data/voice_service.dart';
import 'chat_bloc.dart';
import 'photo_viewer.dart';

/// One bubble: text, photo or voice note, plus its state line.
///
/// Media URLs are resolved lazily and cached by the repository — a thread of 200
/// messages must not fire 200 `createSignedUrl` calls just because it was scrolled
/// once.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.showAvatar,
    required this.onTapReply,
    required this.onLongPress,
  });

  final MessageItem message;
  final bool showAvatar;
  final VoidCallback onTapReply;
  final Future<void> Function() onLongPress;

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    final mirror = message.isMirroredFromTelegram;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;

    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Opacity(
          // A local bubble that has not been confirmed yet reads as "on its way".
          opacity: message.isLocal ? 0.82 : 1,
          child: Padding(
            padding: EdgeInsets.only(left: mine ? 48 : 0, right: mirror && !mine ? 0 : 0),
            child: Column(
              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: <Widget>[
                if (showAvatar && !mine && mirror)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, left: 4),
                    child: Text(
                      message.senderName,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                InkWell(
                  borderRadius: AppTheme.bubbleRadius(mine),
                  onLongPress: onLongPress,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                    decoration: BoxDecoration(
                      color: AppTheme.bubbleColor(context, isMine: mine, isTelegramMirror: mirror),
                      borderRadius: AppTheme.bubbleRadius(mine),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (message.replyToId != null) _ReplyQuote(message: message, mine: mine),
                        ..._body(context),
                        const SizedBox(height: 2),
                        _StateLine(message: message),
                      ],
                    ),
                  ),
                ),
                if (message.state.isFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: TextButton.icon(
                      onPressed: () => context.read<ChatBloc>().add(ChatRetryRequested(message.id)),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    switch (message.kind) {
      case MessageKind.image:
        return <Widget>[
          _Photo(message: message),
          if ((message.body ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(message.body!),
            ),
        ];
      case MessageKind.voice:
        final media = message.media;
        return <Widget>[
          if (media is VoiceMedia)
            VoiceBubble(messageId: message.id, media: media, mine: message.isMine)
          else
            const Text('Voice note unavailable'),
          if ((message.body ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(message.body!),
            ),
        ];
      case MessageKind.system:
        return <Widget>[
          Text(
            message.body ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ];
      case MessageKind.text:
        return <Widget>[
          SelectableText(
            message.body ?? '',
            style: const TextStyle(fontSize: 15, height: 1.35),
          ),
        ];
    }
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.message, required this.mine});

  final MessageItem message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: mine ? Colors.white.withAlpha(120) : scheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            message.replySenderName ?? 'Reply',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
          ),
          Text(
            message.replyBody ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StateLine extends StatelessWidget {
  const _StateLine({required this.message});

  final MessageItem message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = message.state.ticksAreBlue ? AppTheme.tickActive : scheme.onSurfaceVariant;
    final failure = message.failureText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (message.isMirroredFromTelegram && !message.isMine)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.send_rounded, size: 12, color: scheme.onSurfaceVariant),
          ),
        if (failure != null) ...<Widget>[
          Icon(Icons.error_outline_rounded, size: 13, color: scheme.error),
          const SizedBox(width: 4),
          Flexible(child: Text(failure, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error, fontSize: 11))),
          const SizedBox(width: 6),
        ],
        Text(
          ChatFormatting.clock(message.timestamp),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11),
        ),
        if (message.isMine) ...<Widget>[
          const SizedBox(width: 4),
          _Ticks(state: message.state, colour: colour),
        ],
        if (message.isTelegramDelivered)
          Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Tooltip(
              message: 'Sent to Telegram',
              child: Icon(Icons.cloud_done_rounded, size: 13, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.state, required this.colour});

  final DeliveryState state;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    if (state.isFailed) return Icon(Icons.error_outline_rounded, size: 14, color: Theme.of(context).colorScheme.error);
    final count = state.ticks;
    if (count <= 1) return Icon(Icons.schedule_rounded, size: 13, color: colour);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.done_rounded, size: 14, color: colour),
        if (count > 1) Icon(Icons.done_rounded, size: 14, color: colour),
      ],
    );
  }
}

class _Photo extends StatefulWidget {
  const _Photo({required this.message});

  final MessageItem message;

  @override
  State<_Photo> createState() => _PhotoState();
}

class _PhotoState extends State<_Photo> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final url = await sl<ChatRepository>().urlFor(widget.message.media);
      if (mounted) setState(() => _url = url);
    } catch (_) {
      if (mounted) setState(() => _url = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.message.media;
    final ratio = media is ImageMedia ? media.aspectRatio : 1.0;
    if (_url == null) {
      return Container(
        width: 240,
        height: 240 / (ratio <= 0 ? 1 : ratio),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final url = _url!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PhotoViewer(urls: <String>[url], index: 0),
          ),
        ),
        child: Hero(
          tag: 'photo-${widget.message.id}',
          child: Image.network(
            url,
            width: 240,
            height: 240 / (ratio <= 0 ? 1 : ratio),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => SizedBox(
              width: 240,
              height: 140,
              child: Center(child: Icon(Icons.broken_image_rounded, color: Theme.of(context).colorScheme.outline)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Voice bubble: the stored 64-bar envelope doubles as the seek track. A message
/// whose waveform was never stored (a mirrored Telegram note, for instance) falls
/// back to a plain progress bar, so the bubble is never empty.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.messageId, required this.media, required this.mine});

  final String messageId;
  final VoiceMedia media;
  final bool mine;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  late final VoicePlayer _player = sl<VoicePlayer>();
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    setState(() => _resolving = true);
    try {
      final url = await sl<ChatRepository>().urlFor(widget.media);
      if (url != null && mounted) _player.prime(widget.messageId, url);
    } catch (_) {
      // The play button will report the failure when tapped, which is the only
      // moment it matters to the user.
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _toggle() async {
    try {
      await _player.toggle(widget.messageId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error is AppException ? error.message : 'That recording could not be played.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = widget.media.duration;
    final bars = widget.media.waveform;
    return SizedBox(
      width: 230,
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: _resolving ? null : _toggle,
            iconSize: 30,
            icon: StreamBuilder<bool>(
              stream: _player.isPlaying,
              initialData: false,
              builder: (context, snapshot) => Icon(
                (snapshot.data ?? false) && _player.currentId == widget.messageId
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: _player.position,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final progress = _player.currentId == widget.messageId && duration.inMilliseconds > 0
                    ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0;
                return GestureDetector(
                  onTapUp: (details) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final fraction = details.localPosition.dx / box.size.width;
                    _player.seekTo(fraction);
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        height: 26,
                        child: bars.isEmpty
                            ? LinearProgressIndicator(value: progress, minHeight: 3)
                            : _WaveformBars(values: bars, progress: progress),
                      ),
                      Text(
                        _player.currentId == widget.messageId ? '${ChatFormatting.duration(position)} / ${ChatFormatting.duration(duration)}' : ChatFormatting.duration(widget.media.duration),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformBars extends StatelessWidget {
  const _WaveformBars({required this.values, required this.progress});

  final List<int> values;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = AppTheme.tickActive;
    final idle = scheme.onSurfaceVariant.withAlpha(90);
    return CustomPaint(
      painter: _WaveformPainter(values: values, progress: progress, active: active, idle: idle),
      size: Size.infinite,
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.values, required this.progress, required this.active, required this.idle});

  final List<int> values;
  final double progress;
  final Color active;
  final Color idle;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final slot = size.width / values.length;
    final barWidth = slot < 3 ? slot * 0.6 : 2.0;
    final painted = size.width * progress;
    for (var i = 0; i < values.length; i++) {
      final x = i * slot + (slot - barWidth) / 2;
      final height = (values[i] / 100.0) * size.height;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - height) / 2, barWidth, height),
          Radius.circular(barWidth / 2),
        ),
        Paint()..color = x <= painted ? active : idle,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.progress != progress || old.values != values;
}
